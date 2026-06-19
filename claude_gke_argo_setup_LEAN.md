# ArgoCD on GKE — Lean & Secure Setup Guide
### For ~2-week delivery: 1 Region, Default ArgoCD, Ingress, SSO, RBAC

**Author:** DevOps Specialist  
**Cloud:** Google Cloud Platform (GCP)  
**Region:** `asia-south1` (Mumbai) — closest India region with full GKE service availability. Re-derive pricing if running elsewhere.  
**Audience:** Client Engineering Team (2-week sprint timeline)  
**Date:** June 2026  
**Status:** Ready to execute. No external inventory dependencies.

> **Scope note:** This is the **lean** edition. High Availability overhead (multi-zone anti-affinity, Redis Sentinel, PDBs, dedicated node pools) is removed to save setup time and cost. **Security is NOT reduced:** TLS, WAF, Workload Identity, SSO, and RBAC remain fully production-grade.

---

## Shared Variables

```bash
export PROJECT_ID="your-gcp-project-id"
export GCP_REGION="asia-south1"
export CLUSTER_NAME="argocd-cluster"
export DOMAIN="argocd.yourcompany.com"
export COMPANY_DOMAIN="yourcompany.com"

gcloud config set project $PROJECT_ID
gcloud config set compute/region $GCP_REGION
```

---

# PHASE 1 — GKE Cluster (Minimal Regional)

## 1.1 CLI & Auth

```bash
gcloud version
kubectl version --client
helm version

gcloud auth login
gcloud auth application-default login

# Enable APIs (once per project)
gcloud services enable \
  container.googleapis.com \
  secretmanager.googleapis.com \
  certificatemanager.googleapis.com \
  dns.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com
```

## 1.2 Create VPC & Subnet

```bash
gcloud compute networks create argocd-vpc \
  --subnet-mode=custom \
  --bgp-routing-mode=regional

gcloud compute networks subnets create argocd-subnet \
  --network=argocd-vpc \
  --region=$GCP_REGION \
  --range=10.0.0.0/20 \
  --secondary-range=pods=10.100.0.0/16,services=10.200.0.0/20 \
  --enable-private-ip-google-access
```

## 1.3 Create GKE Cluster — Simplified

> **Why regional?** Google manages the control plane across 3 zones for free. You get zone-outage resilience without any extra work. Nodes run 1 per zone (3 total) with autoscaling to 4. For a 2-week project this is the sweet spot: fast to set up, no HA bells and whistles, but not fragile.
>
> **Why Mumbai (`asia-south1`)?** This is the closest GCP region to India with full GKE + Cloud Armor + Cloud DNS availability. It offers low latency for Indian users and keeps data within the country — a common compliance requirement. Compute in Mumbai is **~5.4% more expensive** than US regions; the cost table below reflects this.

```bash
gcloud container clusters create $CLUSTER_NAME \
  --region=$GCP_REGION \
  --release-channel=regular \
  --network=argocd-vpc \
  --subnetwork=argocd-subnet \
  --cluster-secondary-range-name=pods \
  --services-secondary-range-name=services \
  \
  --machine-type=e2-standard-2 \
  --num-nodes=1 \
  --min-nodes=1 \
  --max-nodes=4 \
  --enable-autoscaling \
  --disk-type=pd-balanced \
  --disk-size=50 \
  \
  --enable-workload-identity \
  --enable-shielded-nodes \
  --shielded-secure-boot \
  --shielded-integrity-monitoring \
  \
  --enable-ip-alias \
  --addons=HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver \
  \
  --labels=env=production,team=platform,app=argocd

echo "✅ Cluster ready: $CLUSTER_NAME"
```

> **What's intentionally left out:** private nodes, network policies, master-authorized-networks. These are hardening items for a later phase. They add 20+ minutes to provisioning and aren't blockers for getting ArgoCD running.

## 1.4 Connect kubectl

```bash
gcloud container clusters get-credentials $CLUSTER_NAME --region=$GCP_REGION
kubectl get nodes
# Expected: 3 nodes, Ready
```

---

## 💰 Phase 1 Cost

| Line item | Detail | Monthly (USD) | ~Monthly (₹) |
|---|---|---|---|
| GKE regional mgmt fee | $0.10/hr × 730 | **$73.00** | **~₹6,088** |
| 3× `e2-standard-2` (Mumbai) | $0.07065/hr × 730 × 3 | **$154.72** | **~₹12,904** |
| Boot disks 3× 50 GB `pd-balanced` | $0.10/GiB × 50 × 3 | **$15.00** | **~₹1,251** |
| **Total Phase 1** | | **$242.72** | **~₹20,243** |

