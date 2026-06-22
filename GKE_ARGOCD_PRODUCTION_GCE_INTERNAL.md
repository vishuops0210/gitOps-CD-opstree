# ArgoCD on GKE — Internal-Only Production Setup (Google Managed Ingress / gce-internal)

> **Goal**: Deploy ArgoCD on a single-region, 2-node GKE cluster with **internal-only** Google Managed Ingress (GCE Internal Application Load Balancer), Google SSO, RBAC, and regional pre-shared SSL certificates.
>
> **Access Pattern**: NO public internet. Only company network (VPC + VPN) can reach ArgoCD.
>
> **Load Balancer**: Google Internal Application Load Balancer (L7) — fully managed, container-native load balancing via NEGs.
>
> **Date**: June 2026

---

## ⚠️ Prerequisites — Read This First

| Prerequisite | Status | Why Required |
|-------------|--------|-------------|
| VPC-native cluster (`--enable-ip-alias`) | ✅ Mandatory | Required by GCE Ingress for NEGs |
| `HttpLoadBalancing` add-on | ✅ Mandatory (enabled by default) | Required by GCE Ingress |
| GKE version > 1.16.5-gke.10 | ✅ Check your version | Minimum version for internal Ingress |
| `container.googleapis.com` API | ✅ Enable if not already | Required for GKE |

**Verify your cluster meets requirements:**
```bash
gcloud container clusters describe argocd-cluster --zone=asia-south1-a --format='table(addonsConfig.httpLoadBalancing.disabled, networkConfig.enableIntraNodeVisibility, networkConfig.datapathProvider, locations)'
```

**All values should show:**
- `networkConfig.enableIntraNodeVisibility`: `True` (or field present)
- `addonsConfig.httpLoadBalancing.disabled`: `None` (or not present)

