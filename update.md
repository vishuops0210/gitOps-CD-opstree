# Update.md — NGINX Ingress → Google Managed Ingress (gce-internal)

> **Date**: June 2026
> **Author**: Infrastructure Team
> **Scope**: Switch ArgoCD internal ingress from NGINX Ingress Controller to Google Managed Ingress (GCE Internal Application Load Balancer)
> **Environment**: Production-bound — single-region GKE cluster, internal-only, VPN required for access

---

## Table of Contents

1. [Why the Switch?](#1-why-the-switch)
2. [Traffic Flow: NGINX Ingress (Before)](#2-traffic-flow-nginx-ingress-before)
3. [Traffic Flow: GCE Internal Ingress (After)](#3-traffic-flow-gce-internal-ingress-after)
4. [TLS Termination: Where It Happens](#4-tls-termination-where-it-happens)
5. [Key Architectural Differences](#5-key-architectural-differences)
6. [What Changes in the Setup](#6-what-changes-in-the-setup)
7. [Production Considerations](#7-production-considerations)
8. [Cost Impact](#8-cost-impact)
9. [Rollback Plan](#9-rollback-plan)

---

# 1. Why the Switch?

| Factor | NGINX Ingress | GCE Internal Ingress |
|--------|--------------|---------------------|
| **Managed by** | Your team (pod-based) | Google Cloud (fully managed) |
| **Setup complexity** | Lower (Helm install) | Higher (proxy subnet, firewall, regional certs) |
| **Operating burden** | Pod health, upgrades, config | Zero — Google manages everything |
| **Traffic path** | LB → NodePort → NGINX pod → ArgoCD pod | LB → **Pod IP directly** (Container Native LB via NEGs) |
| **WebSocket support** | Native, battle-tested | Requires FrontendConfig |
| **Health checks** | NGINX handles it | BackendConfig CRD defines it |
| **Cost** | Free (runs on your nodes) | Forwarding rule ~$18/mo (same as NGINX's internal LB) |
| **Resource usage** | Consumes cluster CPU/memory | Zero cluster resources |

**Why use Google Managed for production**: Fully managed L7 load balancer, container-native load balancing (traffic goes directly to pods, not through nodes), no pod to maintain, no upgrade cycles, integrates natively with Google Cloud Monitoring/Logging.

---

# 2. Traffic Flow: NGINX Ingress (Before)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   YOUR LAPTOP (VPN connected to company network)                            │
│   You type: https://argocd.yourcompany.internal                             │
│                                                                             │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ HTTPS (TLS encrypted)
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   STEP 1: GOOGLE CLOUD INTERNAL LOAD BALANCER (L4 — TCP)                    │
│   IP: 10.0.15.30 (private, VPC-only)                                       │
│   Type: Network Load Balancer (Internal)                                    │
│   Created by: ingress-nginx-controller Service (type: LoadBalancer)         │
│                                                                             │
│   TLS Status: ❌ NOT TERMINATED HERE                                         │
│   Traffic: Still encrypted TCP (pass-through)                               │
│                                                                             │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ TCP (encrypted payload goes through)
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   STEP 2: GKE NODE (NodePort)                                               │
│   Port: 30443 (randomly assigned NodePort)                                  │
│   kube-proxy routes traffic to NGINX pod                                    │
│                                                                             │
│   TLS Status: ❌ NOT TERMINATED HERE                                         │
│                                                                             │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ TCP (still encrypted)
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   STEP 3: NGINX INGRESS CONTROLLER POD                                      │
│   Namespace: ingress-nginx                                                  │
│   Reads Ingress rules → matches hostname → decrypts TLS → routes traffic    │
│                                                                             │
│   TLS Status: 🔒 TLS IS TERMINATED HERE!                                     │
│   Certificate used: argocd-server-tls K8s Secret (self-signed / custom)     │
│   What happens:                                                             │
│     1. NGINX decrypts HTTPS traffic                                         │
│     2. Reads hostname: "argocd.yourcompany.internal"                        │
│     3. Matches Ingress rule for ArgoCD                                      │
│     4. Forward request as HTTP to ArgoCD service                            │
│                                                                             │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ HTTP (unencrypted, inside cluster — trusted)
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   STEP 4: ARGOCD SERVICE (ClusterIP)                                        │
│   Namespace: argocd                                                         │
│   Just routes to ArgoCD pods                                                │
│                                                                             │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ HTTP
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   STEP 5: ARGOCD SERVER POD                                                 │
│   ArgoCD runs with --insecure flag (accepts HTTP inside cluster)            │
│   Serves the web UI                                                         │
│                                                                             │
│   TLS Status: ❌ NOT TERMINATED HERE (already decrypted at NGINX)            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### NGINX Flow Summary

```
Browser ──[HTTPS]──► GCLB (L4, Internal) ──[TCP/HTTPS]──► NodePort:30443
                          │                                        │
                          │                                        ▼
                          │                            NGINX Pod (terminates TLS)
                          │                            Reads cert from: argocd-server-tls
                          │                                        │
                          │                                        ▼
                          │                                    [HTTP]──► ArgoCD Pod
                          │
                          └── External IP: 10.0.15.30 (private)
```

---

# 3. Traffic Flow: GCE Internal Ingress (After)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   YOUR LAPTOP (VPN connected to company network)                            │
│   You type: https://argocd.yourcompany.internal                             │
│                                                                             │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ HTTPS (TLS encrypted)
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   STEP 1: GOOGLE INTERNAL APPLICATION LOAD BALANCER (L7 — HTTP/S)          │
│   IP: 10.0.15.30 (reserved regional static IP, private)                     │
│   Type: Regional Application Load Balancer (Internal)                       │
│   Created by: GKE Ingress Controller (built-in)                             │
│   Subnets:                                                                  │
│     - Node subnet: where GKE nodes live                                     │
│     - Proxy-only subnet: where Google-managed proxy VMs live                │
│                                                                             │
│   TLS Status: 🔒 TLS IS TERMINATED HERE!                                     │
│   Certificate used: argocd-selfsigned-cert (regional pre-shared cert)      │
│   What happens:                                                             │
│     1. Load balancer receives HTTPS request                                 │
│     2. Performs TLS handshake (proves identity via certificate)             │
│     3. Decrypts HTTPS → reads HTTP headers                                  │
│     4. Reads Host header: "argocd.yourcompany.internal"                     │
│     5. Looks up URL map rules → finds matching backend service              │
│     6. Routes to Network Endpoint Group (NEG)                              │
│                                                                             │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ HTTP/HTTPS (optionally re-encrypt to backend)
                                   │ Using Container Native Load Balancing:
                                   │ Traffic goes DIRECTLY to Pod IP (not NodePort)
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   STEP 2: GKE NODE                                                          │
│   Type: No NodePort involved!                                               │
│   kube-proxy: SKIPPED (direct pod routing via NEG)                          │
│                                                                             │
│   Container Native Load Balancing:                                          │
│   ┌─────────────────────────────────────────────────────────────────┐       │
│   │  Network Endpoint Group (NEG)                                   │       │
│   │  ┌─────────────────────────────┐  ┌─────────────────────────────┐│       │
│   │  │  Pod 1: 10.82.1.5:8080      │  │  Pod 2: 10.82.2.9:8080      ││       │
│   │  │  (healthy)                  │  │  (healthy)                  ││       │
│   │  └──────────┬──────────────────┘  └──────────┬──────────────────┘│       │
│   │             │                                 │                  │       │
│   │             ▼                                 │                  │       │
│   │     Traffic goes DIRECTLY to Pod IP           │                  │       │
│   │     (not via NodePort / kube-proxy)           │                  │       │
│   └─────────────────────────────────────────────────────────────────┘       │
│                                                                             │
│   TLS Status: ❌ NOT TERMINATED HERE (already decrypted at LB)               │
│                                                                             │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ HTTP (inside VPC — already decrypted)
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   STEP 3: ARGOCD SERVER POD                                                 │
│   ArgoCD runs with --insecure flag (accepts HTTP inside cluster)            │
│   Serves the web UI                                                         │
│                                                                             │
│   TLS Status: ❌ NOT TERMINATED HERE (already decrypted at LB)               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### GCE Internal Flow Summary

```
Browser ──[HTTPS]──► GCE Internal Application LB (L7)
                          │
                          │ 🔒 TLS TERMINATED HERE
                          │ Certificate: regional pre-shared cert
                          │ (uploaded via gcloud compute ssl-certificates create)
                          │
                          ├── URL Map: matches argocd.yourcompany.internal
                          │
                          ├── Backend Service: health-checked
                          │   healthCheck: /healthz (BackendConfig CRD)
                          │
                          ├── Network Endpoint Group (NEG)
                          │   Direct routes to Pod IPs (container-native)
                          │
                          └── IP: 10.0.15.30 (reserved regional static)
                                   │
                                   ▼
                              [HTTP]──► ArgoCD Pod
```

---

# 4. TLS Termination: Where It Happens

## NGINX Approach

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  Client Browser  ───HTTPS───►  GCLB (L4)  ───TCP───►  NGINX  Pod   │
│                                                                      │
│                     🔒                           🔒                  │
│                  Encrypted                   Encrypted               │
│                                                                      │
│                                               └────┬────┘            │
│                                                    │                 │
│                                  TLS TERMINATED HERE │                │
│                                  Certificate: K8s Secret             │
│                                  (argocd-server-tls)                 │
│                                                    │                 │
│                                                    ▼                 │
│                                               HTTP                  │
│                                                    │                 │
│                                                    ▼                 │
│                                               ArgoCD Pod            │
│                                               (--insecure)           │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

## GCE Internal Approach

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  Client Browser  ───HTTPS───►  GCE App LB (L7)  ───HTTP───► ArgoCD │
│                                                                      │
│                     🔒                           ❌                  │
│                  Encrypted                Inside VPC, trusted        │
│                                                                      │
│                         ┌────┬────┐                                  │
│                              │                                       │
│           TLS TERMINATED HERE │                                       │
│           Certificate: regional pre-shared cert                      │
│           (argocd-selfsigned-cert in GCP)                            │
│                              │                                       │
│                              ▼                                       │
│                          Decrypted                                   │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

## TLS Certificate Comparison

|  | NGINX Ingress | GCE Internal Ingress |
|----|--------------|---------------------|
| **Certificate type** | Kubernetes TLS Secret (in-cluster) | Google Cloud regional pre-shared SSL certificate |
| **How created** | `kubectl create secret tls` | `gcloud compute ssl-certificates create` |
| **Where stored** | Inside the Kubernetes cluster, encrypted at rest in etcd | In Google Cloud, managed by IAM |
| **Rotation** | You rotate the K8s secret | You update the regional cert, re-apply via annotation |
| **Self-signed** | ✅ Works natively via K8s secret | ✅ Works via regional pre-shared cert |
| **CA-signed (customer)** | ✅ Works via K8s secret | ✅ Works via regional pre-shared cert |
| **Google-managed (Let's Encrypt)** | ✅ Works via cert-manager | ❌ NOT supported for internal LBs |

> ⚠️ **Critical for production**: Google-managed certificates (auto-provisioned by Google via Let's Encrypt) are **NOT supported** by internal LBs. You must use pre-shared regional certificates for internal GCE Ingress.

---

# 5. Key Architectural Differences

## 5.1 Load Balancer Type

|  | NGINX | GCE Internal |
|----|-------|-------------|
| **LB type** | External Load Balancer (L4 / TCP passthrough) → NGINX does L7 | Internal Application Load Balancer (L7 / HTTP + HTTPS) |
| **Level** | Layer 4 (TCP) at Google LB level, Layer 7 (HTTP) at NGINX pod level | Layer 7 (HTTP/HTTPS) entirely at Google LB level |
| **External vs Internal** | `cloud.google.com/load-balancer-type: "Internal"` creates an External Load Balancer configured as Internal | `kubernetes.io/ingress.class: "gce-internal"` creates a true Internal Application LB |

## 5.2 Routing

|  | NGINX | GCE Internal |
|----|-------|-------------|
| **Backend type** | Instance Groups (Node IPs) | Network Endpoint Groups (Pod IPs directly) |
| **Path to pod** | LB → Node IP → kube-proxy → NodePort → NGINX pod → ArgoCD pod | LB → Pod IP directly (container-native) |
| **Benefit** | Simpler | Lower latency, better health checking, no kube-proxy hop |
| **Drawback** | Proxy pod adds latency (~1-5ms) | Requires pod readiness gates, more complex |

## 5.3 Required GCP Resources

| Resource | NGINX | GCE Internal | Notes |
|----------|-------|-------------|-------|
| **Proxy-only subnet** | ❌ No | ✅ Yes | `/23` subnet in same region |
| **Firewall rules** | Automatic | Manual + health-check rules | Must allow proxy subnet to pods |
| **BackendConfig CRD** | ❌ No | ✅ Yes | Defines health checks |
| **FrontendConfig CRD** | ❌ No | ✅ Yes | Defines HTTPS redirect, WebSocket timeouts |
| **Regional static IP** | Optional | Recommended | Reserve IP before Ingress creation |
| **Regional SSL cert** | ❌ No (K8s secret) | ✅ Yes | Must upload cert to GCP |

## 5.4 Health Checks

|  | NGINX | GCE Internal |
|----|-------|-------------|
| **Who checks?** | NGINX (sends HTTP checks to pods) | Google's health check probers |
| **How defined** | Ingress annotations (nginx-specific) | BackendConfig CRD |
| **Port** | Service port (e.g., 80) | Container port (e.g., 8080) — NOT NodePort |
| **Path** | Anything you set in annotations | Must match container readiness probe |
| **Interval/timeout** | Annotation-based (proxy-read-timeout) | BackendConfig spec.healthCheck |

## 5.5 WebSocket Support (ArgoCD needs this!)

|  | NGINX | GCE Internal |
|----|-------|-------------|
| **Configuration** | `nginx.ingress.kubernetes.io/proxy-read-timeout: "1800"` | `networking.gke.io/v1beta1.FrontendConfig` |
| **Complexity** | Simple — one annotation | Requires extra CRD resource |
| **Risk if wrong** | Live sync UI may lag or disconnect | Live sync UI may lag or disconnect |

---

# 6. What Changes in the Setup

## Components Removed

| Component | Why Removed |
|-----------|------------|
| `ingress-nginx` Helm chart | Not needed — GCE Ingress controller is built into GKE |
| `nginx-values.yaml` | NGINX-specific values file |
| `ingress-nginx` namespace | No NGINX pods to run |
| ArgoCD `extraTls` in values | TLS handled via pre-shared regional cert annotation |

## Components Added

| Component | Why Added |
|-----------|----------|
| **Proxy-only subnet** (`192.168.0.0/23`) | Google-managed proxy VMs for the L7 LB live here |
| **Firewall rule** (proxy subnet → pods) | Google's proxies must reach your pods |
| **Regional static IP** (reserved) | Stable IP address for the LB |
| **Regional pre-shared SSL certificate** | GCE Internal LB requires certs uploaded to GCP |
| **BackendConfig CRD** | Defines health checks for the backend service |
| **FrontendConfig CRD** | Configures HTTPS redirect and WebSocket timeouts |
| **NEG annotation on ArgoCD Service** (`cloud.google.com/neg`) | Enables container-native load balancing |
| **VPA or HPA for ArgoCD** | Production best practice (recommended) |

## Components Changed

| Component | NGINX Way | GCE Internal Way |
|-----------|-----------|------------------|
| ArgoCD values `server.ingress` | `ingressClassName: nginx` | `ingressClassName: ""` + annotation `kubernetes.io/ingress.class: "gce-internal"` |
| ArgoCD TLS config | `tls: true` + `extraTls` with K8s secret | `tls: false` + `ingress.gcp.kubernetes.io/pre-shared-cert` annotation |
| ArgoCD Service | Default (ClusterIP) | Add `cloud.google.com/neg: '{"ingress": true}'` annotation |
| ArgoCD health check | Default K8s readiness probe | BackendConfig pointing to `/healthz` with proper thresholds |

---

# 7. Production Considerations

## 7.1 Certificate Management

### For Demo (Self-Signed)
```bash
gcloud compute ssl-certificates create argocd-selfsigned-cert \
    --certificate certs/argocd.crt \
    --private-key certs/argocd.key \
    --region=asia-south1
```

### For Production (Customer-Provided CA Certificates)
```bash
gcloud compute ssl-certificates create argocd-production-cert \
    --certificate certs/customer-ca.crt \
    --private-key certs/customer-ca.key \
    --region=asia-south1
```

**No changes needed to Kubernetes** — just update the annotation on the Ingress and restart (or create a new cert, update annotation, delete old cert).

## 7.2 IP Address Stability

Without a reserved static IP:
- IP changes if you delete + recreate the Ingress
- DNS must be updated manually
- Terraform / IaC becomes unreliable

**Always reserve a static regional IP for production.**

## 7.3 Firewall Rules

Without proper firewall rules:
- Load balancer health checks will fail
- Pods will show as `UNHEALTHY`
- You'll get `502` or `504` errors

**Must allow both:**
1. Google health check probes (`130.211.0.0/22`, `35.191.0.0/16`)
2. Proxy-only subnet where Google proxy VMs live

## 7.4 Monitoring

| Layer | What to Monitor | How |
|-------|-----------------|-----|
| LB | Health check success rate | Cloud Monitoring → Internal HTTP LB |
| LB | Request count, latency | Cloud Monitoring → Load Balancer metrics |
| Backend | Pod health, CPU/memory | Cloud Monitoring → GKE metrics |
| Ingress | Events, annotations | `kubectl get events --field-selector involvedObject.kind=Ingress -n argocd` |
| SSL | Certificate expiry | Cloud Monitoring alert on `days_until_expiration` |

---

# 8. Cost Impact

| Line Item | NGINX Approach | GCE Internal Approach | Notes |
|-----------|---------------|----------------------|-------|
| **Forwarding rule** | ~$18.25/mo | ~$18.25/mo | Same cost |
| **NGINX pod resources** | ~100m CPU, 128Mi RAM | **$0** | No pod on your nodes |
| **Proxy-only subnet** | **$0** | Free in VPC | Part of /23 — pre-reserved |
| **Regional static IP** | **$0** (ephemeral) | ~$0.004/hr × unused | ~$3/mo if **not** attached |
| | | **$0** if attached | Free when in use by load balancer |
| **Total delta** | Baseline | **-$0 to -$5/mo** saved by removing NGINX pod |

> 💡 **Cost saving is minimal (~$0–5/mo)**. The real value is operational simplicity and not maintaining another component.

---

# 9. Rollback Plan

If GCE Internal Ingress causes issues:

```bash
# Step 1: Delete the GCE Ingress
kubectl delete ingress argocd-server -n argocd

# Step 2: Delete BackendConfig and FrontendConfig
kubectl delete backendconfig argocd-backend-config -n argocd
kubectl delete frontendconfig argocd-frontend-config -n argocd

# Step 3: Clean up ArgoCD service NEG annotation
kubectl patch service argocd-server -n argocd \
  --type='json' -p='[{"op": "remove", "path": "/metadata/annotations/cloud.google.com~1neg"}]'

# Step 4: Delete GCE LB resources from GCP (they may be orphaned otherwise)
gcloud compute forwarding-rules list --filter='name ~ k8s-fw-argocd' --region=asia-south1
gcloud compute backend-services list --filter='name ~ k8s1' --region=asia-south1

# Step 5: Reinstall NGINX Ingress Controller with internal LB
# (Follow Phase 2 from the old NGINX guide)

# Step 6: Update ArgoCD values to point to nginx class
helm upgrade argocd argo/argo-cd -n argocd -f argocd-values-nginx.yaml
```

> ⚠️ **Important**: Deleting the GCE Ingress may leave orphaned GCP resources (forwarding rules, backend services). Google documentation explicitly warns about this: *"You must also delete Ingress and Service resources before you delete clusters or else the Compute Engine load balancing resources are orphaned."*

---

## References

| Topic | Link |
|-------|------|
| GKE Internal Ingress official doc | https://cloud.google.com/kubernetes-engine/docs/how-to/internal-load-balance-ingress |
| GKE Ingress routing & security | https://docs.cloud.google.com/kubernetes-engine/docs/concepts/ingress-routing-security |
| BackendConfig health checks | https://docs.cloud.google.com/kubernetes-engine/docs/how-to/ingress-configuration |
| GKE internal ingress limitations | https://cloud.google.com/kubernetes-engine/docs/how-to/internal-load-balance-ingress#requirements_and_limitations |
| Pre-shared regional certificates | https://cloud.google.com/kubernetes-engine/docs/how-to/secure-traffic-management |