**2-week project actual (prorated, on-demand):** ~**$112** (~₹9,341) if torn down after 2 weeks.  
**With 1-Year CUD:** ~$187/mo (~₹15,596) if the cluster stays up.

---

# PHASE 2 — ArgoCD (Default Setup, Minimal Replicas)

## 2.1 Namespace

```bash
kubectl create namespace argocd
kubectl label namespace argocd \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.28
```

## 2.2 Workload Identity

```bash
gcloud iam service-accounts create argocd-prod-sa \
  --display-name="ArgoCD Service Account"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:argocd-prod-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

kubectl create serviceaccount argocd-ksa --namespace argocd

gcloud iam service-accounts add-iam-policy-binding \
  argocd-prod-sa@${PROJECT_ID}.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[argocd/argocd-ksa]"

kubectl annotate serviceaccount argocd-ksa \
  --namespace argocd \
  iam.gke.io/gcp-service-account=argocd-prod-sa@${PROJECT_ID}.iam.gserviceaccount.com
```

## 2.3 Install ArgoCD — Simplified Values

> **Key simplifications vs. the HA doc:**
> - `redis.enabled: true` (default single-pod Redis — rebuildable cache, fine for this scope)
> - No anti-affinity rules (faster scheduling, fewer failures on small clusters)
> - No PodDisruptionBudgets (not needed for 2-week timeline)
> - 1 controller replica (scale to 2 later if app count grows past ~30)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

cat > argocd-values.yaml << 'EOF'
global:
  domain: argocd.yourcompany.com

controller:
  replicas: 1
  resources:
    requests: {cpu: 500m, memory: 512Mi}
    limits:    {cpu: 2000m, memory: 2Gi}
  containerSecurityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    runAsUser: 999
    capabilities: {drop: [ALL]}
    seccompProfile: {type: RuntimeDefault}
  metrics:
    enabled: true
    serviceMonitor: {enabled: false}

server:
  replicas: 2
  resources:
    requests: {cpu: 250m, memory: 256Mi}
    limits:    {cpu: 1000m, memory: 1Gi}
  containerSecurityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    runAsUser: 999
    capabilities: {drop: [ALL]}
    seccompProfile: {type: RuntimeDefault}
  extraArgs:
    - --insecure
  metrics:
    enabled: true
    serviceMonitor: {enabled: false}

repoServer:
  replicas: 2
  resources:
    requests: {cpu: 250m, memory: 256Mi}
    limits:    {cpu: 1000m, memory: 1Gi}
  containerSecurityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    runAsUser: 999
    capabilities: {drop: [ALL]}
    seccompProfile: {type: RuntimeDefault}
  metrics:
    enabled: true
    serviceMonitor: {enabled: false}

dex:
  enabled: true
  resources:
    requests: {cpu: 50m, memory: 64Mi}
    limits:    {cpu: 200m, memory: 256Mi}
  containerSecurityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    runAsUser: 999
    capabilities: {drop: [ALL]}
  volumes:
    - name: google-admin-sa
      secret:
        secretName: dex-google-admin-sa
  volumeMounts:
    - name: google-admin-sa
      mountPath: /etc/dex
      readOnly: true

applicationSet:
  enabled: true
  replicas: 1
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits:    {cpu: 500m, memory: 512Mi}

notifications:
  enabled: true
  resources:
    requests: {cpu: 50m, memory: 64Mi}
    limits:    {cpu: 200m, memory: 128Mi}

configs:
  cm:
    admin.enabled: "true"
    timeout.reconciliation: 180s
    application.resourceTrackingMethod: label
  params:
    server.insecure: true
  secret:
    createSecret: true
EOF

helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.8.10 \
  --values argocd-values.yaml \
  --wait --timeout 10m