If `httpLoadBalancing` is disabled, **you cannot use GCE Ingress**. Re-enable it via:
```bash
gcloud container clusters update argocd-cluster --zone=asia-south1-a --update-addons=HttpLoadBalancing=ENABLED
```

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Traffic Flow](#2-traffic-flow)
3. [Resource Sizing](#3-resource-sizing)
4. [Phase 1 — Create GKE Cluster](#4-phase-1--create-gke-cluster)
5. [Phase 2 — Prepare Networking (Proxy Subnet + Firewall)](#5-phase-2--prepare-networking-proxy-subnet--firewall)
6. [Phase 3 — Generate Certificates](#6-phase-3--generate-certificates)
7. [Phase 4 — Create GCP Resources (Static IP + SSL Cert)](#7-phase-4--create-gcp-resources-static-ip--ssl-cert)
8. [Phase 5 — Install ArgoCD (With GCE Internal Ingress)](#8-phase-5--install-argocd-with-gce-internal-ingress)
9. [Phase 6 — Create BackendConfig & FrontendConfig](#9-phase-6--create-backendconfig--frontendconfig)
10. [Phase 7 — Google SSO](#10-phase-7--google-sso)
11. [Phase 8 — RBAC](#11-phase-8--rbac)
12. [Phase 9 — Verification](#12-phase-9--verification)
13. [Phase 10 — Production Hardening](#13-phase-10--production-hardening)
14. [Accessing ArgoCD from Your Laptop](#14-accessing-argocd-from-your-laptop)
15. [Cost Estimate](#15-cost-estimate)
16. [Troubleshooting](#16-troubleshooting)
17. [Command Cheat Sheet](#17-command-cheat-sheet)

---

# 1. Architecture Overview

## 1.1 What Is GKE Ingress (Google Managed)?

GKE Ingress is a **built-in** Ingress controller provided by Google Cloud. When you create an Ingress resource with `kubernetes.io/ingress.class: "gce-internal"`, GKE automatically:

1. Creates a Regional Internal Application Load Balancer (L7)
2. Creates forwarding rules, backend services, URL maps, and target proxies
3. Sets up Network Endpoint Groups (NEGs) for container-native load balancing
4. Manages health checks
5. Terminates TLS using your pre-shared regional certificate

**You do NOT install or manage any controller pod.** Google runs everything outside your cluster.

## 1.2 Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   OUTSIDE WORLD (INTERNET)                                                  │
│   ════════════════════════                                                  │
│                                                                             │
│   No public IP exists. The internal LB has NO internet face.               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      ▲
                                      │ Only internal traffic passes
                                      │
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   COMPANY NETWORK / VPN / GOOGLE CLOUD VPC                                  │
│   ════════════════════════════════════════                                  │
│                                                                             │
│   Your laptop (office) ─────────────────────┐                              │
│   Your phone (company WiFi) ────────────────┤                              │
│   Cloud VM in same VPC ─────────────────────┤                              │
│   On-prem server (via VPN) ─────────────────┤                              │
│                                             │                              │
│                                             ▼                              │
│                              ┌────────────────────────────┐                │
│                              │ INTERNAL APPLICATION LB    │                │
│                              │ (Google Managed, L7)       │                │
│                              │ TLS terminated here        │                │
│                              │ IP: 10.0.15.30 (private)   │                │
│                              │ Pre-shared SSL cert        │                │
│                              └────────────┬───────────────┘                │
│                                           │                                │
│                                           │ HTTP (inside VPC)              │
│                                           │ Pod IP directly (NEG)          │
│                                           ▼                                │
│                              ┌────────────────────────────┐                │
│                              │  GKE NODE (no kube-proxy)  │                │
│                              │  Traffic goes to Pod IP    │                │
│                              │  (Container Native LB)     │                │
│                              └────────────┬───────────────┘                │
│                                           │                                │
│                                           ▼                                │
│                              ┌────────────────────────────┐                │
│                              │  ArgoCD Server Pod         │                │
│                              │  (--insecure, HTTP only)   │                │
│                              └────────────────────────────┘                │
│                                                                             │
│   GOOGLE MANAGED PROXY VMS LIVE IN PROXY-ONLY SUBNET: 10.129.0.0/23       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 1.3 Network Resources

| Resource | Purpose | CIDR / Type |
|----------|---------|-------------|
| **GKE Node Subnet** | Where worker nodes live | Your existing subnet (e.g., `10.0.0.0/20`) |
| **Proxy-Only Subnet** | Where Google-managed LB proxies live | `/23` range (e.g., `10.129.0.0/23`) |
| **Regional Static IP** | Stable IP for the load balancer | Reserved in your node subnet |

---

# 2. Traffic Flow

```
Client Browser (VPN)
        │
        │ HTTPS (TLS encrypted)
        ▼
┌──────────────────────────────────┐
│  GCE INTERNAL APPLICATION LB     │
│  ┌──── KPI's at this LB:        │
│  │  • TLS handshake             │
│  │  • Certificate: regional SSL │
│  │  • Host: argocd...internal   │
│  │  • URL map matching          │
│  │  • TLS decrypted here        │
│  └───────────────────────────────┘
│  IP: 10.0.15.30 (reserved)      │
└────────┬─────────────────────────┘
         │ HTTP (now decrypted)
         │ Direct to Pod IP
         ▼
┌──────────────────────────────────┐
│  Network Endpoint Group (NEG)    │
│  ┌──────────────────────────┐   │
│  │ Pod 1: 10.82.1.5:8080    │   │
│  │ Pod 2: 10.82.2.9:8080    │   │
│  └──────────────────────────┘   │
│  Health checked by Google LB    │
└────────┬─────────────────────────┘
         │ HTTP (inside cluster)
         ▼
┌──────────────────────────────────┐
│  ArgoCD Server Pod               │
│  Namespace: argocd               │
│  Flag: --insecure (HTTP only)    │
└──────────────────────────────────┘
```

---

# 3. Resource Sizing

## 3.1 What Runs on This Cluster

| Component | Replicas | CPU Request | Memory Request | Notes |
|-----------|----------|-------------|----------------|-------|
| ArgoCD Controller | 1 | 500m | 512Mi | Core "brain" |
| ArgoCD Server | 1 | 250m | 256Mi | UI + API |
| ArgoCD Repo Server | 1 | 250m | 256Mi | Git → YAML generator |
| ArgoCD Dex | 1 | 50m | 64Mi | Google SSO |
| ArgoCD Redis | 1 | 100m | 128Mi | Cache |
| ApplicationSet | 1 | 100m | 128Mi | Multi-app generator |
| Notifications | 1 | 50m | 64Mi | Slack/email alerts |
| **Total** | **~7** | **~1.3 vCPU** | **~1.4 GiB** | |

**NGINX Ingress Controller has been removed.** Zero pods used for ingress. Google's managed infrastructure handles all L7 traffic.

## 3.2 Recommended Node Types

| Scenario | Machine | Nodes | CPU | RAM | Monthly |
|----------|---------|-------|-----|-----|---------|
| **Demo** | e2-medium | 2 | 2 vCPU | 8 GB | ~$122 |
| **Production** | e2-standard-2 | 3 | 6 vCPU | 24 GB | ~$220 |

> 💡 **Production recommendation**: Use 3 nodes of e2-standard-2 for headroom, rolling updates, and zone spread. The 3rd node provides redundancy — if 1 node fails, ArgoCD stays available.

---

# 4. Phase 1 — Create GKE Cluster

## 4.1 Prerequisites

```bash
gcloud version
kubectl version --client
helm version
```

## 4.2 Authenticate

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
gcloud services enable container.googleapis.com
```

## 4.3 Create the Cluster

> ⚠️ **Critical**: Do NOT disable `HttpLoadBalancing`. GCE Ingress requires it. Do NOT set `--addons` without it.

```bash
export PROJECT_ID="your-project-id"
export GCP_REGION="asia-south1"
export GCP_ZONE="asia-south1-a"
export CLUSTER_NAME="argocd-cluster"
export NETWORK="default"

# Set defaults
gcloud config set project $PROJECT_ID
gcloud config set compute/region $GCP_REGION
gcloud config set compute/zone $GCP_ZONE

# Create the cluster
gcloud container clusters create $CLUSTER_NAME \
  --zone=$GCP_ZONE \
  --release-channel=regular \
  --machine-type=e2-medium \
  --num-nodes=2 \
  --min-nodes=1 \
  --max-nodes=4 \
  --enable-autoscaling \
  --disk-type=pd-standard \
  --disk-size=50 \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
  --enable-shielded-nodes \
  --shielded-secure-boot \
  --shielded-integrity-monitoring \
  --enable-ip-alias \
  --network=$NETWORK \
  --addons=HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver \
  --labels=env=argocd,team=platform,managed-by=gke-ingress

echo "✅ Cluster created: $CLUSTER_NAME"
```

### Why These Flags?

| Flag | Why It Matters |
|------|---------------|
| `--enable-ip-alias` | VPC-native networking — **required** for container-native LB via NEGs |
| `--addons=HttpLoadBalancing` | GKE must create HTTP(S) load balancers — **mandatory** |
| `--network=$NETWORK` | Proxy-only subnet must be in the same network |

## 4.4 Connect kubectl

```bash
gcloud container clusters get-credentials $CLUSTER_NAME --zone=$GCP_ZONE
kubectl get nodes -o wide
```

**Expected output:**
```
NAME                                        STATUS   ROLES    AGE   VERSION
gke-argocd-cluster-default-pool-xxx-yyy     Ready    <none>   1m    v1.31.x
gke-argocd-cluster-default-pool-zzz-www     Ready    <none>   1m    v1.31.x
```

---

# 5. Phase 2 — Prepare Networking (Proxy Subnet + Firewall)

> ⚠️ **This phase is MANDATORY** for GCE Internal Ingress. Without proxy subnet, the Ingress controller cannot deploy the load balancer.

## 5.1 Create Proxy-Only Subnet

Google-managed proxy VMs for the Internal Application Load Balancer need a dedicated subnet.

```bash
# Check if a proxy-only subnet already exists
gcloud compute networks subnets list --network=$NETWORK --purpose=REGIONAL_MANAGED_PROXY

# If none exists, create one
gcloud compute networks subnets create argocd-proxy-subnet \
    --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE \
    --region=$GCP_REGION \
    --network=$NETWORK \
    --range=10.129.0.0/23 \
    --description="Proxy-only subnet for Google Internal Application Load Balancers"

echo "✅ Proxy-only subnet created in $NETWORK"
```

### Why `/23`?

Google recommends a `/23` (512 IPs) proxy-only subnet for regional purposes. This is pre-reserved and **does not cost extra** — it's just a subnet range.

### Verify

```bash
gcloud compute networks subnets describe argocd-proxy-subnet \
    --region=$GCP_REGION --network=$NETWORK --format='table(name,purpose,region,ipCidrRange)'
```

**Expected output:**
```
NAME                   PURPOSE                 REGION        IP_CIDR_RANGE
argocd-proxy-subnet    REGIONAL_MANAGED_PROXY  asia-south1   10.129.0.0/23
```

## 5.2 Create Firewall Rule for Proxy Subnet

The proxy VMs need to reach your ArgoCD pods. Without this firewall rule, health checks fail and traffic is dropped.

```bash
gcloud compute firewall-rules create allow-proxy-to-argocd \
    --allow=tcp:8080,tcp:80 \
    --source-ranges=10.129.0.0/23 \
    --network=$NETWORK \
    --direction=INGRESS \
    --priority=900 \
    --description="Allow Google proxy VMs to reach ArgoCD pods for internal LB" \
    --target-tags=gke-argocd-cluster-node

echo "✅ Firewall rule created"
```

> ⚠️ **The target-tag** should match your GKE node tags. Run `gcloud compute firewall-rules list --filter='targetTags~gke'` to find the correct tag for your cluster's nodes.

## 5.3 Create Firewall Rule for Google Health Checks

Google health check probes need to verify your pods are healthy.

```bash
gcloud compute firewall-rules create allow-gcp-health-checks \
    --allow=tcp:8080,tcp:80 \
    --source-ranges=130.211.0.0/22,35.191.0.0/16 \
    --network=$NETWORK \
    --direction=INGRESS \
    --priority=910 \
    --description="Allow Google health check probes to reach ArgoCD pods" \
    --target-tags=gke-argocd-cluster-node

echo "✅ Health-check firewall rule created"
```

### Verify Firewall Rules

```bash
gcloud compute firewall-rules list --filter='name~allow-proxy OR name~allow-gcp' --format='table(name,sourceRanges,allowed,direction)'
```

---

# 6. Phase 3 — Generate Certificates

## 6.1 Self-Signed Certificate (For Demo)

```bash
mkdir -p certs

# Private key
openssl genrsa -out certs/argocd.key 2048

# Self-signed certificate (365 days)
openssl req -new -x509 -key certs/argocd.key -out certs/argocd.crt -days 365 \
  -subj "/C=IN/ST=MH/L=Mumbai/O=YourCompany/CN=argocd.yourcompany.internal"

ls -la certs/
```

**Output:**
```
-rw------- 1 user user 1704 Jun 20 10:00 argocd.key
-rw-r--r-- 1 user user 1302 Jun 20 10:00 argocd.crt
```

## 6.2 Customer CA Certificate (For Production)

When your client provides `company.crt` and `company.key`:

```bash
# Place client-provided certs in certs/ directory
# Replace the self-signed certs

gcloud compute ssl-certificates create argocd-production-cert \
    --certificate certs/company.crt \
    --private-key certs/company.key \
    --region=$GCP_REGION
```

> ✅ **No Kubernetes changes needed** — just update the cert name in the Ingress annotation later.

---

# 7. Phase 4 — Create GCP Resources (Static IP + SSL Cert)

## 7.1 Reserve Regional Static Internal IP

Without a static IP, the LB gets an ephemeral IP that changes if you delete/recreate the Ingress.

```bash
gcloud compute addresses create argocd-internal-ip \
    --region=$GCP_REGION \
    --subnet=default \
    --purpose=GCE_ENDPOINT \
    --description="Static internal IP for ArgoCD Internal Application LB"

echo "✅ Static IP reserved"
```

### Verify

```bash
gcloud compute addresses describe argocd-internal-ip --region=$GCP_REGION --format='table(name,address,addressType,status,purpose)'
```

**Expected output:**
```
NAME               ADDRESS       ADDRESS_TYPE  STATUS   PURPOSE
argocd-internal-ip  10.0.15.30    INTERNAL      IN_USE   GCE_ENDPOINT
```

## 7.2 Upload Regional SSL Certificate

> ⚠️ **GCE Internal Ingress does NOT support Google-managed certificates** (Let's Encrypt). It only supports regional pre-shared certificates.

```bash
gcloud compute ssl-certificates create argocd-selfsigned-cert \
    --certificate certs/argocd.crt \
    --private-key certs/argocd.key \
    --region=$GCP_REGION \
    --description="Self-signed certificate for ArgoCD internal ingress (demo)"

echo "✅ Regional SSL certificate uploaded"
```

### Verify

```bash
gcloud compute ssl-certificates list --filter='name=argocd-selfsigned-cert' --region=$GCP_REGION --format='table(name,type,creationTimestamp)'
```

### List Certificates (to confirm)

```bash
gcloud compute ssl-certificates list --region=$GCP_REGION --format='table(name,type)'
```

---

# 8. Phase 5 — Install ArgoCD (With GCE Internal Ingress)

## 8.1 Add ArgoCD Helm Repository

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

## 8.2 Create Production argocd-values.yaml

> ⚠️ **Key differences from NGINX approach:**
> - `kubernetes.io/ingress.class: "gce-internal"` instead of `ingressClassName: nginx`
> - `ingress.gcp.kubernetes.io/pre-shared-cert` instead of K8s TLS Secret
> - `cloud.google.com/neg` annotation on Service (added separately because Helm values may not support Service annotations)
> - `tls: false` — TLS is handled by the regional pre-shared cert, NOT K8s Secret

Create `argocd-values.yaml`:

```yaml
global:
  domain: argocd.yourcompany.internal

controller:
  replicas: 1
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi

server:
  replicas: 1
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 1Gi

  # ArgoCD runs HTTP internally. TLS is terminated at the LB.
  extraArgs:
    - --insecure

  # ===========================================
  # GCE INTERNAL INGRESS CONFIGURATION
  # ===========================================
  # GCE Ingress is built into GKE — no separate controller install needed.
  # Uses annotation-based class (not ingressClassName field).
  # TLS handled via regional pre-shared cert uploaded to GCP.
  ingress:
    enabled: true
    ingressClassName: ""   # Not supported by GCE Ingress
    hostname: argocd.yourcompany.internal
    tls: false             # TLS handled by pre-shared cert annotation, NOT K8s secret

    annotations:
      # Ingress class — this tells GKE to use the built-in controller
      kubernetes.io/ingress.class: "gce-internal"

      # Associate regional pre-shared SSL certificate
      ingress.gcp.kubernetes.io/pre-shared-cert: "argocd-selfsigned-cert"

      # Force HTTPS only (disable HTTP)
      kubernetes.io/ingress.allow-http: "false"

      # Use the reserved static internal IP
      kubernetes.io/ingress.regional-static-ip-name: "argocd-internal-ip"

      # Associate FrontendConfig (for HTTPS redirect + WebSocket timeouts)
      networking.gke.io/v1beta1.FrontendConfig: "argocd-frontend-config"

repoServer:
  replicas: 1
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 1Gi

dex:
  enabled: true
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi

applicationSet:
  enabled: true
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi

notifications:
  enabled: true

configs:
  cm:
    # Keep local admin enabled until SSO is verified
    admin.enabled: "true"
    timeout.reconciliation: 180s
    application.resourceTrackingMethod: label
  params:
    server.insecure: true
  secret:
    createSecret: true
```

## 8.3 Create Namespace and Install

```bash
# Create namespace
kubectl create namespace argocd

# Apply BackendConfig and FrontendConfig BEFORE ArgoCD install
# (We'll create these in Phase 6)
```

> ⚠️ **IMPORTANT ORDER**: BackendConfig and FrontendConfig must exist BEFORE the Ingress is created. So we create them FIRST.

## 8.4 Deploy BackendConfig, FrontendConfig, and ArgoCD (in order)

### Step A: Create BackendConfig

```bash
cat > argocd-backendconfig.yaml << 'EOF'
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: argocd-backend-config
  namespace: argocd
spec:
  healthCheck:
    checkIntervalSec: 10
    timeoutSec: 5
    healthyThreshold: 2
    unhealthyThreshold: 3
    type: HTTP
    requestPath: /healthz
    port: 8080
  timeoutSec: 300
EOF

kubectl apply -f argocd-backendconfig.yaml
```

> ⚠️ **Port is 8080** — this is ArgoCD's container port (NOT the Service Port 80). GCE Ingress uses container native load balancing which routes to the pod's container port.

### Step B: Create FrontendConfig

```bash
cat > argocd-frontendconfig.yaml << 'EOF'
apiVersion: networking.gke.io/v1beta1
kind: FrontendConfig
metadata:
  name: argocd-frontend-config
  namespace: argocd
spec:
  # Force HTTP to HTTPS redirect
  redirectToHttps:
    enabled: true
    responseCodeName: MOVED_PERMANENTLY_DEFAULT
EOF

kubectl apply -f argocd-frontendconfig.yaml
```

### Step C: Install ArgoCD

```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.8.10 \
  --values argocd-values.yaml \
  --wait --timeout 10m
```

### Step D: Add NEG Annotation to ArgoCD Service

ArgoCD Helm chart creates a Service named `argocd-server` in the `argocd` namespace. We need to add the NEG annotation so GCE Ingress can use container-native load balancing.

```bash
# Patch the ArgoCD server service to enable NEG
kubectl patch service argocd-server -n argocd --type='merge' -p '{
  "metadata": {
    "annotations": {
      "cloud.google.com/neg": "{\"ingress\": true}",
      "cloud.google.com/backend-config": "{\"default\": \"argocd-backend-config\"}"
    }
  }
}'
```

> ⚠️ **Why after Helm install?** The Service is created by the Helm chart. We patch it after. Alternatively, you can create the Service first with annotations, but Helm usually manages it. Patching post-install is cleaner for production.

## 8.5 Verify Ingress Is Being Provisioned

```bash
# Watch the Ingress as it provisions (takes 2–5 minutes)
kubectl get ingress argocd-server -n argocd -w
```

**Expected progression:**
```
NAME             CLASS   HOSTS                          ADDRESS   PORTS     AGE
argocd-server    None    argocd.yourcompany.internal              80        10s
argocd-server    None    argocd.yourcompany.internal              80,443    1m
argocd-server    None    argocd.yourcompany.internal    10.0.15.30  80,443    3m
```

**Final state must show:**
- `ADDRESS` = your reserved static IP (e.g., `10.0.15.30`)
- `PORTS` = `80,443`
- No error events

## 8.6 Verify Ingress Events

```bash
kubectl get events --field-selector involvedObject.kind=Ingress,involvedObject.name=argocd-server -n argocd
```

**Expected:** No errors. Possible progress messages like:
```
IngressSynced       Successfully synced NEGs
```

## 8.7 Verify Backend Health

```bash
kubectl get ing argocd-server -n argocd -o yaml | grep -A5 'ingress.kubernetes.io/backends'
```

**Expected (all backends should say `HEALTHY`):**
```yaml
ingress.kubernetes.io/backends: '{"k8s1-241a2b5c-argocd-argocd-server-80-xxxx":"HEALTHY"}'
```

If it says `UNHEALTHY`, check:
1. `kubectl get pods -n argocd` — all ArgoCD pods must be `1/1 Running`
2. Firewall rules for health checks
3. BackendConfig port matches ArgoCD container port (8080)

## 8.8 Verify All ArgoCD Pods

```bash
kubectl get pods -n argocd
```

**Expected:**
```
NAME                                                READY   STATUS
argocd-application-controller-0                     1/1     Running
argocd-applicationset-controller-xxx                1/1     Running
argocd-dex-server-xxx                               1/1     Running
argocd-notifications-controller-xxx                 1/1     Running
argocd-redis-xxx                                    1/1     Running
argocd-repo-server-xxx                              1/1     Running
argocd-server-xxx                                   1/1     Running
```

## 8.9 Get the Internal LB IP

```bash
export ARGOCD_INTERNAL_IP=$(kubectl get ingress argocd-server \
  -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "ArgoCD Internal IP: $ARGOCD_INTERNAL_IP"
```

## 8.10 Test from Inside the Cluster

```bash
kubectl run test-pod --image=curlimages/curl -it --rm -- \
  -k -I https://$ARGOCD_INTERNAL_IP \
  --resolve argocd.yourcompany.internal:443:$ARGOCD_INTERNAL_IP
```

**Expected output:**
```
HTTP/2 307
location: https://argocd.yourcompany.internal/login
```

A `307` or `200` confirms: LB → Health checks → ArgoCD are all working.

---

# 9. Phase 6 — Create BackendConfig & FrontendConfig

> ⚠️ **This phase is already done in Phase 5.8.4 (steps A and B).** It is called out separately here for clarity — in production, you should apply BackendConfig + FrontendConfig BEFORE Helm install.

## 9.1 BackendConfig Explained

| Field | Value | Why |
|-------|-------|-----|
| `type: HTTP` | Protocol | ArgoCD's `/healthz` responds to HTTP |
| `requestPath: /healthz` | Health endpoint | ArgoCD built-in health check path |
| `port: 8080` | Container port | Must match ArgoCD server's container port |
| `checkIntervalSec: 10` | Check every 10s | Frequent enough for fast recovery |
| `timeoutSec: 5` | 5s timeout | Must be < checkIntervalSec |
| `timeoutSec: 300` | Backend timeout | Idle timeout for connections |

## 9.2 FrontendConfig Explained

| Field | Value | Why |
|-------|-------|-----|
| `redirectToHttps.enabled: true` | Force HTTPS | All HTTP traffic redirects to HTTPS |
| `responseCodeName: MOVED_PERMANENTLY_DEFAULT` | 301 redirect | Standard redirect behavior |

> 💡 For WebSocket timeout config: ArgoCD uses WebSockets for live sync. If you see stale UIs, increase timeout in FrontendConfig. But GCE Internal LB's default timeouts (generous) are usually sufficient.

---

# 10. Phase 7 — Google SSO

## 10.1 Create OAuth App in Google Cloud

Follow the same steps as the NGINX guide. Key setup:

1. Go to https://console.cloud.google.com/apis/credentials/consent
2. Create **Internal** OAuth consent screen
3. Add scopes: `openid`, `userinfo.profile`, `userinfo.email`
4. Create **Web application** OAuth Client ID
5. **Authorized redirect URIs**:
   - `http://localhost:8080/api/dex/callback` (for testing)
   - `https://argocd.yourcompany.internal/api/dex/callback` (production)

## 10.2 Store OAuth Secret in Kubernetes

```bash
export GOOGLE_CLIENT_ID="your-client-id.apps.googleusercontent.com"
export GOOGLE_CLIENT_SECRET="your-client-secret"

kubectl create secret generic google-oauth \
  --namespace argocd \
  --from-literal=dex.google.clientSecret="$GOOGLE_CLIENT_SECRET"
```

## 10.3 Configure Dex in ArgoCD

Create `argocd-cm-patch.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: "https://argocd.yourcompany.internal"
  dex.config: |
    connectors:
      - type: google
        id: google
        name: Google
        config:
          clientID: YOUR_GOOGLE_CLIENT_ID
          clientSecret: $google-oauth:dex.google.clientSecret
          redirectURI: https://argocd.yourcompany.internal/api/dex/callback
          hostedDomains:
            - yourcompany.com
```

Apply:
```bash
sed -i "s/YOUR_GOOGLE_CLIENT_ID/$GOOGLE_CLIENT_ID/g" argocd-cm-patch.yaml
kubectl apply -f argocd-cm-patch.yaml
```

## 10.4 Restart ArgoCD Dex & Server

```bash
kubectl rollout restart deployment argocd-dex-server -n argocd
kubectl rollout restart deployment argocd-server -n argocd

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-dex-server -n argocd --timeout=120s
```

## 10.5 Test Login via Port-Forward

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open `http://localhost:8080` → Click **"LOG IN VIA GOOGLE"** → Authorize → Should redirect to ArgoCD.

## 10.6 Disable Local Admin (After SSO Verified)

```bash
kubectl patch configmap argocd-cm -n argocd \
  --type merge -p '{"data":{"admin.enabled":"false"}}'

kubectl rollout restart deployment argocd-server -n argocd
```

> ⚠️ **DON'T do this until Google login works at least once.**

If locked out:
```bash
kubectl patch configmap argocd-cm -n argocd \
  --type merge -p '{"data":{"admin.enabled":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
```

---

# 11. Phase 8 — RBAC

Create `argocd-rbac.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly

  policy.csv: |
    # ADMIN ROLE
    p, role:admin, applications, *, */*, allow
    p, role:admin, projects, *, *, allow
    p, role:admin, repositories, *, *, allow
    p, role:admin, certificates, *, *, allow
    p, role:admin, accounts, *, *, allow
    p, role:admin, gpgkeys, *, *, allow
    p, role:admin, exec, create, */*, allow

    # DEVELOPER ROLE
    p, role:developer, applications, get, */*, allow
    p, role:developer, applications, sync, */*, allow
    p, role:developer, applications, rollback, */*, allow
    p, role:developer, projects, get, *, allow
    p, role:developer, repositories, get, *, allow
    p, role:developer, applications, create, */*, deny
    p, role:developer, applications, delete, */*, deny
    p, role:developer, applications, update, */*, deny
    p, role:developer, projects, create, *, deny
    p, role:developer, projects, delete, *, deny

    # READONLY ROLE
    p, role:readonly, applications, get, */*, allow
    p, role:readonly, projects, get, *, allow
    p, role:readonly, repositories, get, *, allow

    # GROUP MAPPINGS
    g, devops@yourcompany.com, role:admin
    g, developers@yourcompany.com, role:developer
    g, auditors@yourcompany.com, role:readonly

  scopes: "[email, groups]"
EOF

kubectl apply -f argocd-rbac.yaml
```

Restart server:
```bash
kubectl rollout restart deployment argocd-server -n argocd
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s
```

---

# 12. Phase 9 — Verification

## 12.1 Full Checklist

```
□ GKE cluster created with VPC-native networking (--enable-ip-alias)
□ HttpLoadBalancing addon is enabled
□ kubectl connected to cluster
□ Proxy-only subnet created in same region & network
□ Firewall rules: proxy subnet → pods AND health checks → pods
□ Self-signed certs generated
□ Regional static IP reserved
□ Regional SSL certificate uploaded to GCP
□ BackendConfig created with health check at /healthz:8080
□ FrontendConfig created with redirectToHttps enabled
□ ArgoCD installed via Helm with gce-internal ingress
□ ArgoCD service patched with NEG annotation
□ Ingress shows internal IP with no errors
□ Backend health check shows HEALTHY
□ Google OAuth app created with redirect URIs
□ Dex configured with Google connector
□ SSO login works (admin account disabled after)
□ RBAC ConfigMap applied
□ All roles tested (admin / developer / readonly)
```

## 12.2 Verify GCP Load Balancer Resources

```bash
# See the actual GCP resources GKE created
gcloud compute forwarding-rules list --filter='IPAddress=10.0.15.30' --region=$GCP_REGION
gcloud compute backend-services list --filter='name ~ k8s1.*argocd' --region=$GCP_REGION
gcloud compute target-http-proxies list --filter='name ~ k8s-tp.*argocd' --region=$GCP_REGION
gcloud compute ssl-certificates list --filter='name=argocd-selfsigned-cert' --region=$GCP_REGION
```

## 12.3 Health Check Details

```bash
# Get backend service name
BACKEND=$(gcloud compute backend-services list \
  --filter='name ~ k8s1.*argocd.*server' \
  --region=$GCP_REGION --format='value(name)')

# Check health status
gcloud compute backend-services get-health $BACKEND --region=$GCP_REGION
```

**Expected:** All backends show `healthState: HEALTHY`.

---

# 13. Phase 10 — Production Hardening

## 13.1 Certificate Rotation

When your client provides production certificates:

```bash
# Step 1: Upload new production cert
gcloud compute ssl-certificates create argocd-production-cert \
    --certificate certs/company-ca.crt \
    --private-key certs/company-ca.key \
    --region=$GCP_REGION

# Step 2: Update Ingress to use production cert
kubectl patch ingress argocd-server -n argocd --type='merge' -p '{
  "metadata": {
    "annotations": {
      "ingress.gcp.kubernetes.io/pre-shared-cert": "argocd-production-cert"
    }
  }
}'

# Step 3: Remove old cert (after confirming new one works)
gcloud compute ssl-certificates delete argocd-selfsigned-cert --region=$GCP_REGION
```

> No Helm reinstall needed — just patch the annotation.

## 13.2 WebSocket Configuration (For Live Sync)

If ArgoCD's live sync UI lags or disconnects, adjust FrontendConfig:

```bash
cat > argocd-frontendconfig-updated.yaml << 'EOF'
apiVersion: networking.gke.io/v1beta1
kind: FrontendConfig
metadata:
  name: argocd-frontend-config
  namespace: argocd
spec:
  redirectToHttps:
    enabled: true
    responseCodeName: MOVED_PERMANENTLY_DEFAULT
  # Add timeout config if needed for WebSockets
  # GCE LB has generous defaults, but if you see issues:
  # connectionTimeout: 300
EOF

kubectl apply -f argocd-frontendconfig-updated.yaml
```

## 13.3 Terraform / IaC Reproducibility

For production, automate this with Terraform or Cloud Deployment Manager:

| GCP Resource | Terraform Resource |
|-------------|-------------------|
| Proxy-only subnet | `google_compute_subnetwork` with `purpose = "REGIONAL_MANAGED_PROXY"` |
| Firewall rules | `google_compute_firewall` |
| Regional static IP | `google_compute_address` with `purpose = "GCE_ENDPOINT"` |
| Regional SSL cert | `google_compute_region_ssl_certificate` |
| GKE cluster | `google_container_cluster` (ensure `http_load_balancing` is enabled) |
| K8s resources | Helm provider + kubernetes provider |

## 13.4 Monitoring & Alerting

```bash
# Monitor LB health check failures
gcloud monitoring dashboards create \
  --dashboard-json='{
    "displayName": "ArgoCD Internal LB",
    "gridLayout": {
      "columns": "2",
      "widgets": [
        {
          "title": "Backend Health",
          "xyChart": {
            "dataSets": [{
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"http_lb_rule\" AND metric.type=\"loadbalancing.googleapis.com/https/backend_request_count\"",
                  "aggregation": {
                    "alignmentPeriod": "60s",
                    "perSeriesAligner": "ALIGN_RATE"
                  }
                }
              }
            }]
          }
        }
      ]
    }
  }'
```

---

# 14. Accessing ArgoCD from Your Laptop

Since the LB is **internal only**, your laptop cannot reach it directly unless on VPN.

## Option 1: kubectl port-forward (Admin Only)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open `http://localhost:8080` on your laptop.

> ⚠️ Bypasses Ingress, SSO, and TLS entirely. Admin use only.

## Option 2: VPN / Company Network

```bash
# Add to your laptop's /etc/hosts
echo "$ARGOCD_INTERNAL_IP argocd.yourcompany.internal" | sudo tee -a /etc/hosts

# Open browser
open https://argocd.yourcompany.internal
# (Accept self-signed cert warning for demo)
```

## Option 3: Cloud IAP (Production)

For employees who need access without full VPN, Cloud IAP (Identity-Aware Proxy) sits in front:
1. IAP authenticates employees with Google accounts
2. IAP forwards request to internal LB
3. No VPN required

Out of scope for demo but worth evaluating for production.

---

# 15. Cost Estimate

| Line Item | Detail | Monthly Cost (USD) | ~Monthly (₹) |
|-----------|--------|-------------------|--------------|
| GKE cluster management | $0.10/hr × 730 | **$73.00** | **~₹6,088** |
| 2 × e2-medium nodes | $0.0335/hr × 730 × 2 | **$48.91** | **~₹4,079** |
| Boot disks 2 × 50 GB | $0.040/GB × 50 × 2 | **$4.00** | **~₹334** |
| Internal Application LB | Forwarding rule: $0.025/hr × 730 | **$18.25** | **~₹1,522** |
| Regional static IP | Free when attached | **$0** | **₹0** |
| Proxy-only subnet | No cost | **$0** | **₹0** |
| SSL certificate | No cost (self-managed) | **$0** | **₹0** |
| **Total** | | **~$144** | **~₹12,023** |

## Cost Comparison: NGINX vs GCE Internal

| Cost Factor | NGINX | GCE Internal | Difference |
|-------------|-------|-------------|------------|
| LB forwarding rule | ~$18.25/mo | ~$18.25/mo | Same |
| NGINX pod CPU/memory | ~10–50m CPU, ~128Mi RAM | **$0** | Saves cluster resources |
| Total delta | Baseline | **Same to -$5/mo** | GCE saves by removing proxy pod |

> 💡 **Savings are minimal (~$0–5/mo)**. The real value is operational: no pod to maintain, Google manages all upgrades/patching, and container-native LB gives lower latency.

---

# 16. Troubleshooting

## 16.1 Ingress ADDRESS Empty or Stuck

```bash
# Check Ingress events
kubectl get events --field-selector involvedObject.kind=Ingress -n argocd --sort-by='.firstTimestamp'
```

**Common causes:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ADDRESS` stays empty | Proxy-only subnet missing | Create it (Phase 2.5.1) |
| `ADDRESS` stays empty | SSL cert doesn't exist in region | Upload cert (Phase 4.7.2) |
| `ADDRESS` stays empty | Static IP doesn't exist | Reserve it (Phase 4.7.1) |
| `ADDRESS` stays empty | HttpLoadBalancing addon disabled | Re-enable it on the cluster |
| Error: `failed to sync NEG` | ArgoCD Service lacks NEG annotation | Patch service (Phase 5.8.4 Step D) |
| Error: `NEG not found` | Service didn't get NEG injected | Check if mutating webhook exists |

## 16.2 Backend Shows UNHEALTHY

```bash
# Check which backend is unhealthy
kubectl get ing argocd-server -n argocd -o yaml | grep -A3 'ingress.kubernetes.io/backends'
```

**Fix checklist:**
1. `kubectl get pods -n argocd` — all pods Ready?
2. `kubectl describe pod argocd-server-xxx -n argocd` — look at readiness probe
3. `curl http://localhost:8080/healthz` inside the ArgoCD pod:
   ```bash
   kubectl exec -it deployment/argocd-server -n argocd -- curl -s http://localhost:8080/healthz
   ```
   Should return `ok`
4. Firewall rules for `130.211.0.0/22` and `35.191.0.0/16` must allow port 8080
5. Firewall rule for proxy subnet `10.129.0.0/23` must allow port 8080

## 16.3 502 Bad Gateway

Cause: LB can reach backend but backend is rejecting traffic.

```bash
# Check ArgoCD pod logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50
```

Possible fixes:
- Pod is crashing: `kubectl describe pod argocd-server-xxx -n argocd`
- ArgoCD running in TLS mode internally but LB sends HTTP: ensure `server.insecure: true`
- Backend timeout too low: increase `timeoutSec` in BackendConfig

## 16.4 Certificate Not Trusted / SSL Error

With self-signed certs, browsers show the "Your connection is not private" warning. This is **expected** for internal/demo:

- Click **Advanced** → **Proceed**
- Or add the certificate to your OS trust store:
  ```bash
  # macOS
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain certs/argocd.crt

  # Linux (Ubuntu)
  sudo cp certs/argocd.crt /usr/local/share/ca-certificates/argocd-internal.crt
  sudo update-ca-certificates
  ```

## 16.5 SSO Button Missing

```bash
# Check argocd-cm configmap
kubectl get cm argocd-cm -n argocd -o yaml | grep -A2 'url:'
```

The `url` field must be set: `https://argocd.yourcompany.internal`

## 16.6 Redirect URI Mismatch

In Google Console → Credentials → Authorized redirect URIs, ensure:
```
https://argocd.yourcompany.internal/api/dex/callback
```

> ⚠️ Must match the `url` in `argocd-cm` exactly.

## 16.7 Orphaned GCP Resources After Deletion

> ⚠️ **Critical**: When you delete the Ingress, GKE should clean up all LB resources. But if Terraform or kubectl fails, resources may be orphaned.

```bash
# List all LB resources
gcloud compute forwarding-rules list --region=$GCP_REGION
gcloud compute target-http-proxies list --region=$GCP_REGION
gcloud compute target-https-proxies list --region=$GCP_REGION
gcloud compute backend-services list --region=$GCP_REGION
gcloud compute url-maps list --region=$GCP_REGION

# Delete orphaned resources manually (ADVANCED)
gcloud compute forwarding-rules delete RULE_NAME --region=$GCP_REGION
gcloud compute backend-services delete SERVICE_NAME --region=$GCP_REGION
```

## 16.8 Quick Diagnostic Command

```bash
echo "=== INGRESS ==="
kubectl get ingress argocd-server -n argocd -o yaml | grep -E 'address|annotations|backends'

echo "=== PODS ==="
kubectl get pods -n argocd

echo "=== SERVICE ==="
kubectl get service argocd-server -n argocd -o yaml | grep -E 'annotations|neg|backend-config'

echo "=== BACKEND CONFIG ==="
kubectl get backendconfig argocd-backend-config -n argocd -o yaml

echo "=== FRONTEND CONFIG ==="
kubectl get frontendconfig argocd-frontend-config -n argocd -o yaml

echo "=== GCP RESOURCES ==="
gcloud compute forwarding-rules list --filter='name ~ k8s.*argocd' --region=$GCP_REGION --format='table(name,target)' 2>/dev/null || echo "No MISC rules"
```

---

# 17. Command Cheat Sheet

```bash
# ===== ENVIRONMENT =====
export PROJECT_ID="your-project-id"
export GCP_REGION="asia-south1"
export GCP_ZONE="asia-south1-a"
export CLUSTER_NAME="argocd-cluster"
export NETWORK="default"

gcloud config set project $PROJECT_ID
gcloud config set compute/region $GCP_REGION
gcloud config set compute/zone $GCP_ZONE

# ===== CLUSTER =====
gcloud container clusters create $CLUSTER_NAME \
  --zone=$GCP_ZONE --machine-type=e2-medium --num-nodes=2 \
  --enable-ip-alias --network=$NETWORK \
  --addons=HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver

gcloud container clusters get-credentials $CLUSTER_NAME --zone=$GCP_ZONE
kubectl get nodes

# ===== PROXY SUBNET =====
gcloud compute networks subnets create argocd-proxy-subnet \
  --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE --region=$GCP_REGION \
  --network=$NETWORK --range=10.129.0.0/23

# ===== FIREWALL =====
gcloud compute firewall-rules create allow-proxy-to-argocd \
  --allow=tcp:8080 --source-ranges=10.129.0.0/23 --network=$NETWORK \
  --priority=900 --target-tags=gke-argocd-cluster-node

gcloud compute firewall-rules create allow-gcp-health-checks \
  --allow=tcp:8080 --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --network=$NETWORK --priority=910 --target-tags=gke-argocd-cluster-node

# ===== CERTIFICATES =====
mkdir -p certs
openssl genrsa -out certs/argocd.key 2048
openssl req -new -x509 -key certs/argocd.key -out certs/argocd.crt -days 365 \
  -subj "/C=IN/ST=MH/L=Mumbai/O=YourCompany/CN=argocd.yourcompany.internal"

# ===== GCP RESOURCES =====
gcloud compute addresses create argocd-internal-ip \
  --region=$GCP_REGION --subnet=default --purpose=GCE_ENDPOINT

gcloud compute ssl-certificates create argocd-selfsigned-cert \
  --certificate certs/argocd.crt --private-key certs/argocd.key --region=$GCP_REGION

# ===== ARGOCD =====
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update

# Apply BackendConfig & FrontendConfig FIRST
kubectl create namespace argocd
kubectl apply -f argocd-backendconfig.yaml
kubectl apply -f argocd-frontendconfig.yaml

# Install ArgoCD
helm install argocd argo/argo-cd \
  --namespace argocd --version 7.8.10 --values argocd-values.yaml \
  --wait --timeout 10m

# Patch ArgoCD service with NEG annotation
kubectl patch service argocd-server -n argocd --type='merge' -p '{
  "metadata": {
    "annotations": {
      "cloud.google.com/neg": "{\"ingress\": true}",
      "cloud.google.com/backend-config": "{\"default\": \"argocd-backend-config\"}"
    }
  }
}'

# Verify
kubectl get ingress argocd-server -n argocd
kubectl get pods -n argocd
argocd admin initial-password -n argocd

# ===== CONFIG =====
kubectl apply -f argocd-cm-patch.yaml
kubectl apply -f argocd-rbac.yaml

# ===== SECRETS =====
kubectl create secret generic google-oauth -n argocd \
  --from-literal=dex.google.clientSecret="SECRET"

# ===== RESTARTS =====
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout restart deployment argocd-dex-server -n argocd

# ===== PORT-FORWARD (admin bypass) =====
kubectl port-forward svc/argocd-server -n argocd 8080:80

# ===== TEST INTERNAL ACCESS =====
export ARGOCD_INTERNAL_IP=$(kubectl get ingress argocd-server \
  -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

kubectl run test-pod --image=curlimages/curl -it --rm -- \
  -k -I https://$ARGOCD_INTERNAL_IP \
  --resolve argocd.yourcompany.internal:443:$ARGOCD_INTERNAL_IP

# ===== CLEANUP =====
helm uninstall argocd -n argocd
kubectl delete -f argocd-backendconfig.yaml
kubectl delete -f argocd-frontendconfig.yaml
kubectl delete namespace argocd

# GCP resources (delete Ingress first to avoid orphans)
kubectl delete ingress --all -n argocd || true
gcloud compute addresses delete argocd-internal-ip --region=$GCP_REGION
gcloud compute ssl-certificates delete argocd-selfsigned-cert --region=$GCP_REGION
gcloud compute networks subnets delete argocd-proxy-subnet --region=$GCP_REGION
gcloud compute firewall-rules delete allow-proxy-to-argocd
gcloud compute firewall-rules delete allow-gcp-health-checks
gcloud container clusters delete $CLUSTER_NAME --zone=$GCP_ZONE
```

---

**End of Production Guide.**

> 💡 **Certificate swap**: Upload new regional cert → patch Ingress annotation → delete old cert. No Helm reinstall.
>
> 💡 **Never skip proxy subnet + firewall rules** — without these, GCE Internal Ingress cannot provision.
>
> 💡 **Always reserve static IP + pre-shared SSL cert** — ephemeral resources cause issues in production.
>
> 💡 **Verify backend health** — `UNHEALTHY` backends mean 502 errors for users.
>
> 💡 **Monitor Ingress events** — `kubectl get events` is your friend when things go wrong.
