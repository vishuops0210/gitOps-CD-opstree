# ArgoCD on GKE — Internal Access Explained Like You're 5

> **Goal**: Understand EVERY step of why we set up what we set up — no jargon, no skipping, so you can confidently explain to your manager.
>
> **Date**: June 2026

---

## Table of Contents

1. [The Big Picture — What Are We Building?](#1-the-big-picture)
2. [Why Internal-Only? The Apartment Analogy](#2-why-internal-only)
3. [What Is GKE Ingress? (Google Managed)](#3-what-is-gke-ingress)
4. [Every Component Explained One by One](#4-every-component-explained)
   - 4.1 [Proxy-Only Subnet](#41-proxy-only-subnet)
   - 4.2 [Firewall Rules](#42-firewall-rules)
   - 4.3 [Regional Static IP](#43-regional-static-ip)
   - 4.4 [Regional SSL Certificate](#44-regional-ssl-certificate)
   - 4.5 [BackendConfig](#45-backendconfig)
   - 4.6 [FrontendConfig](#46-frontendconfig)
   - 4.7 [NEG Annotation](#47-neg-annotation)
5. [The Full Traffic Flow — Step by Step](#5-the-full-traffic-flow)
6. [What Happens During Helm Install?](#6-what-happens-during-helm-install)
7. [Verification Commands](#7-verification-commands)
8. [Common Errors We Already Hit (and Why)](#8-common-errors)
9. [Cost Summary](#9-cost-summary)
10. [Manager Talking Points](#10-manager-talking-points)

---

# 1. The Big Picture

## What Are We Building?

We have a **Google Kubernetes Engine (GKE) cluster** — that is, a group of virtual machines (servers) running inside Google Cloud.

On this cluster, we installed **ArgoCD** — a tool that lets you manage Kubernetes apps from a web UI.

**Our goal**: Make ArgoCD accessible only from inside the company network. Nobody on the internet can reach it.

## How Do People Reach It?

```
Manager's laptop (inside office / VPN connected)
        │
        │ types in browser: https://argocd.yourcompany.internal
        │
        ▼
┌─────────────────────────────────┐
│ Google Cloud Load Balancer      │
│ (private IP only)               │
│ Terminates TLS (decrypts HTTPS) │
└─────┬───────────────────────────┘
      │ Now it's regular HTTP inside
      ▼
┌─────────────────────────────────┐
│ ArgoCD Web Server               │
│ (shows login page)              │
└─────────────────────────────────┘
```

**Key rule**: Anyone outside the company sees nothing. The IP is private.

---

# 2. Why Internal-Only? The Apartment Analogy

## Normal Website (Public)

Imagine a **public restaurant**:
- Address: `123 Main Street` (public address that anyone can find)
- Anyone can walk in from the street
- Needs security guards (WAF, DDoS protection)

## Our Setup (Private)

Imagine a **company cafeteria inside a locked office building**:
- Address: `Floor 3, Building A` (only people with a company badge can enter)
- You need a **company badge** (VPN) to enter the building
- No random person from the street can even find the elevator
- It's already secure because the building is locked

**Our ArgoCD is the cafeteria.** The Google Cloud VPC is the office building. The VPN badge is how employees get in.

---

# 3. What Is GKE Ingress? (Google Managed)

## Simple Definition

> **Ingress** = A door into your Kubernetes cluster that knows WHERE to send traffic.

When you type `https://argocd.yourcompany.internal` into your browser:
1. Something needs to receive that request
2. Something needs to decrypt HTTPS
3. Something needs to find the ArgoCD pod
4. Something needs to forward the request to ArgoCD

**GKE Ingress is Google doing steps 1-4 for you.**

### Two Types of Ingress

| Type | Google Class Name | What It Is | Who Manages It |
|------|-------------------|------------|----------------|
| **External** (public internet) | `gce` | For public websites | Google |
| **Internal** (company network only) | `gce-internal` | For internal tools | Google |

We chose **`gce-internal`** because ArgoCD must be private.

### What's Inside This "Door"?

When you create an Ingress with `gce-internal`, Google automatically builds:

```
┌────────────────────────────────────┐
│ Forwarding Rule                     │ ← Receives traffic on IP + port
│  IP: 10.160.0.18                    │
│  Port: 443                          │
└────────┬───────────────────────────┘
         │
         ▼
┌────────────────────────────────────┐
│ Target HTTPS Proxy                  │ ← Handles TLS/SSL decryption
│  Certificate: argocd-selfsigned     │
└────────┬───────────────────────────┘
         │
         ▼
┌────────────────────────────────────┐
│ URL Map                             │ ← Reads hostname, decides where to go
│  "argocd.yourcompany.internal"     │
│    → Backend Service for ArgoCD     │
└────────┬───────────────────────────┘
         │
         ▼
┌────────────────────────────────────┐
│ Backend Service + Health Checks     │ ← "Is ArgoCD alive? Can I send traffic?"
└────────┬───────────────────────────┘
         │
         ▼
┌────────────────────────────────────┐
│ Network Endpoint Group (NEG)        │ ← List of ArgoCD pod IPs
│  Pod 1: 10.82.1.5:8080             │
│  Pod 2: 10.82.2.9:8080             │
└────────┬───────────────────────────┘
         │
         ▼
┌────────────────────────────────────┐
│ ArgoCD Pod (Container)              │ ← Serves the web UI
└────────────────────────────────────┘
```

**You write one YAML file (Ingress). Google builds ALL of this automatically.**

---

# 4. Every Component Explained One by One

## 4.1 Proxy-Only Subnet

### What Is It?

> A **proxy-only subnet** is a small block of private IP addresses that Google reserves for its own internal load balancer proxies.

### The Analogy

Imagine your office building has:
- **Employee area** (where your team works) = your cluster nodes
- **Reception area** (where guests sign in) = proxy-only subnet

Google's load balancer needs a "reception desk" inside your building to sit. You must tell Google: "Here, use this part of the building for your reception."

### Why Do We Need It?

Google's Internal Load Balancer is not a pod inside your cluster. It runs outside your cluster but inside your VPC (network). Google needs to place its proxy VMs somewhere. That "somewhere" is the proxy-only subnet.

Without it, the load balancer literally cannot exist.

### How Big Is It?

Google recommends `/23` (512 IPs). That's it — just a reservation. You're not charged per IP.

### Command to Verify

```bash
gcloud compute networks subnets list \
  --network=default \
  --filter="purpose=REGIONAL_MANAGED_PROXY"
```

**Expected output:**
```
NAME                   REGION        NETWORK  RANGE
argocd-proxy-subnet  asia-south1   default  10.129.0.0/23
```

### What If Someone Deletes It?

The Ingress will fail to sync. The `kubectl get events` will show errors about missing proxy subnet.

```bash
kubectl get events -n argocd --field-selector involvedObject.kind=Ingress
```

---

## 4.2 Firewall Rules

### What Are They?

> **Firewall rules** are bouncers. They decide who is ALLOWED to talk to your pods.

### The Analogy

Your office building has a security desk. The security guard checks IDs:
- People with a company badge → let in
- Random strangers → block

### Why Do We Need TWO Firewall Rules?

| Rule | Who It Lets In | Why |
|------|----------------|-----|
| **allow-proxy** | Google's proxy VMs (from proxy subnet) | The load balancer needs to reach ArgoCD pods |
| **allow-gcp-health-checks** | Google's health check systems | Google pings your pods every few seconds to see if they're alive |

### Rule 1: allow-proxy-to-argocd

```
Google Proxy VM (10.129.0.x) ──► ArgoCD Pod (10.82.x.x)
via firewall rule on port 8080
```

Without this rule: The proxy tries to reach ArgoCD → blocked → **502 Bad Gateway**

### Rule 2: allow-gcp-health-checks

Google has two special IP ranges it uses to check if your pods are healthy:
- `130.211.0.0/22`
- `35.191.0.0/16`

Every few seconds, Google sends a ping: "Hey ArgoCD, are you alive?"
ArgoCD must respond with HTTP 200 on `/healthz`.

Without this rule: Health checks fail → Backends marked UNHEALTHY → **no traffic sent**

### Commands to Verify

```bash
# List firewall rules you created
gcloud compute firewall-rules list --filter="name~allow-proxy OR name~allow-gcp"
```

**Expected output:**
```
NAME                         NETWORK  DIRECTION  PRIORITY  ALLOW
allow-proxy-to-argocd        default  INGRESS    900       tcp:8080
allow-gcp-health-checks      default  INGRESS    910       tcp:8080
```

### Quick Health Check

```bash
# Check if ArgoCD pod responds to /healthz
kubectl exec deployment/argocd-server -n argocd -- wget -qO- http://localhost:8080/healthz
```

**Expected output:**
```
ok
```

---

## 4.3 Regional Static IP

### What Is It?

> A **static IP address** that never changes. It's like a permanent phone number.

### The Analogy

Imagine your company's main reception phone number:
- **Without static IP** (ephemeral) → Google gives you a new number every week → you have to update business cards constantly
- **With static IP** → Same number forever → tell everyone once

### Why Do We Need It?

Without a static IP, every time you delete and recreate the Ingress, Google gives you a DIFFERENT IP. Then:
- DNS entries break
- VPN routes break
- Team bookmarks break

### Command to Verify

```bash
# Check if your reserved IP exists
gcloud compute addresses describe argocd-internal-ip \
  --region=asia-south1 \
  --format="table(name,address,status)"
```

**Expected output:**
```
NAME               ADDRESS       STATUS
argocd-internal-ip 10.160.0.18   IN_USE
```

### Check It on the Ingress

```bash
kubectl get ingress argocd-server -n argocd
```

**Expected:**
```
NAME            CLASS   HOSTS                         ADDRESS       PORTS   AGE
argocd-server   <none>  argocd.yourcompany.internal   10.160.0.18   80      2m
```

If `ADDRESS` is blank, the Ingress is still provisioning.

---

## 4.4 Regional SSL Certificate

### What Is It?

> An SSL/TLS certificate uploaded to Google Cloud so the load balancer can prove its identity and encrypt traffic.

### The Analogy

A certificate is like a **company ID badge**:
- It says "I am who I claim to be"
- It has your company name on it
- Clients (browsers) check it before trusting you

### Why Do We Upload It to Google (Not Just Kubernetes)?

With NGINX Ingress, Kubernetes holds the certificate as a Secret, and NGINX (a pod) does the TLS handshake.

With GCE Ingress, Google manages the LB entirely. The LB itself terminates TLS. So **Google needs the certificate in its own system** — not just inside Kubernetes.

### Two Types of Certs

| Type | How Created | For |
|------|-------------|-----|
| **Self-signed** | You generate it with `openssl` | Demo, testing, internal tools |
| **CA-signed** | Your client's IT team gives you `.crt` + `.key` | Production |

**Google-managed (Let's Encrypt) is NOT supported for internal LBs.**

### Command to Verify

```bash
gcloud compute ssl-certificates list --region=asia-south1
```

**Expected output:**
```
NAME                    TYPE    CREATION_TIMESTAMP
argocd-selfsigned-cert  SELF_MANAGED  2026-06-22T10:00:00
```

### Check It Through kubectl

```bash
kubectl get ingress argocd-server -n argocd -o yaml | grep ssl-cert
```

**Expected:**
```yaml
ingress.gcp.kubernetes.io/ssl-cert: argocd-selfsigned-cert
```

---

## 4.5 BackendConfig

### What Is It?

> A **BackendConfig** tells Google: "Here's how to check if my app is healthy."

### The Analogy

Imagine a hospital with multiple nurses:
- Each nurse has a patient
- Every 10 minutes, a nurse checks: "Are you breathing? Pulse?"
- If no response 3 times: patient is UNHEALTHY → move to emergency

**BackendConfig = the nurse's checklist.**

### Why Do We Need It?

Google sends health check pings to your ArgoCD pod. BackendConfig tells Google:
- Where to check: `/healthz`
- Which port: `8080`
- How often: every 10 seconds
- How many failures before calling it dead: 3
- How many successes before calling it healthy: 2

Without BackendConfig:
- Google uses a default health check (often just `/`)
- ArgoCD might not respond to `/` → health check fails → backend marked UNHEALTHY
- No traffic sent → ArgoCD unreachable → **502 errors**

### Our BackendConfig

```yaml
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: argocd-backend-config
  namespace: argocd
spec:
  healthCheck:
    checkIntervalSec: 10       # Check every 10 seconds
    timeoutSec: 5              # Each check times out after 5 seconds
    healthyThreshold: 2        # Must pass 2 times to be "healthy"
    unhealthyThreshold: 3      # Can fail 3 times before "unhealthy"
    type: HTTP                 # Protocol
    requestPath: /healthz      # Path to hit
    port: 8080                 # Port (container port, NOT service port)

  timeoutSec: 300              # How long a connection can be idle
```

### Important: Port is 8080

**The health check port must be the CONTAINER port, not the Service port.**

ArgoCD server container listens on port `8080`. The Kubernetes Service might expose it as port `80`. But Google checks the actual container directly (container-native LB). So we tell it `8080`.

### Command to Verify

```bash
kubectl get backendconfig argocd-backend-config -n argocd -o yaml
```

### Check Health Status

```bash
# Get backend name from Ingress
kubectl get ingress argocd-server -n argocd -o jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/backends}'
```

**Expected:**
```json
{"k8s1-14a21725-argocd-argocd-server-80-72841769":"HEALTHY"}
```

If it says `UNHEALTHY`, your BackendConfig is wrong or the pod is down.

---

## 4.6 FrontendConfig

### What Is It?

> A **FrontendConfig** controls what the load balancer does "at the door" before routing to your app.

### Why We Originally Wanted It

We added `redirectToHttps` to FrontendConfig:
```yaml
spec:
  redirectToHttps:
    enabled: true
```

This means: "If someone types `http://`... automatically redirect them to `https://`"

### Why It Broke for gce-internal

**Google's Internal Load Balancer does NOT support FrontendConfig.** It's a known limitation.

When we tried it, Google said:
```
Error: cannot enable HTTPS Redirects with L7 ILB
```

### The Fix

Instead of FrontendConfig, we use an **annotation on the Ingress**:
```yaml
kubernetes.io/ingress.allow-http: "false"
```

This tells Google: "Block HTTP entirely." It's actually **more secure** than a redirect because:

| Behavior | What happens | Security |
|----------|-------------|----------|
| Redirect | Accept HTTP → send 301 redirect | ⚠️ Hacker can still probe your HTTP port |
| Block (`allow-http: false`) | Reject HTTP immediately | ✅ Hacker gets no response at all |

### Do We Even Need FrontendConfig Now?

**Technically no** — it does nothing for `gce-internal`. We keep it empty (`spec: {}`) because we reference it in the Ingress annotation. In the future, Google might add more features.

### Check It

```bash
kubectl get frontendconfig argocd-frontend-config -n argocd -o yaml
```

**Should show:**
```yaml
spec: {}
```

---

## 4.7 NEG Annotation

### What Is NEG?

> **NEG** = Network Endpoint Group. A list of pod IPs that the load balancer can send traffic to.

### The Analogy

NEG is like a **contact list**:
- "Call these three people if someone asks for ArgoCD"
- "Person 1: 10.82.1.5"
- "Person 2: 10.82.2.9"

Google maintains this list automatically.

### Why Do We Need It?

Without NEGs, traffic flows through the node VM (the "server machine") first, then to the pod:
```
LB → Node IP → kube-proxy → Pod IP
```

With NEGs, traffic goes **directly to the pod**:
```
LB → Pod IP (directly)
```

**Benefits of direct routing:**
- Faster (no extra hop)
- Better for scaling (any pod, any node)
- Better health monitoring (Google knows if each individual pod is healthy)

### How We Enable NEG

We add an annotation to the ArgoCD Service:
```yaml
cloud.google.com/neg: '{"ingress": true}'
```

This tells Google: "For this Service, create a NEG and track all pod IPs."

### Verify NEG Exists

```bash
# Check the annotation on the Service
kubectl get service argocd-server -n argocd -o jsonpath='{.metadata.annotations.cloud\.google\.com/neg}'
```

**Expected:**
```json
{"ingress": true}
```

### Verify GCP Created a NEG

```bash
# List NEGs in your region
gcloud compute network-endpoint-groups list --region=asia-south1 \
  --format="table(name, network, subnetwork, zone, size)"
```

**Expected:**
```
NAME                                         NETWORK  SUBNETWORK  ZONE           SIZE
k8s1-14a21725-argocd-argocd-server-80-xxx  default  default     asia-south1-a  1
```

If `SIZE` starts at 0, it means ArgoCD pod just started. It should grow to 1 within a minute.

---

# 5. The Full Traffic Flow — Step by Step

## Scenario: You open ArgoCD from inside the VPC

**You are a pod inside the cluster (or a VM, or a VPN-connected laptop).**

```
STEP 1: You type in your browser
        https://argocd.yourcompany.internal

        Inside the URL, your browser:
        - Resolves DNS: argocd.yourcompany.internal → 10.160.0.18
        - Opens HTTPS connection to 10.160.0.18 on port 443
        - Sends TLS handshake: "Let's encrypt this connection"

        ┌──────────────────────────────────────────┐
        │ FORWARDING RULE                          │
        │ IP: 10.160.0.18 | Port: 443              │
        │ "I received traffic on this IP+port"     │
        └────────┬─────────────────────────────────┘
                 │
                 ▼

STEP 2: Google Target HTTPS Proxy
        - Receives TLS handshake
        - Presents certificate: "argocd-selfsigned-cert"
        - Decrypts traffic (HTTPS → HTTP)
        - Reads HTTP headers including "Host: argocd.yourcompany.internal"

        ┌──────────────────────────────────────────┐
        │ TARGET HTTPS PROXY                       │
        │ Certificate: argocd-selfsigned-cert      │
        │ "Yes, I am argocd.yourcompany.internal"  │
        │ TLS: DECRYPTED HERE                      │
        └────────┬─────────────────────────────────┘
                 │ Now it's plain HTTP inside
                 ▼

STEP 3: Google URL Map
        - Looks at "Host: argocd.yourcompany.internal"
        - Checks URL Map rules: "argocd.yourcompany.internal → argocd-backend"
        - Sends traffic to Backend Service associated with ArgoCD

        ┌──────────────────────────────────────────┐
        │ URL MAP                                  │
        │ "argocd.yourcompany.internal"            │
        │   → Backend Service: argocd-server       │
        └────────┬─────────────────────────────────┘
                 │
                 ▼

STEP 4: Backend Service + Health Checks
        - Checks health status: "Is ArgoCD healthy?"
        - BackendConfig says: check /healthz on port 8080 every 10s
        - Hears back: "Yes, HEALTHY"

        ┌──────────────────────────────────────────┐
        │ BACKEND SERVICE                          │
        │ Health Check: /healthz : 8080 = HEALTHY  │
        │ "ArgoCD is alive. Send traffic."         │
        └────────┬─────────────────────────────────┘
                 │
                 ▼

STEP 5: Network Endpoint Group (NEG)
        - Looks up current pod IPs
        - "Send traffic to ArgoCD pod at 10.82.1.5:8080"

        ┌──────────────────────────────────────────┐
        │ NETWORK ENDPOINT GROUP                   │
        │ Pod 1: 10.82.1.5:8080                    │
        └────────┬─────────────────────────────────┘
                 │ Direct routing (no VM hop)
                 ▼

STEP 6: ArgoCD Pod
        - Receives HTTP request on port 8080
        - ArgoCD is running with --insecure (accepts HTTP)
        - Redirects to login page: /login
        - Sends response: 307 Temporary Redirect

        ┌──────────────────────────────────────────┐
        │ ARGOCD SERVER POD                        │
        │ Port: 8080 | Flag: --insecure            │
        │ Response: 307 → https://.../login        │
        └──────────────────────────────────────────┘

STEP 7: Back to Browser
        - Browser follows redirect to /login
        - Sees ArgoCD login page
        - User clicks "LOG IN VIA GOOGLE"
        - Dex handles Google OAuth
        - Authentication complete → user sees dashboard
```

**Key insight:** TLS is terminated at the Google Load Balancer (Step 2). Everything after that is HTTP inside the private network. This is safe because:
1. The network is already private
2. Traffic never leaves Google's internal network

---

# 6. What Happens During Helm Install?

When you run:
```bash
helm install argocd argo/argo-cd -n argocd -f argocd-values.yaml
```

Helm does this:

| Step | What Helm Creates | What It Does |
|------|-------------------|--------------|
| 1 | Namespace `argocd` | A bucket/room for all ArgoCD things |
| 2 | Deployment `argocd-server` | Runs ArgoCD web UI (your app) |
| 3 | Deployment `argocd-dex-server` | Handles Google login |
| 4 | Service `argocd-server` | Makes ArgoCD reachable by name inside cluster |
| 5 | Ingress `argocd-server` | Tells Google: "route external traffic here" |
| 6 | ConfigMap `argocd-cm` | Settings like URL, admin enabled, Dex config |
| 7 | Secret | Admin password, TLS certs |
| 8 | + more controllers | Repo server, app controller, etc. |

**The Ingress is the key.** It triggers Google to build the entire load balancer chain.

### What Happens After Helm Install?

```
Helm done → Ingress exists
     ↓
Google Ingress Controller sees new Ingress
     ↓
Checks: Is there a proxy subnet? → YES
     ↓
Checks: Is there a BackendConfig? → YES
     ↓
Checks: Is there a static IP? → YES
     ↓
Checks: Is there a regional SSL cert? → YES
     ↓
Checks: Does Service have NEG annotation? → YES
     ↓
Builds: ForwardingRule → TargetProxy → URL Map → Backend Service → NEG
     ↓
Checks health: /healthz → ok → HEALTHY
     ↓
Ingress ADDRESS column shows: 10.160.0.18 ← READY!
```

**This takes 2-5 minutes.** If any check fails, the entire chain stops.

---

# 7. Verification Commands

Here is every command you can run to prove each component is working.

## Verify Cluster

```bash
# Is cluster alive?
gcloud container clusters describe argocd-cluster --zone=asia-south1-a --format='table(name,status)'
```

## Verify Proxy Subnet

```bash
gcloud compute networks subnets list --filter="purpose=REGIONAL_MANAGED_PROXY"
```

## Verify Firewall Rules

```bash
gcloud compute firewall-rules list --filter="name~allow-proxy OR name~allow-gcp"
```

## Verify Static IP

```bash
gcloud compute addresses describe argocd-internal-ip --region=asia-south1 --format='table(name,address,status)'
```

## Verify SSL Certificate

```bash
gcloud compute ssl-certificates describe argocd-selfsigned-cert --region=asia-south1 --format='table(name,type)'
```

## Verify Kubernetes Resources

```bash
# All ArgoCD pods running?
kubectl get pods -n argocd

# Ingress has IP?
kubectl get ingress argocd-server -n argocd

# Ingress events (look for errors)
kubectl get events -n argocd --field-selector involvedObject.kind=Ingress

# Backend health
kubectl get ingress argocd-server -n argocd -o jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/backends}'
```

## Verify Health Check

```bash
# From inside a pod
kubectl exec deployment/argocd-server -n argocd -- wget -qO- http://localhost:8080/healthz
```

## Full Connectivity Test

```bash
kubectl run test-pod --image=curlimages/curl -n argocd --rm -i --restart=Never -- \
  curl -k -s -o /dev/null -w 'HTTP CODE: %{http_code}
' \
  -H 'Host: argocd.yourcompany.internal' \
  'https://10.160.0.18'
```

---

# 8. Common Errors We Already Hit (and Why)

## Error 1: `gke-gcloud-auth-plugin not found`

**What it means:** Your kubectl can't talk to Google Cloud.

**Fix:**
```bash
sudo apt-get install google-cloud-sdk-gke-gcloud-auth-plugin
```

---

## Error 2: `cannot enable HTTPS Redirects with L7 ILB`

**What it means:** You had `redirectToHttps: true` in FrontendConfig.

**Why:** GCE Internal LB does NOT support FrontendConfig.

**Fix:** Delete the `redirectToHttps` block. Use `allow-http: "false"` on Ingress instead.

---

## Error 3: `Error: no FrontendConfig for Ingress exists`

**What it means:** You deleted FrontendConfig, and the Ingress still referenced it.

**Fix:** Recreate FrontendConfig with empty `spec: {}`.

---

## Error 4: `ingress.kubernetes.io/backends` shows `UNHEALTHY`

**What it means:** ArgoCD pod is not responding to `/healthz`.

**Why:**
- Pod is still starting up (wait 1 minute)
- Firewall rule for health checks is missing
- BackendConfig port is wrong

**Fix:**
```bash
# Check if pod is running
kubectl get pods -n argocd

# Check if /healthz works
kubectl exec deployment/argocd-server -n argocd -- wget -qO- http://localhost:8080/healthz

# Check firewall rules
gcloud compute firewall-rules list --filter="name~allow-gcp"
```

---

## Error 5: HTTP 404 When Testing

**What it means:** Load balancer received the request, but the hostname didn't match.

**Why:** You curled `https://10.160.0.18` instead of `https://argocd.yourcompany.internal`. The Ingress only matches the hostname.

**Fix:** Use `-H "Host: argocd.yourcompany.internal"` in curl.

---

# 9. Cost Summary

| Item | Monthly Cost | Notes |
|------|-------------|-------|
| GKE management fee | $73 | Required |
| 2 × e2-medium nodes | $49 | ArgoCD runs here |
| Internal LB forwarding rule | $18 | One rule for HTTPS |
| Proxy subnet | $0 | Free reservation |
| Static IP (when attached) | $0 | Free while in use |
| SSL certificate | $0 | Self-managed |
| **Total** | **~$144** | For demo |

---

# 10. Manager Talking Points

## 30-Second Pitch

> "We deployed ArgoCD on a 2-node Google Kubernetes cluster in Mumbai. The entire setup is internal-only — no public IP. Employees need VPN access to reach it. Authentication is through company Google accounts. We use Google's managed load balancer for zero maintenance overhead."

## Show the Architecture

```bash
echo "Internal IP: $ARGOCD_INTERNAL_IP"
```

> "This IP — $ARGOCD_INTERNAL_IP — lives inside our VPC. It does not exist on the internet. Someone outside the company cannot reach it even if they know the IP."

## Show the Access Flow

```bash
kubectl get ingress argocd-server -n argocd
```

> "Google manages the load balancer for us. It terminates TLS using our certificate. It health-checks ArgoCD every 10 seconds. Traffic goes directly to the ArgoCD pod. No extra server needed."

## Show the Security

> "Zero internet exposure. No public IP. No WAF needed. No DDoS protection needed. The load balancer does not have an internet face. You can't hack what you can't reach."

## Show the Cost

> "Total is about $144 a month, same as a small EC2 instance. We removed the NGINX pod, so we actually save compute resources."

---

## End of Guide

Questions? Every component above has a **"Command to Verify"** section. Run those commands and confirm each component exists. If any is missing, that is where something broke.