```

> **`--insecure` is NOT a security problem.** TLS terminates at the GCE load balancer (Phase 3). Traffic between the LB and ArgoCD pods travels over Google's internal VPC, which is encrypted in transit. This is the standard production pattern for GKE Ingress.

## 2.4 Verify

```bash
kubectl get pods -n argocd
# Expected (simplified):
#   argocd-application-controller-0
#   argocd-server-* (x2)
#   argocd-repo-server-* (x2)
#   argocd-dex-server-*
#   argocd-redis-* (single pod, built-in)
```

---

## 💰 Phase 2 Cost

| Line item | Detail | Monthly |
|---|---|---|
| ArgoCD workload | ~1.45 vCPU / ~1.4 GB requests; fits inside existing nodes | **$0.00** |
| Built-in Redis | Uses ephemeral storage; included in node cost | **$0.00** |
| Cross-zone traffic | Negligible for this footprint | **~$0.05** |
| **Total Phase 2** | | **~$0.05** |

---

# PHASE 3 — Internet Exposure (GCE Ingress + Cloud Armor)

## 3.1 Reserve Static IP

```bash
gcloud compute addresses create argocd-global-ip --global --ip-version=IPV4

export ARGOCD_IP=$(gcloud compute addresses describe argocd-global-ip \
  --global --format="value(address)")
echo "✅ IP: $ARGOCD_IP"
```

## 3.2 Cloud Armor (Basic WAF)

```bash
gcloud compute security-policies create argocd-waf \
  --description="WAF for ArgoCD"

gcloud compute security-policies rules create 1000 \
  --security-policy=argocd-waf \
  --expression="evaluatePreconfiguredWaf('sqli-v33-stable')" \
  --action=deny-403 --description="SQLi"

gcloud compute security-policies rules create 1001 \
  --security-policy=argocd-waf \
  --expression="evaluatePreconfiguredWaf('xss-v33-stable')" \
  --action=deny-403 --description="XSS"
```

## 3.3 Backend & Frontend Configs

```bash
cat > argocd-backend-config.yaml << 'EOF'
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: argocd-backend
  namespace: argocd
spec:
  healthCheck:
    checkIntervalSec: 15
    timeoutSec: 10
    healthyThreshold: 1
    unhealthyThreshold: 3
    type: HTTP
    requestPath: /healthz
    port: 8080
  sessionAffinity:
    affinityType: "GENERATED_COOKIE"
    affinityCookieTtlSec: 50
  securityPolicy:
    name: argocd-waf
  connectionDraining:
    drainingTimeoutSec: 60
EOF

cat > argocd-frontend-config.yaml << 'EOF'
apiVersion: networking.gke.io/v1beta1
kind: FrontendConfig
metadata:
  name: argocd-frontend
  namespace: argocd
spec:
  redirectToHttps:
    enabled: true
EOF

kubectl apply -f argocd-backend-config.yaml
kubectl apply -f argocd-frontend-config.yaml
```

## 3.4 Google-Managed SSL Certificate

```bash
cat > argocd-cert.yaml << 'EOF'
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: argocd-cert
  namespace: argocd
spec:
  domains:
    - argocd.yourcompany.com
EOF
kubectl apply -f argocd-cert.yaml
```

## 3.5 Ingress (Modern API)

```bash
cat > argocd-ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    networking.gke.io/managed-certificates: argocd-cert
    networking.gke.io/v1beta1.FrontendConfig: argocd-frontend
    cloud.google.com/backend-config: '{"default": "argocd-backend"}'
    kubernetes.io/ingress.global-static-ip-name: argocd-global-ip
    kubernetes.io/ingress.allow-http: "false"
spec:
  ingressClassName: gce
  rules:
    - host: argocd.yourcompany.com
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

## 3.6 DNS Record

```bash
gcloud dns record-sets create argocd.yourcompany.com \
  --zone=your-managed-zone-name \
  --type=A --ttl=300 \
  --rrdatas=$ARGOCD_IP
```

> **Certificate provisioning requires DNS to resolve first.** Wait 5–10 min after creating the DNS record before the ManagedCertificate will provision.

---

## 💰 Phase 3 Cost

| Line item | Detail | Monthly (USD) | ~Monthly (₹) |
|---|---|---|---|
| Static IP (attached) | Free when attached | **$0.00** | **₹0** |
| Forwarding rule | $0.025/hr × 730 | **$18.25** | **~₹1,522** |
| Managed SSL cert | Always free | **$0.00** | **₹0** |
| Cloud Armor policy | $5 base | **$5.00** | **~₹417** |
| Cloud Armor rules | 2 preconfigured WAF rules × $3 | **$6.00** | **~₹500** |
| Cloud DNS zone | $0.20/mo | **$0.20** | **~₹17** |
| Variable (LB processing + egress) | ~$1–2/mo for 15–20 users | **$1.50** | **~₹125** |
| **Total Phase 3** | | **~$30.95** | **~₹2,581** |

