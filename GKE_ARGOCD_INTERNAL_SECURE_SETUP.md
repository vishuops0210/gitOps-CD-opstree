# ArgoCD on GKE — Internal-Only Secure Setup Guide

> **Goal**: Deploy ArgoCD on a single-region, 2-node GKE cluster with internal-only access, Google SSO, RBAC, and TLS — all explained for someone seeing GCP for the first time.
>
> **Scope**: ArgoCD control plane only. Dev / UAT / Prod workload clusters are out of scope for this doc. After ArgoCD is running, we connect clusters.
>
> **Access Pattern**: NO public internet. Only your company network (VPC) can reach ArgoCD.
>
> **Region**: Single region (pick one). Examples use `asia-south1` (Mumbai). You can change it.
>
> **Date**: June 2026

---

## Table of Contents

1. [How Everything Works (The Noob Section)](#1-how-everything-works-the-noob-section)
   - 1.1 [The WiFi Analogy — Public vs Private](#11-the-wifi-analogy--public-vs-private)
   - 1.2 [What is Ingress?](#12-what-is-ingress)
   - 1.3 [How Internal Ingress Works (Step by Step)](#13-how-internal-ingress-works-step-by-step)
   - 1.4 [Where Does TLS / SSL Fit?](#14-where-does-tls--ssl-fit)
   - 1.5 [Full Architecture Diagram](#15-full-architecture-diagram)
2. [Resource Sizing Chart](#2-resource-sizing-chart)
3. [Phase 1 — Create GKE Cluster (UI + CLI)](#3-phase-1--create-gke-cluster-ui--cli)
   - 3.1 [Prerequisites](#31-prerequisites)
   - 3.2 [Option A: Google Cloud Console (UI)](#32-option-a-google-cloud-console-ui)
   - 3.3 [Option B: gcloud CLI](#33-option-b-gcloud-cli)
   - 3.4 [Connect kubectl](#34-connect-kubectl)
4. [Phase 2 — Install ArgoCD](#4-phase-2--install-argocd)
5. [Phase 3 — Generate Self-Signed Certificates](#5-phase-3--generate-self-signed-certificates)
6. [Phase 4 — Internal Ingress (The Important Part)](#6-phase-4--internal-ingress-the-important-part)
   - 6.1 [Deploy NGINX Ingress Controller (Internal)](#61-deploy-nginx-ingress-controller-internal)
   - 6.2 [Create ArgoCD Ingress with TLS](#62-create-argocd-ingress-with-tls)
   - 6.3 [Get Internal IP & Test](#63-get-internal-ip--test)
7. [Phase 5 — Google SSO](#7-phase-5--google-sso)
   - 7.1 [Create OAuth App in Google Cloud](#71-create-oauth-app-in-google-cloud)
   - 7.2 [Configure Dex in ArgoCD](#72-configure-dex-in-argocd)
8. [Phase 6 — RBAC (Role-Based Access Control)](#8-phase-6--rbac-role-based-access-control)
9. [Phase 7 — Verification & Go-Live](#9-phase-7--verification--go-live)
10. [Accessing ArgoCD from Your Laptop](#10-accessing-argocd-from-your-laptop)
11. [Monthly Cost Estimate](#11-monthly-cost-estimate)
12. [Troubleshooting](#12-troubleshooting)
13. [Quick Command Cheat Sheet](#13-quick-command-cheat-sheet)

---

# 1. How Everything Works (The Noob Section)

Read this section first. It explains every component so you sound like you know what you're talking about in front of your manager.

---

## 1.1 The WiFi Analogy — Public vs Private

### Your Home WiFi

At your home, your WiFi router creates a **private network**:
- Your laptop: `192.168.1.10`
- Your phone: `192.168.1.11`
- Your TV: `192.168.1.12`

These are **private IP addresses** (RFC 1918). Your neighbor **cannot** open `http://192.168.1.10` from their house because they are on a different network.

But you **can** open that IP from your phone because both devices are connected to the **same WiFi / same network**.

### Public vs Private — The Difference

| Aspect | Public | Private (Internal) |
|--------|--------|--------------------|
| **IP Address** | Something like `34.120.45.67` (anyone can reach) | Something like `10.0.15.30` (only inside the network) |
| **Who can access?** | Anyone on the internet | Only devices inside the same VPC / network |
| **Google Cloud equivalent** | External HTTP(S) Load Balancer | Internal Load Balancer |
| **Your WiFi equivalent** | Your public IP (seen by websites) | Your laptop's IP `192.168.1.x` |
| **Security** | Needs WAF, DDoS protection, strict auth | Already isolated from the internet |

**What we are building**: We create an **Internal Load Balancer** for ArgoCD. It gets a **private IP** inside your company's Google VPC. Just like your laptop at `192.168.1.10` can only be accessed by devices on your WiFi, the ArgoCD LB can only be accessed by computers inside your company's Google Cloud network (or connected via VPN).

---

## 1.2 What is Ingress?

### Simple Definition

> **Ingress** = A door into your Kubernetes cluster that knows WHERE to send traffic.

Imagine an apartment building:
- There is **one main entrance** (the Ingress)
- Inside, there are many apartments: Apartment 101 (ArgoCD), Apartment 102 (Monitoring), Apartment 103 (App Dashboard)
- The doorman at the entrance reads the name on the envelope and delivers it to the right apartment

In Kubernetes:
- The **Ingress Controller** = The doorman (a pod running inside the cluster)
- The **Ingress Resource** = The list of rules ("if hostname is argocd.company.com, send to ArgoCD service")
- The **Service** = The apartment door (routes to pods)
- The **Pod** = The actual app running inside

### Why Not Just Use a Service?

A Kubernetes `Service` is like a direct phone number to one app. It handles **Layer 4** (TCP/UDP) traffic.

An `Ingress` is smarter. It handles **Layer 7** (HTTP/HTTPS) traffic. It can:
- Route `argocd.company.com` → ArgoCD
- Route `grafana.company.com` → Grafana
- Route `api.company.com/users` → User microservice
- Terminate TLS (decrypt HTTPS) using an SSL certificate
- Enforce HTTPS redirects

### Two Types of Ingress You Will Hear About

| Type | What It Is | Cost | Best For |
|------|-----------|------|----------|
| **GCE Ingress (native)** | Google's managed ingress. Creates a Google Cloud Load Balancer automatically. | Forwarding rules cost ~$18/mo | Public-facing apps, auto-scaling |
| **NGINX Ingress** | An open-source ingress controller running as pods inside YOUR cluster. You control everything. | Free (runs on your existing nodes) | Private/internal apps, custom rules, learning |

**For this setup, we use NGINX Ingress** because:
1. It is fully internal (no public IP)
2. It costs nothing extra
3. It is easier to understand and debug
4. You control TLS completely

---

## 1.3 How Internal Ingress Works (Step by Step)

Here is the EXACT path your browser takes when you access ArgoCD internally:

```
Step 1: YOUR LAPTOP (inside company network)
        You open: https://argocd.yourcompany.internal

Step 2: COMPANY VPN / ROUTER / FIREWALL
        Checks: Is this request coming from inside the company?
        Result: YES → Forward to Google Cloud
        (If NO → Block it)

Step 3: GOOGLE CLOUD INTERNAL LOAD BALANCER
        This is NOT a public load balancer.
        It has a PRIVATE IP like: 10.0.15.30
        Only Google Cloud VPC traffic can reach this IP.
        Action: Forwards the HTTPS packet to a NodePort

Step 4: GKE NODE (one of your 2 worker nodes)
        The NodePort opens traffic to the node.
        The kube-proxy routes it to the NGINX pod.

Step 5: NGINX INGRESS CONTROLLER POD
        Reads the hostname: "argocd.yourcompany.internal"
        Matches against the Ingress rule we created.
        Action: "This packet goes to the ArgoCD server service."
        Also: Decrypts HTTPS using the SSL certificate.

Step 6: ARGOCD SERVER SERVICE
        A Kubernetes Service load-balances across ArgoCD server pods.
        Action: Sends the packet to one ArgoCD server pod.

Step 7: ARGOCD SERVER POD
        ArgoCD receives the request on HTTP (inside the cluster).
        Serves the login page.
```

### What Makes This "Internal Only"?

The magic happens at **Step 3**. The Google Cloud Internal Load Balancer:
- Does **NOT** get a public IP address
- Gets an IP address from your **private subnet** range (e.g., `10.0.0.0/20`)
- Can only be reached by:
  - Other VMs in the same VPC
  - VMs in VPCs connected via VPC peering
  - Your laptop if you are connected to the company VPN
  - On-premises servers connected via Cloud Interconnect / VPN

---

## 1.4 Where Does TLS / SSL Fit?

### What is TLS/SSL?

> **TLS (Transport Layer Security)** = Encryption that protects data between your browser and the server.

Without TLS, everything is sent as **plain text**:
- Passwords, tokens, API keys — anyone sniffing the network can read them.

With TLS, everything is **encrypted**:
- Even if someone intercepts the traffic, it looks like random garbage without the private key.

### The Two "TLS Moments" in Our Setup

| Location | What Happens | Certificate Used |
|----------|-------------|----------------|
| **Browser → Internal LB** | HTTPS traffic encrypted from browser to load balancer | Self-signed cert (demo) / Client-provided cert (production) |
| **LB → NGINX → ArgoCD pods** | Inside the cluster, traffic can be HTTP (already in a private network) | None needed — VPC is trusted |

### Self-Signed vs Real Certificates

| Type | What It Is | Browser Warning? | When to Use |
|------|-----------|------------------|-------------|
| **Self-signed** | You generate it yourself. Browser doesn't recognize the issuer. | ⚠️ Yes — "Your connection is not private" | Demo, testing, internal tools, before client provides real cert |
| **CA-signed** | Issued by a trusted authority (Let's Encrypt, DigiCert, etc.) | ✅ No warning | Production, public-facing apps |
| **Client-provided** | Your client's IT team gives you a `.crt` and `.key` file | ✅ No warning (if properly configured) | This demo — we will swap self-signed with client's cert later |

> **For this demo**: We generate a self-signed certificate. After the demo, you simply replace the Kubernetes Secret with the client's certificate files — no other changes needed.

---

## 1.5 Full Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   OUTSIDE WORLD (INTERNET)                                                  │
│   ════════════════════════                                                  │
│                                                                             │
│   Hacker's laptop ────────► ❌ BLOCKED                                     │
│   Random person ──────────► ❌ BLOCKED                                     │
│                                                                             │
│   No public IP exists for ArgoCD. The internal LB has NO internet face.    │
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
│   Your laptop (office) ─────────────────────┐                               │
│   Your phone (company WiFi) ────────────────┤                               │
│   Cloud VM in same VPC ─────────────────────┤                               │
│   On-prem server (via VPN) ─────────────────┤                               │
│                                             │                               │
│                                             ▼                               │
│                              ┌────────────────────────────┐                 │
│                              │  GOOGLE LOAD BALANCER      │                 │
│                              │  TYPE: INTERNAL            │                 │
│                              │  IP: 10.0.15.30            │                 │
│                              │  (Private — no public IP)  │                 │
│                              └────────────┬───────────────┘                 │
│                                           │                                 │
│                                           │ HTTPS (TLS encrypted)           │
│                                           ▼                                 │
│                              ┌────────────────────────────┐                 │
│                              │  GKE NODE 1  or  NODE 2    │                 │
│                              │  (your 2-node cluster)     │                 │
│                              └────────────┬───────────────┘                 │
│                                           │                                 │
│                          ┌────────────────┼────────────────┐                │
│                          │                │                │                │
│                          ▼                ▼                ▼                │
│   ┌──────────────────┐   NAMESPACE: ingress-nginx                        │
│   │  NGINX Ingress   │   ┌──────────────────────────┐                    │
│   │  Controller Pod  │◄──│  Ingress Resource YAML   │                    │
│   │                  │   │  hostname: argocd...     │                    │
│   └────────┬─────────┘   └──────────────────────────┘                    │
│            │                                                              │
│            │ HTTP (inside cluster — already trusted)                      │
│            ▼                                                              │
│   ┌──────────────────┐                                                   │
│   │ ArgoCD Service   │                                                   │
│   │ (ClusterIP)      │                                                   │
│   └────────┬─────────┘                                                   │
│            │                                                              │
│            ▼                                                              │
│   ┌──────────────────┐   NAMESPACE: argocd                               │
│   │ ArgoCD Server    │   ┌──────────────────────────┐                    │
│   │ Pod              │──►│  Dex Server Pod          │                    │
│   │                  │   │  (Google SSO)            │                    │
│   └──────────────────┘   └──────────────────────────┘                    │
│                                                                             │
│   After login → Google verifies you → Dex tells ArgoCD who you are          │
│   → ArgoCD checks RBAC rules → You see the dashboard                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

# 2. Resource Sizing Chart

## 2.1 Important Concept: ArgoCD Does NOT Run Your Apps

Your 9 microservices + 3 frontends running in dev / uat / prod are **NOT** running on the ArgoCD cluster. They run on separate **workload clusters** (dev-gke, uat-gke, prod-gke).

The ArgoCD cluster only runs:
1. ArgoCD server — the web UI
2. ArgoCD application controller — the "brain" that compares Git with actual cluster state
3. ArgoCD repo-server — generates Kubernetes YAML from Git
4. ArgoCD dex-server — handles Google login
5. Redis — tiny in-memory cache
6. ApplicationSet controller — generates multiple apps from templates
7. Notifications controller — sends Slack/email alerts

These need **moderate** resources. The controller's CPU/memory scales with the number of apps it is **managing**, not running.

## 2.2 Sizing Table

### For the Demo (2 nodes)

| ArgoCD Component | CPU Request | Memory Request | CPU Limit | Memory Limit | Replicas |
|-----------------|-------------|----------------|-----------|--------------|----------|
| Server (UI/API) | 250m | 256Mi | 1000m | 1Gi | 1 |
| Controller | 500m | 512Mi | 2000m | 2Gi | 1 |
| Repo Server | 250m | 256Mi | 1000m | 1Gi | 1 |
| Dex (SSO) | 50m | 64Mi | 200m | 256Mi | 1 |
| Redis | 100m | 128Mi | 200m | 256Mi | 1 |
| ApplicationSet | 100m | 128Mi | 500m | 512Mi | 1 |
| Notifications | 50m | 64Mi | 200m | 128Mi | 1 |
| **Total Requests** | **~1.3 vCPU** | **~1.4 GiB** | | | |
| **Total Limits** | | | **~4.1 vCPU** | **~5.1 GiB** | |

### Recommended GKE Node Types

| Scenario | Machine Type | CPU per Node | RAM per Node | Node Count | Total CPU | Total RAM | Monthly Cost (approx) |
|----------|-------------|--------------|--------------|------------|-----------|-----------|----------------------|
| **Demo (what we build)** | e2-medium | 1 shared | 4 GB | 2 | 2 vCPU | 8 GB | ~$49 (nodes) + $73 (mgmt) = ~$122 |
| **More headroom** | e2-standard-2 | 2 guaranteed | 8 GB | 2 | 4 vCPU | 16 GB | ~$98 (nodes) + $73 (mgmt) = ~$171 |
| **Future scale-up** | e2-standard-2 | 2 guaranteed | 8 GB | 3 | 6 vCPU | 24 GB | ~$147 + $73 = ~$220 |
| **If you also run monitoring** | e2-standard-4 | 4 guaranteed | 16 GB | 2 | 8 vCPU | 32 GB | ~$196 + $73 = ~$269 |

> 💡 **Why 2 nodes of e2-medium is enough for the demo**:
> - Total requests: 1.3 vCPU / 1.4 GiB
> - Node capacity: 2 vCPU / 8 GiB total (across 2 nodes)
> - Headroom: ~35% CPU, ~82% RAM still available
> - For ~36 managed apps (12 env × 3), the controller uses ~512Mi RAM. At 100+ apps, scale to e2-standard-2.

### Cost Comparison: GKE vs EKS

| Item | AWS EKS (your old setup) | GKE (our new setup) |
|------|-------------------------|---------------------|
| Control plane fee | $73/month (zonal/regional same) | $73/month (same for all GKE clusters) |
| 2 nodes t3.small (AWS) | 2 × $0.0208/hr × 730 = ~$30/mo | — |
| 2 nodes e2-medium (GCP) | — | 2 × $0.0335/hr × 730 = ~$49/mo |
| 2 nodes e2-standard-2 | — | 2 × $0.067/hr × 730 = ~$98/mo |
| **Total for 2 nodes** | **~$103/mo** | **~$122/mo** (e2-medium) or **~$171/mo** (e2-standard-2) |

> e2-medium is slightly more expensive than t3.small but gives **2x the RAM** (4 GB vs 2 GB). ArgoCD benefits from the extra RAM.

---

# 3. Phase 1 — Create GKE Cluster (UI + CLI)

## 3.1 Prerequisites

Install these tools on your laptop:

| Tool | Purpose | Install Command |
|------|---------|----------------|
| gcloud | Talk to Google Cloud | https://cloud.google.com/sdk/docs/install |
| kubectl | Talk to Kubernetes | `gcloud components install kubectl` |
| helm | Package manager for K8s | https://helm.sh/docs/intro/install/ |

```bash
# Verify installations
gcloud version
kubectl version --client
helm version
```

```bash
# Login to Google Cloud
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
```

Enable required APIs (one-time per project):

```bash
gcloud services enable container.googleapis.com
```

---

## 3.2 Option A: Google Cloud Console (UI) — Click by Click

### Step 1: Open Kubernetes Engine
1. Go to https://console.cloud.google.com/kubernetes
2. Make sure your project is selected (top left dropdown)
3. Click **"Create"** or **"Create Cluster"**

### Step 2: Choose Cluster Type
1. Select **"Standard"** (NOT Autopilot — we want control over nodes)
2. Choose **"GKE Standard cluster"**
3. Click **"Configure"**

### Step 3: Basic Cluster Details
| Field | Value | Why |
|-------|-------|-----|
| **Name** | `argocd-cluster` | Any name you want |
| **Location type** | Zonal | Single zone (cheapest, no multi-zone overhead) |
| **Zone** | `asia-south1-a` (or your preferred zone) | 1 zone = 1 region |
| **Release channel** | Regular | Stable, updated automatically |
| **Kubernetes version** | Latest (e.g., 1.29+) | Let GKE pick |

### Step 4: Networking (CRITICAL for Internal Setup)

Click **"default-pool"** → **"Networking"** tab:

| Field | Value |
|-------|-------|
| **VPC network** | `default` (or create a new one) |
| **Node subnet** | `default` |
| **Private cluster** | ❌ Uncheck (for demo; simplifies setup) |
| **Enable VPC-native traffic routing** | ✅ Checked (automatic) |
| **Intranet visibility** | ❌ Leave unchecked |

> ⚠️ **"Public cluster" is OK for the demo**. Our INTERNAL Ingress setup makes ArgoCD unreachable from the internet regardless. For true hardening, enable Private Cluster in a later phase.

### Step 5: Node Pool Configuration

Click **"default-pool"** → **"Nodes"** tab:

| Field | Value |
|-------|-------|
| **Pool name** | `default-pool` |
| **Number of nodes** | **2** |
| **Machine type** | **e2-medium** (or e2-standard-2 if budget allows) |
| **Image type** | `Container-Optimized OS with containerd` |
| **Boot disk type** | `Standard persistent disk` |
| **Boot disk size** | **50 GB** |

Leave everything else default.

### Step 6: Security

| Field | Value |
|-------|-------|
| **Enable Workload Identity** | ✅ Checked (required for secure secret access later) |
| **Enable Shielded GKE Nodes** | ✅ Checked |

### Step 7: Create
1. Click **"Create"** at the bottom
2. Wait 5–8 minutes for the cluster to provision
3. You will see a green checkmark when ready

---

## 3.3 Option B: gcloud CLI — One Command

If you prefer the terminal (faster), use this command:

```bash
export PROJECT_ID="jovial-beach-499716-g8"
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
  --workload-pool=jovial-beach-499716-g8.svc.id.goog \
  --enable-shielded-nodes \
  --shielded-secure-boot \
  --shielded-integrity-monitoring \
  --enable-ip-alias \
  --addons=HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver \
  --labels=env=argocd,team=platform

echo "✅ Cluster created: $CLUSTER_NAME"
```

**Wait time**: 5–8 minutes. You will see progress in the terminal.

### Why These Flags?

| Flag | What It Does |
|------|-------------|
| `--zone` | Puts everything in ONE zone (single region, cheapest) |
| `--machine-type=e2-medium` | 1 vCPU, 4 GB RAM per node — enough for ArgoCD demo |
| `--num-nodes=2` | Exactly what the client wants |
| `--enable-autoscaling` | If ArgoCD needs more room, nodes auto-scale to 4 max |
| `--enable-workload-identity` | Lets Kubernetes pods securely access Google Cloud services |
| `--enable-shielded-nodes` | Boot security (verifies node integrity) |
| `--enable-ip-alias` | VPC-native networking (required for internal LB) |

---

## 3.4 Connect kubectl

```bash
# Download cluster credentials to your laptop
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

**If you see 2 nodes with status `Ready`, your cluster is alive.**

---

# 4. Phase 2 — Install ArgoCD

## 4.1 Add Helm Repository

```bash
# Add ArgoCD's Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

## 4.2 Create Namespace

```bash
kubectl create namespace argocd
```

## 4.3 Create Custom Values for 2-Node Cluster

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
  # We use TLS at the Ingress level, so ArgoCD server runs HTTP internally
  extraArgs:
    - --insecure
  ingress:
    enabled: false  # We create Ingress manually with NGINX

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

> **Important**: `server.insecure: true` means ArgoCD accepts HTTP internally. This is NOT a security problem because:
> 1. The cluster is private
> 2. NGINX terminates TLS before traffic reaches ArgoCD
> 3. Traffic between NGINX → ArgoCD never leaves the cluster network

## 4.4 Install ArgoCD

```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.8.10 \
  --values argocd-values.yaml \
  --wait --timeout 10m
```

## 4.5 Verify Installation

```bash
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

## 4.6 Test Port-Forward (Admin Access, Bypasses Ingress)

Before we set up Ingress, confirm ArgoCD works:

```bash
# In one terminal — creates a tunnel from your laptop to ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open browser: `http://localhost:8080`

You should see the ArgoCD login page with a **local admin** login.

Get the admin password:
```bash
argocd admin initial-password -n argocd
```

Login with username `admin` and that password just to verify the UI loads.

> **Port-forward is only for admin/testing.** It bypasses Ingress, SSO, and TLS. Once Ingress is working, normal users will NEVER use this.

---

# 5. Phase 3 — Generate Self-Signed Certificates

## 5.1 Why Self-Signed For This Demo?

Your client hasn't provided certificates yet. We generate a temporary one so we can:
- Test HTTPS access
- Verify TLS termination works
- Prove the Ingress setup is correct

Later, when the client provides their `.crt` and `.key` files, you simply replace the Secret. The entire setup stays the same.

## 5.2 Generate the Certificate

```bash
# Create a directory for certificates
mkdir -p certs && cd certs

# Generate a private key
openssl genrsa -out argocd.key 2048

# Generate a self-signed certificate (valid for 365 days)
openssl req -new -x509 -key argocd.key -out argocd.crt -days 365 \
  -subj "/C=IN/ST=MH/L=Mumbai/O=YourCompany/CN=argocd.yourcompany.internal"

# Verify files exist
ls -la argocd.key argocd.crt
```

**Output:**
```
-rw------- 1 user user 1704 Jun 20 10:00 argocd.key
-rw-r--r-- 1 user user 1302 Jun 20 10:00 argocd.crt
```

## 5.3 Store as Kubernetes Secret

```bash
# Go back to project root
cd ..

# Create a Kubernetes TLS secret in the argocd namespace
kubectl create secret tls argocd-server-tls \
  --namespace argocd \
  --cert=certs/argocd.crt \
  --key=certs/argocd.key

# Verify
kubectl get secret argocd-server-tls -n argocd
```

## 5.4 How to Use Client Certificates Later (Important!)

When your client gives you their real certificate files (e.g., `company.crt` and `company.key`):

```bash
# Step 1: Delete the old secret
kubectl delete secret argocd-server-tls -n argocd

# Step 2: Create new secret with client certs
kubectl create secret tls argocd-server-tls \
  --namespace argocd \
  --cert=company.crt \
  --key=company.key

# Step 3: Restart NGINX to pick up the new cert
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
```

> That's it. No other YAML changes needed.

---

# 6. Phase 4 — Internal Ingress (The Important Part)

This section creates the private, internal-only access path to ArgoCD.

## 6.1 Deploy NGINX Ingress Controller (Internal Only)

We install the official NGINX Ingress Controller but force it to create an **Internal Load Balancer** (not a public one).

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

  # Enable metrics (optional, for monitoring)
  metrics:
    enabled: false
EOF

# Install NGINX Ingress Controller
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values nginx-values.yaml \
  --wait --timeout 5m
```

### What Just Happened?

Check the service that was created:

```bash
kubectl get svc -n ingress-nginx
```

**Expected output:**
```
NAME                                 TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)
ingress-nginx-controller             LoadBalancer   10.100.10.10    10.0.15.30    80:30000/TCP,443:30443/TCP
```

Notice two things:
1. **TYPE = LoadBalancer** — Google Cloud created a real Load Balancer
2. **EXTERNAL-IP = 10.0.15.30** — This is a **PRIVATE** IP address (starts with `10.x.x.x`), not a public one

### Why Is the IP Private?

Because of this annotation in `nginx-values.yaml`:
```yaml
cloud.google.com/load-balancer-type: "Internal"
```

Without this annotation, Google Cloud would create a **public** Load Balancer with an IP like `34.120.x.x`. With the annotation, it creates an **internal** Load Balancer with a **private** IP inside your VPC.

## 6.2 Create ArgoCD Ingress with TLS

Now we create an Ingress rule that tells NGINX:
- "When someone visits `argocd.yourcompany.internal`, send them to ArgoCD"
- "Use the TLS certificate we created"
- "Redirect HTTP to HTTPS"

```bash
cat > argocd-ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    # Use the NGINX ingress class
    nginx.ingress.kubernetes.io/ingress.class: nginx
    # Redirect all HTTP to HTTPS
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    # ArgoCD needs this for WebSocket / real-time sync
    nginx.ingress.kubernetes.io/proxy-read-timeout: "1800"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "1800"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - argocd.yourcompany.internal
      secretName: argocd-server-tls
  rules:
    - host: argocd.yourcompany.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF

kubectl apply -f argocd-ingress.yaml
```

### Ingress YAML Explained

| Field | What It Does |
|-------|-------------|
| `ingressClassName: nginx` | "Use the NGINX Ingress Controller we installed" |
| `tls.secretName` | "Use the `argocd-server-tls` Secret for HTTPS encryption" |
| `rules.host` | "Only match requests for `argocd.yourcompany.internal`" |
| `ssl-redirect` | "If someone types `http://...`, automatically redirect to `https://...`" |
| `proxy-read-timeout` | "ArgoCD uses WebSockets for live sync status — needs long timeouts" |

## 6.3 Get Internal IP & Test

### Step 1: Get the Internal LB IP

```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx
```

Look at the `EXTERNAL-IP` column (yes, it's confusingly named — but when Internal LB is used, this field shows the **private IP**):

```
EXTERNAL-IP
10.0.15.30
```

> Note: This IP is **NOT** exposed to the internet. Only things inside your VPC can reach it.

Save it:
```bash
export ARGOCD_INTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "ArgoCD Internal IP: $ARGOCD_INTERNAL_IP"
```

### Step 2: Test from a Pod Inside the Cluster

Since the LB is internal, you can't test from your laptop (unless on VPN). But you CAN test from a pod inside the cluster:

```bash
# Run a temporary test pod
kubectl run test-pod --image=curlimages/curl -it --rm -- \
  -k -I https://$ARGOCD_INTERNAL_IP \
  --resolve argocd.yourcompany.internal:443:$ARGOCD_INTERNAL_IP
```

**Expected output:**
```
HTTP/2 307
location: https://argocd.yourcompany.internal/login
```

If you see `307` or `200`, the Ingress + TLS + ArgoCD chain is working!

### Step 3: Verify the Ingress Resource

```bash
kubectl get ingress -n argocd
kubectl describe ingress argocd-ingress -n argocd
```

You should see the NGINX controller listed under `Ingress Class` and the correct backend.

---

# 7. Phase 5 — Google SSO

We now connect ArgoCD to Google so users can log in with their company Google accounts.

## 7.1 Create OAuth App in Google Cloud

### Step 1: Configure OAuth Consent Screen

1. Go to https://console.cloud.google.com/apis/credentials/consent
2. Click **"Create"** (or **"Edit"** if one exists)
3. Choose **"Internal"** (only users in your Google Workspace organization)
   - If you don't have Google Workspace, choose **"External"** for the demo
4. Fill in the app info:
   - **App name**: `ArgoCD Internal Dashboard`
   - **User support email**: your email
   - **Contact email**: your email
5. Click **"Save and Continue"**
6. On **Scopes**, click **"Add or Remove Scopes"**
   - Add these scopes:
     - `openid`
     - `userinfo.profile`
     - `userinfo.email`
   - Click **"Update"** → **"Save and Continue"**
7. On **Test Users**, add your email and any test colleagues
8. Click **"Save and Continue"** → **"Back to Dashboard"**

### Step 2: Create OAuth Client ID

1. Go to https://console.cloud.google.com/apis/credentials
2. Click **"+ Create Credentials"** → **"OAuth client ID"**
3. **Application type**: **"Web application"**
4. **Name**: `ArgoCD SSO`
5. **Authorized redirect URIs**: Click **"+ Add URI"**
   - Add exactly this (replace YOUR_INTERNAL_IP or use hostname):
   ```
   http://localhost:8080/api/dex/callback
   ```
   > ⚠️ We'll update this later to the real hostname. For now, use localhost for the Dex config that uses `argocd-cm`.

   Actually, for a proper internal setup, the redirect URI must match the URL in `argocd-cm`. Let's set it up correctly from the start.

   Since ArgoCD inside the cluster uses its internal service name, we need the redirect URI to match.

   For simplicity during setup/testing, or if using port-forward temporarily:
   ```
   http://localhost:8080/api/dex/callback
   ```

   But for the actual internal hostname:
   ```
   https://argocd.yourcompany.internal/api/dex/callback
   ```

   **Recommendation**: Add BOTH:
   - `http://localhost:8080/api/dex/callback` (for testing via port-forward)
   - `https://argocd.yourcompany.internal/api/dex/callback` (for production internal access)

6. Click **"Create"**
7. **Copy the Client ID and Client Secret** — you will NOT see the secret again

## 7.2 Store OAuth Secret in Kubernetes

```bash
# Replace these with your actual values
export GOOGLE_CLIENT_ID="paste-your-client-id-here.apps.googleusercontent.com"
export GOOGLE_CLIENT_SECRET="paste-your-client-secret-here"

# Create a Kubernetes secret
kubectl create secret generic google-oauth \
  --namespace argocd \
  --from-literal=dex.google.clientSecret="$GOOGLE_CLIENT_SECRET"
```

## 7.3 Configure Dex in ArgoCD

ArgoCD uses **Dex** as an identity middleware. We tell Dex to use Google as the identity provider.

```bash
# Patch the ArgoCD configmap
kubectl patch configmap argocd-cm -n argocd --type merge -p '{
  "data": {
    "url": "https://argocd.yourcompany.internal",
    "dex.config": "connectors:\n  - type: google\n    id: google\n    name: Google\n    config:\n      clientID: '"$GOOGLE_CLIENT_ID"'\n      clientSecret: \$google-oauth:dex.google.clientSecret\n      redirectURI: https://argocd.yourcompany.internal/api/dex/callback\n      # Restrict logins to your company domain only\n      hostedDomains:\n        - yourcompany.com"
  }
}'
```

### Dex Config Explained

| Line | Meaning |
|------|---------|
| `type: google` | Use Google's OAuth 2.0 API |
| `clientID` | Your Google OAuth app's client ID |
| `clientSecret: $google-oauth:...` | Reference to the K8s Secret we created |
| `redirectURI` | Where Google sends users after login — MUST match Google Console exactly |
| `hostedDomains` | **CRITICAL**: Only allows `@yourcompany.com` emails. Blocks personal Gmail accounts. |

## 7.4 Restart ArgoCD Dex & Server

```bash
kubectl rollout restart deployment argocd-dex-server -n argocd
kubectl rollout restart deployment argocd-server -n argocd

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-dex-server -n argocd --timeout=120s
```

## 7.5 Test Login via Port-Forward (Before Ingress Is Fully Ready)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Open `http://localhost:8080`:
1. Click **"LOG IN VIA GOOGLE"**
2. Google asks you to authorize
3. After authorization, you are redirected back to ArgoCD

If you log in successfully, SSO is working!

> **Important**: If you see an error about `redirect_uri_mismatch`, check that the redirect URI in Google Console matches your `argocd-cm` config exactly.

## 7.6 Disable Local Admin (After SSO Is Verified)

Once you confirm SSO works, disable the built-in admin user:

```bash
kubectl patch configmap argocd-cm -n argocd \
  --type merge -p '{"data":{"admin.enabled":"false"}}'

kubectl rollout restart deployment argocd-server -n argocd
```

> ⚠️ **DON'T do this until you have successfully logged in via Google at least once!** If you disable admin and SSO breaks, you will lock yourself out.

If you get locked out, re-enable admin:
```bash
kubectl patch configmap argocd-cm -n argocd \
  --type merge -p '{"data":{"admin.enabled":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
```

---

# 8. Phase 6 — RBAC (Role-Based Access Control)

## 8.1 The RBAC File Explained Line by Line

We create a ConfigMap called `argocd-rbac-cm` that defines WHO can do WHAT.

### Groups You Will Use (Google Workspace / Company)

| Google Group | Members | What They Can Do |
|-------------|---------|-----------------|
| `devops@yourcompany.com` | DevOps team | Everything (admin) |
| `developers@yourcompany.com` | Developers | Deploy/sync apps, cannot create/delete |
| `auditors@yourcompany.com` | QA / Security | Read-only, view everything |

### The RBAC Policy Format

Each line looks like this:
```
p, role:developer, applications, sync, */*, allow
│  │              │             │     │    └─ Action: allow or deny
│  │              │             │     └─ Resource path: */* = all apps
│  │              │             └─ Action type: sync, get, create, delete...
│  │              └─ Resource: applications, projects, repositories...
│  └─ Role name
└─ p = policy line (g = group mapping line)
```

## 8.2 Apply RBAC Config

```bash
cat > argocd-rbac.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  # Default: anyone without a role gets read-only
  policy.default: role:readonly

  policy.csv: |
    # =========================================================
    # ADMIN ROLE — Full control
    # Members of devops@yourcompany.com get this role
    # =========================================================
    p, role:admin, applications, *, */*, allow
    p, role:admin, projects, *, *, allow
    p, role:admin, repositories, *, *, allow
    p, role:admin, certificates, *, *, allow
    p, role:admin, accounts, *, *, allow
    p, role:admin, gpgkeys, *, *, allow
    p, role:admin, exec, create, */*, allow

    # =========================================================
    # DEVELOPER ROLE — Can deploy but cannot destroy
    # Members of developers@yourcompany.com get this role
    # =========================================================
    p, role:developer, applications, get, */*, allow
    p, role:developer, applications, sync, */*, allow
    p, role:developer, applications, rollback, */*, allow
    p, role:developer, projects, get, *, allow
    p, role:developer, repositories, get, *, allow
    # Explicit DENY for destructive actions
    p, role:developer, applications, create, */*, deny
    p, role:developer, applications, delete, */*, deny
    p, role:developer, applications, update, */*, deny
    p, role:developer, projects, create, *, deny
    p, role:developer, projects, delete, *, deny

    # =========================================================
    # READONLY ROLE — View only, change nothing
    # Default for anyone else
    # =========================================================
    p, role:readonly, applications, get, */*, allow
    p, role:readonly, projects, get, *, allow
    p, role:readonly, repositories, get, *, allow

    # =========================================================
    # GROUP MAPPINGS — Map Google groups to ArgoCD roles
    # IMPORTANT: For group mapping to work with Google + Dex,
    # you need domain-wide delegation (see production note below).
    # For the demo, we also map individual emails.
    # =========================================================
    g, devops@yourcompany.com, role:admin
    g, developers@yourcompany.com, role:developer
    g, auditors@yourcompany.com, role:readonly

    # Demo fallback — map specific email addresses
    # Replace with YOUR actual emails for testing
    g, your-email@yourcompany.com, role:admin
    g, dev-email@yourcompany.com, role:developer
  scopes: "[email, groups]"
EOF

kubectl apply -f argocd-rbac.yaml
```

> **About Google Groups in Dex**: For Dex to read Google Groups, you need a Google Workspace admin to enable "Domain-wide delegation" and grant the `admin.directory.group.readonly` scope. This is a **production step**. For the demo, mapping individual emails (the lines at the bottom) works without any admin delegation.

### How to Enable Google Group Fetching (Production)

1. In Google Cloud Console → IAM → Service Accounts → Create SA named `argocd-dex-groups-sa`
2. Enable G Suite Domain-wide Delegation on that SA
3. In Google Admin Console → Security → API Controls → Domain-wide Delegation:
   - Add the SA's Client ID
   - Scope: `https://www.googleapis.com/auth/admin.directory.group.readonly`
4. Download the JSON key and mount it into the Dex pod
5. Update `dex.config` in `argocd-cm` with:
```yaml
fetchGroups: true
adminEmail: admin@yourcompany.com
serviceAccountFilePath: /etc/dex/google-sa.json
```

For the demo, skip this and use individual email mappings.

## 8.3 Restart Server

```bash
kubectl rollout restart deployment argocd-server -n argocd
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s
```

## 8.4 Test Each Role

| Test | How | Expected Result |
|------|-----|-----------------|
| **Admin** | Log in with your email | See "Settings", "New App" button, can delete |
| **Developer** | Log in with dev email | Can sync apps, cannot see "New App", cannot delete |
| **Readonly** | Log in with auditor email | Can view apps, sync button greyed out |
| **Personal Gmail** | Try logging in with @gmail.com | Blocked by `hostedDomains` in Dex config |

---

# 9. Phase 7 — Verification & Go-Live

## 9.1 Full Checklist

```
□ GKE cluster created with 2 nodes, e2-medium
□ kubectl connected to cluster
□ ArgoCD installed and all pods Running
□ Internal NGINX Ingress Controller installed
□ LoadBalancer Service shows private IP (10.x.x.x)
□ ArgoCD Ingress created with TLS and hostname
□ Self-signed certificate stored as K8s Secret
□ Google OAuth app created with correct redirect URI
□ Dex configured with Google connector
□ SSO login works (admin account disabled after)
□ RBAC ConfigMap applied
□ All 3 roles tested (admin / developer / readonly)
□ Personal Gmail blocked by hostedDomains
```

## 9.2 Manager Demo Script

### Scene 1: Show the Architecture (30 seconds)

> *"We have deployed ArgoCD on a 2-node GKE cluster in a single region. The entire setup is internal-only — there is no public IP address. Only computers inside our company network can reach it."*

Open the diagram:
```bash
echo "ArgoCD Internal IP: $ARGOCD_INTERNAL_IP"
```

> *"This IP — $ARGOCD_INTERNAL_IP — is a private address. It does not exist on the internet. It is exactly like your laptop at home having `192.168.1.10` — only your WiFi devices can reach it."*

### Scene 2: Show SSO (1 minute)

> *"No local passwords. Everyone logs in with their company Google account."*

1. Open `https://argocd.yourcompany.internal` (or via VPN/company network)
2. Click **"Login with Google"**
3. Log in

> *"If I try with my personal Gmail — blocked. Only @yourcompany.com emails work."*

### Scene 3: Show RBAC (1 minute)

> *"Not everyone gets the same permissions."*

1. Click **Settings → Accounts**
2. Point out your role: **Admin**
3. Open incognito window, log in as developer email
4. Show: No "New App" button, no Settings menu
5. Try to delete an app → Forbidden

### Scene 4: Explain Internal Security (30 seconds)

> *"There is zero internet exposure. No WAF needed. No DDoS protection needed. The load balancer simply does not have a public IP. You cannot hack what you cannot reach."*

---

# 10. Accessing ArgoCD from Your Laptop

Since the LoadBalancer is **internal only**, your laptop cannot reach it directly unless you are somehow inside the Google VPC.

## Option 1: kubectl port-forward (Admin Only)

Fastest way for you (the admin) to access ArgoCD:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Then open `http://localhost:8080` on your laptop.

> ⚠️ This bypasses Ingress, SSO, and TLS completely. Only use this for admin emergencies.

## Option 2: VPN / Company Network

If your company has a VPN that connects your laptop to the Google VPC:
1. Connect to the VPN
2. Add to your laptop's `/etc/hosts` file:
   ```
   10.0.15.30  argocd.yourcompany.internal
   ```
3. Open `https://argocd.yourcompany.internal` in your browser
4. Accept the self-signed certificate warning (expected for demo)

## Option 3: Cloud IAP (Identity-Aware Proxy) — Production

For a production internal setup where employees need occasional access without a full VPN:

Google Cloud IAP can act as a secure frontend:
1. IAP sits in front of your internal resource
2. Employees authenticate with their Google account via IAP
3. IAP forwards the request to the internal IP

This is out of scope for the demo but worth mentioning to your client.

## Option 4: Bastion Host (Jump Box)

1. Create a small VM (f1-micro) in the same VPC
2. Allow SSH from your IP only
3. SSH into the bastion: `gcloud compute ssh bastion-host`
4. From the bastion, run: `curl -k https://10.0.15.30`

This proves the internal access works from within the VPC.

---

# 11. Monthly Cost Estimate

| Line Item | Detail | Monthly Cost (USD) | ~Monthly (₹) |
|-----------|--------|-------------------|--------------|
| GKE cluster management | $0.10/hr × 730 | **$73.00** | **~₹6,088** |
| 2 × e2-medium nodes | $0.0335/hr × 730 × 2 | **$48.91** | **~₹4,079** |
| Boot disks 2 × 50 GB pd-standard | $0.040/GB × 50 × 2 | **$4.00** | **~₹334** |
| Internal Load Balancer | Forwarding rule: $0.025/hr × 730 | **$18.25** | **~₹1,522** |
| **Total** | | **~$144.16** | **~₹12,023** |

**2-week demo cost (prorated):** ~**$67** (~₹5,586)

### Cost Levers

| Change | Monthly Savings | When to Apply |
|--------|----------------|---------------|
| Use e2-medium instead of e2-standard-2 | ~$49/mo | Already done for demo |
| Use zonal instead of regional cluster | $0 (control plane fee same) | Already done |
| 1-Year Committed Use Discount | ~$18/mo | After cluster runs stable for 1 month |
| Delete cluster after demo | $144/mo saved | When demo ends |

---

# 12. Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `Pending` pods on ArgoCD | Not enough resources | `kubectl top nodes` to check CPU/RAM. Scale node pool: `gcloud container clusters resize argocd-cluster --node-pool default-pool --num-nodes 3 --zone asia-south1-a` |
| `Certificate not trusted` | Self-signed cert | Expected. Click "Advanced → Proceed" in browser. Or add cert to OS trust store. |
| SSO button missing | Dex not enabled or url not set in `argocd-cm` | Check `kubectl get cm argocd-cm -n argocd -o yaml`. Ensure `url:` field exists. |
| `redirect_uri_mismatch` | Google OAuth redirect URI doesn't match | In Google Console, the redirect URI MUST exactly match `https://argocd.yourcompany.internal/api/dex/callback` |
| Google login blocked | `hostedDomains` mismatch | Ensure user's email domain matches the `hostedDomains` list in dex.config |
| RBAC not working | Email not in policy.csv | Map individual emails for demo: `g, your-email@yourcompany.com, role:admin` |
| `502 Bad Gateway` | ArgoCD pods not healthy | `kubectl get pods -n argocd` — wait for all `1/1 Running` |
| `404 Not Found` on Ingress | Ingress rules not matching hostname | Check `kubectl get ingress -n argocd -o yaml`. Ensure `host:` matches what you type in browser. |
| Internal LB IP doesn't appear | VPC-native networking not enabled | Cluster must have `--enable-ip-alias` (default on new GKE, but verify) |
| Cannot reach LB from VM | Firewall rules blocking 443 | Update firewall: `gcloud compute firewall-rules create allow-internal-https --network default --allow tcp:443 --source-ranges 10.0.0.0/8` |
| Lockout (no admin + SSO broken) | Disabling admin before SSO works | `kubectl patch cm argocd-cm -n argocd -p '{"data":{"admin.enabled":"true"}}'` |

---

# 13. Quick Command Cheat Sheet

```bash
# ===== CLUSTER =====
gcloud container clusters get-credentials argocd-cluster --zone=asia-south1-a
kubectl get nodes

# ===== ARGOCD =====
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
kubectl get pods -n argocd
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-dex-server --tail=50
argocd admin initial-password -n argocd

# ===== INGRESS =====
kubectl get svc -n ingress-nginx
kubectl get ingress -n argocd
export ARGOCD_INTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# ===== SECRETS =====
kubectl create secret tls argocd-server-tls -n argocd --cert=certs/argocd.crt --key=certs/argocd.key
kubectl create secret generic google-oauth -n argocd --from-literal=dex.google.clientSecret="SECRET"

# ===== CONFIG =====
kubectl get cm argocd-cm -n argocd -o yaml
kubectl get cm argocd-rbac-cm -n argocd -o yaml
kubectl edit cm argocd-cm -n argocd

# ===== RESTARTS =====
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout restart deployment argocd-dex-server -n argocd
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx

# ===== PORT-FORWARD (admin bypass) =====
kubectl port-forward svc/argocd-server -n argocd 8080:80

# ===== CLEANUP (to save money) =====
helm uninstall argocd -n argocd
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace argocd
kubectl delete namespace ingress-nginx
gcloud container clusters delete argocd-cluster --zone=asia-south1-a
```

---

**End of Guide.**

> 💡 **When your client provides real certificates**: Replace the `argocd-server-tls` Secret. Everything else stays the same.
>
> 💡 **When adding dev / uat / prod clusters**: Use `argocd cluster add` after connecting kubectl to each cluster. They do NOT need to be on this same GKE cluster — they can be anywhere.
