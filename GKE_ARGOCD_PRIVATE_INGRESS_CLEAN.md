# ArgoCD on GKE — Internal-Only Secure Setup (Clean / No Redundancy)

> **Goal**: Deploy ArgoCD on a single-region, 2-node GKE cluster with **internal-only** access, Google SSO, RBAC, and TLS. Private ingress only — no public internet exposure. VPN required for access.
>
> **Scope**: ArgoCD control plane only. Dev / UAT / Prod workload clusters are out of scope.
>
> **Access Pattern**: NO public internet. Only your company network (VPC/VPN) can reach ArgoCD.
>
> **Region**: Single region. Examples use `asia-south1` (Mumbai).
>
> **Date**: June 2026

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Resource Sizing](#2-resource-sizing)
3. [Phase 1 — Create GKE Cluster](#3-phase-1--create-gke-cluster)
4. [Phase 2 — Install Internal NGINX Ingress Controller](#4-phase-2--install-internal-nginx-ingress-controller)
5. [Phase 3 — Generate Self-Signed Certificates](#5-phase-3--generate-self-signed-certificates)
6. [Phase 4 — Install ArgoCD (With Built-In Ingress)](#6-phase-4--install-argocd-with-built-in-ingress)
7. [Phase 5 — Google SSO](#5-phase-5--google-sso)
8. [Phase 6 — RBAC](#6-phase-6--rbac)
9. [Phase 7 — Verification](#7-phase-7--verification)
10. [Accessing ArgoCD from Your Laptop](#8-accessing-argocd-from-your-laptop)
11. [Cost Estimate](#9-cost-estimate)
12. [Troubleshooting](#10-troubleshooting)
13. [Command Cheat Sheet](#11-command-cheat-sheet)

---

# 1. Architecture Overview

## 1.1 Why Internal-Only?

| Aspect | Public | Private (Internal) |
|--------|--------|--------------------|
| **IP Address** | `34.120.x.x` (internet-routable) | `10.x.x.x` (VPC-private only) |
| **Who can access?** | Anyone on the internet | Only devices inside the same VPC or connected via VPN |
| **Google Cloud equivalent** | External HTTP(S) Load Balancer | Internal Load Balancer |
| **Security** | Needs WAF, DDoS protection | Already isolated from the internet |

## 1.2 How the Traffic Flows

```
Your Laptop (VPN connected)
        │
        ▼
┌─────────────────────────────┐
│  GOOGLE INTERNAL LOAD       │
│  BALANCER (Private IP)      │
│  IP: 10.0.15.30             │
└────────────┬────────────────┘
             │
             ▼
┌─────────────────────────────┐
│  NGINX INGRESS CONTROLLER   │
│  (reads Ingress rules)      │
└────────────┬────────────────┘
             │ HTTP (inside cluster — trusted)
             ▼
┌─────────────────────────────┐
│  ArgoCD Server Service      │
└────────────┬────────────────┘
             │
             ▼
┌─────────────────────────────┐
│  ArgoCD Server Pod          │
│  (serves the UI)            │
└─────────────────────────────┘
```

## 1.3 Two Components (Both Required — Not Redundant)

| Component | What It Is | Created By |
|-----------|-----------|------------|
| **NGINX Ingress Controller** | The "doorman" — reads Ingress rules and routes traffic | Helm chart `ingress-nginx/ingress-nginx` |
| **Ingress Resource** | The "rule book" — says "argocd.yourcompany.internal → ArgoCD service" | ArgoCD Helm chart (`server.ingress.enabled: true`) |

> **Important**: These are **complementary**, not redundant.
> - The Ingress Controller is a **deployment/pod** that physically routes traffic.
> - The Ingress Resource is a **Kubernetes object** that defines routing rules.
> - You **need both** for ingress to work.

---

# 2. Resource Sizing

## 2.1 What Runs on This Cluster

The ArgoCD cluster only runs the control plane:
1. ArgoCD server — web UI
2. ArgoCD application controller — compares Git with cluster state
3. ArgoCD repo-server — generates Kubernetes YAML from Git
4. ArgoCD dex-server — handles Google login
5. Redis — tiny in-memory cache
6. ApplicationSet controller — generates apps from templates
7. Notifications controller — Slack/email alerts
8. NGINX Ingress Controller — routes external traffic

## 2.2 Sizing Table

### For the Demo (2 nodes)

| Component | CPU Request | Memory Request | CPU Limit | Memory Limit | Replicas |
|-----------|-------------|----------------|-----------|--------------|----------|
| ArgoCD Server | 250m | 256Mi | 1000m | 1Gi | 1 |
| ArgoCD Controller | 500m | 512Mi | 2000m | 2Gi | 1 |
| Repo Server | 250m | 256Mi | 1000m | 1Gi | 1 |
| Dex (SSO) | 50m | 64Mi | 200m | 256Mi | 1 |
| Redis | 100m | 128Mi | 200m | 256Mi | 1 |
| ApplicationSet | 100m | 128Mi | 500m | 512Mi | 1 |
| Notifications | 50m | 64Mi | 200m | 128Mi | 1 |
| NGINX Controller | 100m | 128Mi | 500m | 512Mi | 1 |
| **Total Requests** | **~1.4 vCPU** | **~1.5 GiB** | | | |
| **Total Limits** | | | **~4.6 vCPU** | **~5.6 GiB** | |

### Recommended Node Types

| Scenario | Machine Type | Node Count | Total CPU | Total RAM | Monthly Cost (approx) |
|----------|-------------|------------|-----------|-----------|----------------------|
| **Demo** | e2-medium | 2 | 2 vCPU | 8 GB | ~$122 |
| **More headroom** | e2-standard-2 | 2 | 4 vCPU | 16 GB | ~$171 |
| **Future scale-up** | e2-standard-2 | 3 | 6 vCPU | 24 GB | ~$220 |

---

# 3. Phase 1 — Create GKE Cluster

## 3.1 Prerequisites

```bash
# Verify installations
gcloud version
kubectl version --client
helm version

# Login to Google Cloud
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID

# Enable required APIs (one-time per project)
gcloud services enable container.googleapis.com
```

## 3.2 Create Cluster (gcloud CLI)

```bash
export PROJECT_ID="your-project-id"
export GCP_REGION="asia-south1"
export GCP_ZONE="asia-south1-a"
export CLUSTER_NAME="argocd-cluster"

gcloud config set project $PROJECT_ID
gcloud config set compute/region $GCP_REGION
gcloud config set compute/zone $GCP_ZONE

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
  --addons=HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver \
  --labels=env=argocd,team=platform

echo "✅ Cluster created: $CLUSTER_NAME"
```

**Why `--enable-ip-alias`?** Required for Internal Load Balancer to work.

## 3.3 Connect kubectl

```bash
gcloud container clusters get-credentials $CLUSTER_NAME --zone=$GCP_ZONE

# Verify: you should see 2 nodes
kubectl get nodes -o wide
```

**Expected output:**
```
NAME                                        STATUS   ROLES    AGE   VERSION
gke-argocd-cluster-default-pool-xxx-yyy     Ready    <none>   1m    v1.29.x
gke-argocd-cluster-default-pool-zzz-www     Ready    <none>   1m    v1.29.x
```

---

# 4. Phase 2 — Install Internal NGINX Ingress Controller

> **This creates the Internal Load Balancer with a private IP.**
> Without this, there is no "doorman" to route traffic into the cluster.

## 4.1 Deploy NGINX Ingress Controller (Internal Only)

```bash
# Add the NGINX Helm repo
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Create values file for INTERNAL LB
cat > nginx-values.yaml << 'EOF'
controller:
  replicaCount: 1

  service:
    # THIS IS THE MAGIC ANNOTATION
    # It tells Google Cloud: "Create an INTERNAL load balancer, not public"
    # Without this, GCP defaults to a public LB with a routable internet IP.
    # With this, GCP assigns a private IP from your VPC subnet (e.g. 10.x.x.x).
    annotations:
      cloud.google.com/load-balancer-type: "Internal"
      cloud.google.com/neg: '{"ingress": true}'

  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi

  admissionWebhooks:
    enabled: true
    patch:
      enabled: true

  metrics:
    enabled: false
EOF

# Install NGINX Ingress Controller in its own namespace
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values nginx-values.yaml \
  --wait --timeout 5m
```

## 4.2 Verify the Internal LB Was Created

```bash
kubectl get svc -n ingress-nginx
```

**Expected output:**
```
NAME                       TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)
ingress-nginx-controller   LoadBalancer   10.100.10.10    10.0.15.30    80:30000/TCP,443:30443/TCP
```

Two things to confirm:
1. **TYPE = LoadBalancer** — GCP created a real load balancer
2. **EXTERNAL-IP = `10.x.x.x`** — This is a **private** IP, NOT a public one

> The `EXTERNAL-IP` column is misleadingly named by Kubernetes. When the Internal LB annotation is set, this field shows the **VPC-private IP**, not a public internet address. A public LB would show something like `34.120.x.x` here.

### Save the Internal IP

```bash
export ARGOCD_INTERNAL_IP=$(kubectl get svc ingress-nginx-controller \
  -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "ArgoCD Internal IP: $ARGOCD_INTERNAL_IP"
```

---

# 5. Phase 3 — Generate Self-Signed Certificates

> ⚠️ **Do this BEFORE running `helm install argocd`**. The TLS secret must exist when the ArgoCD Helm chart creates the Ingress object.

## 5.1 Generate the Certificate

```bash
# Create a directory for certificates
mkdir -p certs

# Generate a private key
openssl genrsa -out certs/argocd.key 2048

# Generate a self-signed certificate (valid for 365 days)
openssl req -new -x509 -key certs/argocd.key -out certs/argocd.crt -days 365 \
  -subj "/C=IN/ST=MH/L=Mumbai/O=YourCompany/CN=argocd.yourcompany.internal"

# Verify files exist
ls -la certs/argocd.key certs/argocd.crt
```

## 5.2 Store as Kubernetes Secret

```bash
# Create namespace first (needed for the secret)
kubectl create namespace argocd

# Create TLS secret
kubectl create secret tls argocd-server-tls \
  --namespace argocd \
  --cert=certs/argocd.crt \
  --key=certs/argocd.key

# Verify
kubectl get secret argocd-server-tls -n argocd
```

## 5.3 How to Use Client Certificates Later

When your client gives you real certificate files:

```bash
# Delete old secret, create new one
kubectl delete secret argocd-server-tls -n argocd
kubectl create secret tls argocd-server-tls \
  --namespace argocd --cert=company.crt --key=company.key

# Restart NGINX to pick up the new cert
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
```

> That's it. No YAML changes needed anywhere.

---

# 6. Phase 4 — Install ArgoCD (With Built-In Ingress)

> **Key point**: We use `server.ingress.enabled: true` inside ArgoCD's Helm values.
> This lets the ArgoCD Helm chart create the Ingress resource automatically.
> We do NOT create a separate `argocd-ingress.yaml` file — that would be redundant.

## 6.1 Add ArgoCD Helm Repository

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

## 6.2 Create argocd-values.yaml

Create a file named `argocd-values.yaml`:

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

  # ArgoCD server runs HTTP internally.
  # TLS is terminated at NGINX — traffic never leaves the cluster unencrypted.
  extraArgs:
    - --insecure

  # ===========================================
  # INGRESS CONFIGURATION (Built into Helm)
  # ===========================================
  # The ArgoCD Helm chart creates the Ingress resource automatically.
  # We do NOT need a separate argocd-ingress.yaml file.
  # The Ingress resource points to the NGINX controller (installed in Phase 2).
  ingress:
    enabled: true

    # Use the NGINX ingress controller we installed in Phase 2.
    # This DOES NOT create a new Load Balancer — it attaches to the
    # existing NGINX controller which already has the internal-only LB.
    ingressClassName: nginx

    annotations:
      # Force all HTTP traffic to redirect to HTTPS
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
      # ArgoCD uses WebSockets for live sync status — needs long timeouts
      nginx.ingress.kubernetes.io/proxy-read-timeout: "1800"
      nginx.ingress.kubernetes.io/proxy-send-timeout: "1800"

    # The hostname users will type in their browser
    hostname: argocd.yourcompany.internal

    # Enable TLS on the Ingress
    tls: true

    # Point to the TLS secret we created in Phase 3
    extraTls:
      - hosts:
          - argocd.yourcompany.internal
        secretName: argocd-server-tls

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

### Why `ingressClassName: nginx` Does NOT Create a New LB

| What it is | What it does |
|-----------|-------------|
| `ingressClassName: nginx` | Tells Kubernetes: "Hand this Ingress rule to the NGINX controller" |
| NGINX controller | Already running with an **Internal** Load Balancer (from Phase 2) |
| Result | ArgoCD traffic flows through the **existing** internal LB — no new LB created |

If you used `ingressClassName: gce` instead, GKE would spin up a **new public** Load Balancer for ArgoCD. We avoid this entirely by using `nginx`.

## 6.3 Install ArgoCD

```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.8.10 \
  --values argocd-values.yaml \
  --wait --timeout 10m
```

## 6.4 Verify Installation

```bash
# Check all pods are running
kubectl get pods -n argocd
```

**Expected output (all Running):**
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

Verify the Ingress object was created by the Helm chart:

```bash
kubectl get ingress -n argocd
```

**Expected output:**
```
NAME             CLASS   HOSTS                          ADDRESS       PORTS     AGE
argocd-server    nginx   argocd.yourcompany.internal    10.0.15.30    80, 443   1m
```

The `ADDRESS` column shows your internal LB IP (`10.x.x.x`) — confirming it is private.

## 6.5 Test Port-Forward (Admin Access, Bypasses Ingress)

Before testing Ingress, confirm ArgoCD itself is healthy:

```bash
# Creates a tunnel from your laptop directly to ArgoCD (bypasses ingress)
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open browser: `http://localhost:8080`

Get the admin password:
```bash
argocd admin initial-password -n argocd
```

Login with username `admin` and that password to confirm the UI loads.

> **Port-forward is only for admin/testing.** It bypasses Ingress, SSO, and TLS entirely. Once Ingress is working, normal users will NEVER use this.

## 6.6 Test from Inside the Cluster

Since the LB is internal, your laptop cannot reach it directly (unless on VPN). Test from a pod inside the cluster:

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

A `307` or `200` response confirms the full chain works: Internal LB → NGINX → TLS → ArgoCD.

---

# 7. Phase 5 — Google SSO

## 7.1 Create OAuth App in Google Cloud

### Step 1: Configure OAuth Consent Screen

1. Go to https://console.cloud.google.com/apis/credentials/consent
2. Click **"Create"**
3. Choose **"Internal"** (only users in your Google Workspace organization)
   - If no Google Workspace, choose **"External"** for the demo
4. Fill in:
   - **App name**: `ArgoCD Internal Dashboard`
   - **User support email**: your email
   - **Contact email**: your email
5. Click **"Save and Continue"**
6. On **Scopes**, add:
   - `openid`
   - `userinfo.profile`
   - `userinfo.email`
7. Click **"Update"** → **"Save and Continue"**
8. On **Test Users**, add your email
9. Click **"Save and Continue"** → **"Back to Dashboard"**

### Step 2: Create OAuth Client ID

1. Go to https://console.cloud.google.com/apis/credentials
2. Click **"+ Create Credentials"** → **"OAuth client ID"**
3. **Application type**: **"Web application"**
4. **Name**: `ArgoCD SSO`
5. **Authorized redirect URIs**:
   - `http://localhost:8080/api/dex/callback` (for port-forward testing)
   - `https://argocd.yourcompany.internal/api/dex/callback` (for production)
6. Click **"Create"**
7. **Copy the Client ID and Client Secret**

## 7.2 Store OAuth Secret in Kubernetes

```bash
export GOOGLE_CLIENT_ID="paste-your-client-id-here.apps.googleusercontent.com"
export GOOGLE_CLIENT_SECRET="paste-your-client-secret-here"

kubectl create secret generic google-oauth \
  --namespace argocd \
  --from-literal=dex.google.clientSecret="$GOOGLE_CLIENT_SECRET"
```

## 7.3 Configure Dex in ArgoCD

Create a file `argocd-cm-patch.yaml`:

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
          # CRITICAL: Only allows @yourcompany.com emails
          hostedDomains:
            - yourcompany.com
```

Replace `YOUR_GOOGLE_CLIENT_ID` with your actual Client ID, then apply:

```bash
kubectl apply -f argocd-cm-patch.yaml
```

### Dex Config Explained

| Field | Meaning |
|-------|---------|
| `type: google` | Use Google's OAuth 2.0 API |
| `clientID` | Your Google OAuth app's client ID |
| `clientSecret: $google-oauth:...` | References the K8s Secret — never hardcodes the value |
| `redirectURI` | Where Google sends users after login — MUST match Google Console exactly |
| `hostedDomains` | Only allows `@yourcompany.com` emails — blocks personal Gmail |

## 7.4 Restart ArgoCD Dex & Server

```bash
kubectl rollout restart deployment argocd-dex-server -n argocd
kubectl rollout restart deployment argocd-server -n argocd

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-dex-server -n argocd --timeout=120s
```

## 7.5 Test Login via Port-Forward

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open `http://localhost:8080`:
1. Click **"LOG IN VIA GOOGLE"**
2. Google asks you to authorize
3. After authorization, redirected back to ArgoCD

> **If you see `redirect_uri_mismatch`**: The redirect URI in Google Console must exactly match `https://argocd.yourcompany.internal/api/dex/callback`.

## 7.6 Disable Local Admin (After SSO Is Verified)

```bash
kubectl patch configmap argocd-cm -n argocd \
  --type merge -p '{"data":{"admin.enabled":"false"}}'

kubectl rollout restart deployment argocd-server -n argocd
```

> ⚠️ **DON'T do this until you have successfully logged in via Google at least once!**

If locked out, re-enable admin:
```bash
kubectl patch configmap argocd-cm -n argocd \
  --type merge -p '{"data":{"admin.enabled":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
```

---

# 8. Phase 6 — RBAC (Role-Based Access Control)

## 8.1 Groups

| Google Group | Members | What They Can Do |
|-------------|---------|-----------------|
| `devops@yourcompany.com` | DevOps team | Everything (admin) |
| `developers@yourcompany.com` | Developers | Deploy/sync apps, cannot create/delete |
| `auditors@yourcompany.com` | QA / Security | Read-only |

## 8.2 Apply RBAC Config

```bash
cat > argocd-rbac.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly

  policy.csv: |
    # ADMIN ROLE — Full control
    p, role:admin, applications, *, */*, allow
    p, role:admin, projects, *, *, allow
    p, role:admin, repositories, *, *, allow
    p, role:admin, certificates, *, *, allow
    p, role:admin, accounts, *, *, allow
    p, role:admin, gpgkeys, *, *, allow
    p, role:admin, exec, create, */*, allow

    # DEVELOPER ROLE — Can deploy but cannot destroy
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

    # READONLY ROLE — View only
    p, role:readonly, applications, get, */*, allow
    p, role:readonly, projects, get, *, allow
    p, role:readonly, repositories, get, *, allow

    # GROUP MAPPINGS
    g, devops@yourcompany.com, role:admin
    g, developers@yourcompany.com, role:developer
    g, auditors@yourcompany.com, role:readonly

    # Demo fallback — individual emails
    g, your-email@yourcompany.com, role:admin
    g, dev-email@yourcompany.com, role:developer

  scopes: "[email, groups]"
EOF

kubectl apply -f argocd-rbac.yaml
```

## 8.3 Restart Server

```bash
kubectl rollout restart deployment argocd-server -n argocd
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s
```

## 8.4 Test Each Role

| Test | How | Expected Result |
|------|-----|-----------------|
| **Admin** | Log in with your email | See "Settings", "New App" button |
| **Developer** | Log in with dev email | Can sync apps, no "New App" button |
| **Readonly** | Log in with auditor email | Can view apps, sync button greyed out |
| **Personal Gmail** | Try @gmail.com | Blocked by `hostedDomains` |

---

# 9. Phase 7 — Verification & Go-Live

## 9.1 Full Checklist

```
□ GKE cluster created with 2 nodes, e2-medium
□ kubectl connected to cluster
□ NGINX Ingress Controller installed (Phase 2)
□ LoadBalancer Service shows private IP (10.x.x.x) — NOT a public IP
□ Self-signed certificate created and stored as argocd-server-tls secret
□ ArgoCD installed via Helm with server.ingress.enabled: true
□ Ingress object in argocd namespace shows internal IP as ADDRESS
□ Google OAuth app created with correct redirect URIs
□ Dex configured with Google connector via argocd-cm-patch.yaml
□ SSO login works (admin account disabled after)
□ RBAC ConfigMap applied
□ All 3 roles tested (admin / developer / readonly)
□ Personal Gmail blocked by hostedDomains
```

## 9.2 Manager Demo Script

### Scene 1: Architecture (30 seconds)

> *"ArgoCD runs on a 2-node GKE cluster. The entire setup is internal-only — there is no public IP. Only computers inside our company network can reach it."*

```bash
echo "ArgoCD Internal IP: $ARGOCD_INTERNAL_IP"
```

> *"This IP is private. It does not exist on the internet. Just like your home laptop at `192.168.1.10` — only your WiFi devices can reach it."*

### Scene 2: SSO (1 minute)

> *"No local passwords. Everyone logs in with their company Google account."*

1. Open `https://argocd.yourcompany.internal` (via VPN/company network)
2. Click **"Login with Google"**
3. Log in

> *"Personal Gmail accounts are blocked. Only @yourcompany.com works."*

### Scene 3: RBAC (1 minute)

> *"Not everyone gets the same permissions."*

1. Admin sees "Settings", "New App" button
2. Developer can sync but cannot delete
3. Readonly can only view

### Scene 4: Security (30 seconds)

> *"Zero internet exposure. No WAF needed. The load balancer simply does not have a public IP. You cannot hack what you cannot reach."*

---

# 10. Accessing ArgoCD from Your Laptop

Since the LoadBalancer is **internal only**, your laptop cannot reach it directly unless on VPN.

## Option 1: kubectl port-forward (Admin Only)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open `http://localhost:8080` on your laptop.

> ⚠️ Bypasses Ingress, SSO, and TLS. Only for admin emergencies.

## Option 2: VPN / Company Network

If your company has a VPN:
1. Connect to the VPN
2. Add to your laptop's `/etc/hosts`:
   ```
   10.0.15.30  argocd.yourcompany.internal
   ```
3. Open `https://argocd.yourcompany.internal`
4. Accept the self-signed cert warning (expected for demo)

## Option 3: Cloud IAP (Production)

Google Cloud IAP can sit in front of your internal resource for secure employee access without full VPN. Out of scope for demo.

## Option 4: Bastion Host

1. Create a small VM in the same VPC
2. SSH into it: `gcloud compute ssh bastion-host`
3. From the bastion: `curl -k https://10.0.15.30`

---

# 11. Cost Estimate

| Line Item | Detail | Monthly Cost (USD) | ~Monthly (₹) |
|-----------|--------|-------------------|--------------|
| GKE cluster management | $0.10/hr × 730 | **$73.00** | **~₹6,088** |
| 2 × e2-medium nodes | $0.0335/hr × 730 × 2 | **$48.91** | **~₹4,079** |
| Boot disks 2 × 50 GB | $0.040/GB × 50 × 2 | **$4.00** | **~₹334** |
| Internal Load Balancer | Forwarding rule: $0.025/hr × 730 | **$18.25** | **~₹1,522** |
| **Total** | | **~$144** | **~₹12,023** |

**2-week demo cost:** ~**$67** (~₹5,586)

---

# 12. Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `Pending` pods | Not enough resources | `kubectl top nodes`. Scale up node pool. |
| Ingress ADDRESS is empty | NGINX not yet ready or secret missing | Check `kubectl get pods -n ingress-nginx`. Confirm `argocd-server-tls` secret exists. |
| `Certificate not trusted` | Self-signed cert | Expected. Click "Advanced → Proceed". |
| SSO button missing | Dex not enabled or `url` not set | Check `kubectl get cm argocd-cm -n argocd -o yaml`. |
| `redirect_uri_mismatch` | Redirect URI mismatch | In Google Console, URI MUST exactly match `https://argocd.yourcompany.internal/api/dex/callback` |
| Google login blocked | `hostedDomains` mismatch | Ensure domain matches `hostedDomains` list |
| RBAC not working | Email not in policy.csv | Add individual email mapping |
| `502 Bad Gateway` | ArgoCD pods not healthy | `kubectl get pods -n argocd` — wait for all `1/1 Running` |
| `404 Not Found` via Ingress | Ingress hostname mismatch | Check `kubectl get ingress -n argocd -o yaml` |
| Internal LB IP doesn't appear | VPC-native networking not enabled | Cluster must have `--enable-ip-alias` |
| Lockout (no admin + SSO broken) | Disabling admin before SSO works | `kubectl patch cm argocd-cm -n argocd -p '{"data":{"admin.enabled":"true"}}'` |

---

# 13. Command Cheat Sheet

```bash
# ===== CLUSTER =====
gcloud container clusters get-credentials argocd-cluster --zone=asia-south1-a
kubectl get nodes

# ===== NGINX INGRESS CONTROLLER =====
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --values nginx-values.yaml \
  --wait --timeout 5m
kubectl get svc -n ingress-nginx
export ARGOCD_INTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# ===== TLS SECRET =====
mkdir -p certs
openssl genrsa -out certs/argocd.key 2048
openssl req -new -x509 -key certs/argocd.key -out certs/argocd.crt -days 365 \
  -subj "/C=IN/ST=MH/L=Mumbai/O=YourCompany/CN=argocd.yourcompany.internal"
kubectl create namespace argocd
kubectl create secret tls argocd-server-tls -n argocd \
  --cert=certs/argocd.crt --key=certs/argocd.key

# ===== ARGOCD (with built-in Ingress) =====
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm install argocd argo/argo-cd \
  --namespace argocd --version 7.8.10 --values argocd-values.yaml \
  --wait --timeout 10m
kubectl get pods -n argocd
kubectl get ingress -n argocd
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
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx

# ===== PORT-FORWARD (admin bypass) =====
kubectl port-forward svc/argocd-server -n argocd 8080:80

# ===== CLEANUP =====
helm uninstall argocd -n argocd
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace argocd
kubectl delete namespace ingress-nginx
gcloud container clusters delete argocd-cluster --zone=asia-south1-a
```

---

**End of Guide.**

> 💡 **Certificate swap**: Replace `argocd-server-tls` Secret with client's `.crt` and `.key`, restart NGINX. Everything else stays the same.
>
> 💡 **Correct install order**:
> 1. Phase 2 — NGINX Ingress Controller (internal LB first)
> 2. Phase 3 — TLS Secret (must exist before ArgoCD Helm install)
> 3. Phase 4 — `helm install argocd` (Ingress object created automatically by Helm — no separate YAML needed)
> 4. Phase 5 — SSO
> 5. Phase 6 — RBAC