---

# PHASE 4 — SSO via Google Workspace (Dex)

## 4.1 OAuth Consent Screen

In Google Cloud Console:
1. **APIs & Services → OAuth consent screen**
2. **Internal** (if using a Workspace domain)
3. Scopes:
   - `openid`
   - `userinfo.profile`
   - `userinfo.email`
   - `admin.directory.group.readonly` (for group fetching)
4. Authorized domain: `yourcompany.com`

## 4.2 OAuth Client ID

1. **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**
2. Type: **Web application**
3. Name: `ArgoCD SSO`
4. Authorized redirect URI: `https://argocd.yourcompany.com/api/dex/callback`
5. Save **Client ID** and **Client Secret**

## 4.3 Store Secrets in Secret Manager

```bash
# OAuth client secret
echo -n "YOUR_CLIENT_SECRET" | gcloud secrets create argocd-oauth-secret \
  --data-file=- --replication-policy=automatic

# Google Workspace admin SA key (for group fetching)
# 1. Create SA: argocd-dex-admin-api-sa
# 2. Download JSON key → dex-admin-key.json
# 3. Upload:
gcloud secrets create dex-admin-key \
  --data-file=dex-admin-key.json --replication-policy=automatic

# 4. In Google Admin Console:
#    Security → API Controls → Domain-wide delegation
#    Add: Client ID = SA's numeric ID
#    Scope: https://www.googleapis.com/auth/admin.directory.group.readonly
```

## 4.4 External Secrets Operator + WI

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set installCRDs=true --wait

# Annotate ESO's SA for Workload Identity
kubectl annotate serviceaccount external-secrets \
  --namespace external-secrets \
  iam.gke.io/gcp-service-account=argocd-prod-sa@${PROJECT_ID}.iam.gserviceaccount.com

gcloud iam service-accounts add-iam-policy-binding \
  argocd-prod-sa@${PROJECT_ID}.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[external-secrets/external-secrets]"
```

## 4.5 Pull Secrets into Kubernetes

```bash
cat > secret-store.yaml << 'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: gcp-sm
spec:
  provider:
    gcpsm:
      projectID: YOUR_PROJECT_ID
      auth:
        workloadIdentity:
          clusterLocation: asia-south1
          clusterName: argocd-cluster
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
EOF
kubectl apply -f secret-store.yaml

cat > oauth-es.yaml << 'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: argocd-oauth
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef: {name: gcp-sm, kind: ClusterSecretStore}
  target: {name: argocd-dex-google-oauth, creationPolicy: Owner}
  data:
    - secretKey: client-secret
      remoteRef: {key: argocd-oauth-secret}
EOF
kubectl apply -f oauth-es.yaml

cat > dex-admin-es.yaml << 'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: dex-admin-sa
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef: {name: gcp-sm, kind: ClusterSecretStore}
  target: {name: dex-google-admin-sa, creationPolicy: Owner}
  data:
    - secretKey: google-admin-sa.json
      remoteRef: {key: dex-admin-key}
EOF
kubectl apply -f dex-admin-es.yaml
```

## 4.6 Configure Dex

```bash
kubectl patch configmap argocd-cm -n argocd --type merge -p "$(cat <<EOF
{
  \"data\": {
    \"url\": \"https://argocd.yourcompany.com\",
    \"dex.config\": \"connectors:\\n  - type: google\\n    id: google\\n    name: Google Workspace\\n    config:\\n      clientID: YOUR_GOOGLE_CLIENT_ID\\n      clientSecret: \\\$argocd-dex-google-oauth:client-secret\\n      redirectURI: https://argocd.yourcompany.com/api/dex/callback\\n      hostedDomains:\\n        - yourcompany.com\\n      scopes:\\n        - openid\\n        - profile\\n        - email\\n      fetchGroups: true\\n      adminEmail: admin@yourcompany.com\\n      serviceAccountFilePath: /etc/dex/google-admin-sa.json\\n      groups:\\n        - argocd-admins@yourcompany.com\\n        - devops-team@yourcompany.com\\n        - developers@yourcompany.com\\n        - auditors@yourcompany.com\"
  }
}
EOF
)"

kubectl rollout restart deployment argocd-dex-server -n argocd
```

## 4.7 Verify & Lock Down

```bash
# Check Dex registration
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-dex-server --tail=50

# Test login: https://argocd.yourcompany.com → "Login with Google"
# Only after SUCCESSFUL login:

kubectl patch configmap argocd-cm -n argocd \
  --type merge -p '{"data":{"admin.enabled":"false"}}'
kubectl rollout restart deployment argocd-server -n argocd
```

---

## 💰 Phase 4 Cost

| Line item | Detail | Monthly (USD) | ~Monthly (₹) |
|---|---|---|---|
| Secret Manager | 2 secrets, under free tier | **$0.00** | **₹0** |
| ESO controller | Fits in existing node headroom | **$0.00** | **₹0** |
| Workspace/Cloud Identity | $0 (assumes existing licensing) | **$0.00** | **₹0** |
| **Total Phase 4** | | **$0.00** | **₹0** |

---

# PHASE 5 — RBAC & Multi-Tenancy

## 5.1 Global RBAC

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
    g, argocd-admins@yourcompany.com, role:admin

    p, role:devops, applications, *, */,*, allow
    p, role:devops, clusters, get, *, allow
    p, role:devops, repositories, *, *, allow
    g, devops-team@yourcompany.com, role:devops

    p, role:developer, applications, get, */,*, allow
    p, role:developer, applications, sync, payments/*, allow
    p, role:developer, applications, override, payments/*, deny
    p, role:developer, applications, delete, payments/*, deny
    g, developers@yourcompany.com, role:developer

    g, auditors@yourcompany.com, role:readonly

  scopes: "[groups, email]"
EOF
kubectl apply -f argocd-rbac.yaml
kubectl rollout restart deployment argocd-server -n argocd
```

## 5.2 AppProject (Team Isolation Example)

```bash
cat > payments-project.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: payments-team
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: "Payments Team Scope"
  sourceRepos:
    - "https://github.com/your-org/payments-*"
    - "https://github.com/your-org/gitops-payments.git"
  destinations:
    - {namespace: "payments-*", server: https://kubernetes.default.svc}
    - {namespace: "payments-staging", server: https://kubernetes.default.svc}
  clusterResourceWhitelist:
    - {group: "", kind: Namespace}
  namespaceResourceWhitelist:
    - {group: apps, kind: Deployment}
    - {group: apps, kind: StatefulSet}
    - {group: "", kind: Service}
    - {group: "", kind: ConfigMap}
    - {group: networking.k8s.io, kind: Ingress}
  roles:
    - name: team-lead
      policies:
        - "p, proj:payments-team:team-lead, applications, *, payments-team/*, allow"
      groups: [payments-leads@yourcompany.com]
    - name: developer
      policies:
        - "p, proj:payments-team:developer, applications, get, payments-team/*, allow"
        - "p, proj:payments-team:developer, applications, sync, payments-team/*, allow"
      groups: [payments-developers@yourcompany.com]
EOF
kubectl apply -f payments-project.yaml
```

## 5.3 Accessing ArgoCD via Website

Once all 5 phases are complete, open your browser and navigate to:

```
https://argocd.yourcompany.com
```

### What You Should See

1. **ArgoCD login page** with a **"Login with Google"** button.
2. Clicking it redirects you to Google Workspace SSO.
3. After successful authentication, you land on the ArgoCD dashboard.

### Quick Browser Verification

```bash
# 1. Verify DNS resolves
curl -s -o /dev/null -w "%{http_code}" https://argocd.yourcompany.com
# Expected: 200 (after SSO, it may redirect to /login first)

# 2. Check certificate is valid
echo | openssl s_client -servername argocd.yourcompany.com \
  -connect argocd.yourcompany.com:443 2>/dev/null | openssl x509 -noout -dates
# Expected: notBefore / notAfter dates showing a valid Google-managed cert

# 3. Verify HTTP redirects to HTTPS
curl -I -L http://argocd.yourcompany.com 2>/dev/null | head -5
# Expected: 301 Moved Permanently → redirect to https://
```

### RBAC Smoke Test by User Type

| User Group | Action | Expected Result |
|---|---|---|
| `argocd-admins@yourcompany.com` | Log in → Settings → Accounts | Can see all settings |
| `devops-team@yourcompany.com` | Log in → New App | Can create applications in any project |
| `developers@yourcompany.com` | Log in → Apps | Can view all apps but only sync apps in `payments/*` |
| `auditors@yourcompany.com` | Log in → Apps | Read-only view of everything |
| **Non-Workspace user** (e.g. `hacker@gmail.com`) | Click "Login with Google" | Denied by `hostedDomains` restriction |

### If You See an Error Page

| Error | Meaning | Fix |
|---|---|---|
| `Unauthorized` | Dex trust issue | `kubectl logs -n argocd deploy/argocd-dex-server --tail=50` |
| `502 Bad Gateway` | LB can't reach backend | `kubectl get pods -n argocd` — ensure all pods are `Running` |
| `Your connection is not private` | Certificate not provisioned | Check DNS resolves and `kubectl get managedcertificate -n argocd` |
| `Invalid client` (Google error) | OAuth `clientID` or `redirectURI` mismatch | Verify redirect URI in Google Console matches exactly |


---

## 💰 Phase 5 Cost

**$0.00.** RBAC and AppProjects are Kubernetes resources stored in etcd — already covered by the GKE management fee.

---

# Total Cost Summary

> **India billing note:** GCP invoices Indian billing accounts in **INR (₹)** at the prevailing exchange rate. The **₹ estimates** below use **₹83.4/USD** — update the multiplier before quoting a final number.

## Running Total (Typical Usage Tier)

| Phase | Monthly (USD) | ~Monthly (₹) |
|---|---|---|
| 1 — GKE Cluster | $242.72 | ~₹20,243 |
| 2 — ArgoCD Core | ~$0.05 | ~₹4 |
| 3 — Ingress + WAF + DNS | ~$30.95 | ~₹2,581 |
| 4 — SSO (Dex + ESO) | $0.00 | ₹0 |
| 5 — RBAC | $0.00 | ₹0 |
| **Total** | **~$273.72/mo** | **~₹22,828** |

**2-week sprint prorated cost (Mumbai, on-demand):** ~**$127** (~₹10,592)

## Quick Cost Levers

| Lever | USD saved | ~₹ saved | When to Apply |
|---|---|---|---|
| **1-Year CUD on compute** | ~$55/mo | ~₹4,587/mo | After 1 month of stable node count |
| **Zonal cluster (not regional)** | $73/mo | ~₹6,088/mo | Dev/test only |
| **e2-medium nodes** | ~$73/mo | ~₹6,088/mo | Monitor CPU; only if headroom exists |

---

# What Was Intentionally Left Out (and Why)

| Item | Why It's Out |
|---|---|
| Redis HA (Sentinel) | Default built-in Redis is fine for a rebuildable cache on a 2-week timeline |
| Pod anti-affinity | Adds scheduling failures on small clusters; unnecessary for this scope |
| PodDisruptionBudgets | Not needed if the cluster isn't running mission-critical 24×7 workloads with maintenance windows |
| Private nodes / master-authorized-networks | Adds 20+ min to provisioning; flag as Phase-2 if security audit requires it |
| Prometheus / Grafana monitoring | Out of scope for a 2-week sprint; GKE Cloud Monitoring covers basics |
| Velero backups | Out of scope; source of truth is Git, not the cluster state |
| HPA / VPA | Node pool autoscaling handles horizontal scaling; manual right-sizing is fine for now |
| Multi-cluster fleet mgmt | Not applicable yet |

---

# Quick Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| 502 from LB | Health check on wrong port | BackendConfig must point to `port: 8080` (ArgoCD server port) |
| Cert stuck pending | DNS not resolving | `nslookup argocd.yourcompany.com` must show your static IP before the cert provisions |
| Login failed | Dex OAuth misconfigured | Check `clientID`, `redirectURI`, and OAuth consent screen scopes |
| Lockout after disabling admin | SSO broken | `kubectl patch cm argocd-cm -n argocd -p '{"data":{"admin.enabled":"true"}}'` |
| Group RBAC not working | Domain-wide delegation missing | Verify in Google Admin Console |
| ESO can't sync secrets | Workload Identity not bound | Check `external-secrets` SA annotation and IAM binding |

---

# Go-Live Checklist

- [ ] All `YOUR_...` placeholders replaced with real values
- [ ] OAuth consent screen is **Internal** and scopes are added
- [ ] Redirect URI in OAuth client matches exactly: `https://argocd.yourcompany.com/api/dex/callback`
- [ ] Domain-wide delegation enabled in Google Admin Console
- [ ] DNS A record resolves to `$ARGOCD_IP`
- [ ] At least one successful Google SSO login completed
- [ ] `admin.enabled: "false"` applied **after** SSO verified
- [ ] No secrets in Git; all sensitive values in Secret Manager

---

*End of Document — Lean & Secure ArgoCD on GKE*  
*Scope: 2-week sprint | HA deferred | Security included*
