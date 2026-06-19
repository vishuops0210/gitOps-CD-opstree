# Three-Cluster ArgoCD Demo Guide

> **Goal**: Deploy ArgoCD on a control EKS cluster, deploy 12 apps across 3 separate EKS clusters (dev / uat / prod), and show your manager 3 tiles in the ArgoCD dashboard.
> **Architecture**: App-of-Apps pattern — 3 parent Applications each managing 12 child Applications.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Create 3 EKS Clusters](#3-create-3-eks-clusters)
4. [Add Clusters to ArgoCD](#4-add-clusters-to-argocd)
5. [Update Manifests with Real Endpoints](#5-update-manifests-with-real-endpoints)
6. [Apply ArgoCD Manifests](#6-apply-argocd-manifests)
7. [Verify Deployments](#7-verify-deployments)
8. [Manager Demo Script](#8-manager-demo-script)
9. [Troubleshooting](#9-troubleshooting)
10. [Cost & Cleanup](#10-cost--cleanup)

---

## 1. Architecture Overview

```
                          Control Cluster (argocd-gke)
                 ┌──────────────────────────────────────────┐
                 │  Namespace: argocd                       │
                 │  ┌──────────────────────────────────┐    │
                 │  │ ArgoCD UI shows 3 tiles:         │    │
                 │  │   dev-environment                │    │
                 │  │   uat-environment                │    │
                 │  │   prod-environment               │    │
                 │  └──────────────────────────────────┘    │
                 │         │           │           │         │
                 └─────────┼───────────┼───────────┼─────────┘
                           │           │           │
            ┌──────────────┤           │           ├──────────────┐
            │  argocd-agent│           │           │ argocd-agent │
            │  (443 HTTPS) │           │           │ (443 HTTPS)  │
            ▼              ▼           ▼           ▼              ▼
   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │ Dev Cluster  │  │ UAT Cluster  │  │ Prod Cluster │
   │ (dev-eks)    │  │ (uat-eks)    │  │ (prod-eks)   │
   │              │  │              │  │              │
   │ java-app1    │  │ java-app1    │  │ java-app1    │
   │ java-app2    │  │ java-app2    │  │ java-app2    │
   │ ...          │  │ ...          │  │ ...          │
   │ frontend3    │  │ frontend3    │  │ frontend3    │
   │              │  │              │  │              │
   │ 12 ns total  │  │ 12 ns total  │  │ 12 ns total  │
   └──────────────┘  └──────────────┘  └──────────────┘
```

### What Changed from the Old Setup?

| Before (1 Cluster) | After (3 Clusters) |
|--------------------|-------------------|
| 36 flat tiles | 3 parent tiles (expand to 36) |
| 1 AppProject `platform-apps` | 3 AppProjects `dev`, `uat`, `prod` |
| Namespaces: `app1-dev`, `app1-uat` | Namespaces: `java-app1` on every cluster |
| `destination: https://kubernetes.default.svc` | `destination: https://dev-eks-endpoint.eks.amazonaws.com` |

### File Layout

```
argocd/
├── projects/
│   ├── dev.yaml           # AppProject: dev cluster only
│   ├── uat.yaml           # AppProject: uat cluster only
│   └── prod.yaml          # AppProject: prod cluster only
├── parents/
│   ├── dev-environment.yaml    # Parent App (creates 12 children)
│   ├── uat-environment.yaml    # Parent App (creates 12 children)
│   └── prod-environment.yaml   # Parent App (creates 12 children)
└── apps/
    ├── dev/
    │   ├── java-app1.yaml     # Child App → dev cluster
    │   ├── java-app2.yaml
    │   └── ... (12 files)
    ├── uat/
    │   ├── java-app1.yaml     # Child App → uat cluster
    │   └── ... (12 files)
    └── prod/
        ├── java-app1.yaml     # Child App → prod cluster
        └── ... (12 files)
```

---

## 2. Prerequisites

### Tools
| Tool | Verify |
|------|--------|
| AWS CLI | `aws sts get-caller-identity` |
| kubectl | `kubectl version --client` |
| eksctl | `eksctl version` |
| argocd CLI | `argocd version --client` |
| Docker + registry | `docker login` |

### Already Done
| Requirement | Status |
|-------------|--------|
| Control EKS cluster with ArgoCD + SSO + RBAC | ✅ |
| Port-forward to ArgoCD UI | ✅ |
| 12 Docker images built & pushed | ✅ |
| GitOps repo structure (helm + applications) | ✅ |

---

## 3. Create 3 EKS Clusters

### 3.1 Dev Cluster

```bash
eksctl create cluster \
  --name dev-eks \
  --region us-east-1 \
  --version 1.29 \
  --node-type t3.small \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 4 \
  --managed \
  --asg-access \
  --full-ecr-access
```

### 3.2 UAT Cluster

```bash
eksctl create cluster \
  --name uat-eks \
  --region us-east-1 \
  --version 1.29 \
  --node-type t3.small \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 4 \
  --managed \
  --asg-access \
  --full-ecr-access
```

### 3.3 Prod Cluster

```bash
eksctl create cluster \
  --name prod-eks \
  --region us-east-1 \
  --version 1.29 \
  --node-type t3.small \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 4 \
  --managed \
  --asg-access \
  --full-ecr-access
```

> Each takes ~10–15 minutes. Run them in parallel in separate terminals.

### 3.4 Save Kubeconfig for All Clusters

```bash
# Control cluster (ArgoCD lives here)
aws eks update-kubeconfig --region us-east-1 --name your-argocd-cluster --alias argocd-control

# Dev cluster
aws eks update-kubeconfig --region us-east-1 --name dev-eks --alias dev-eks

# UAT cluster
aws eks update-kubeconfig --region us-east-1 --name uat-eks --alias uat-eks

# Prod cluster
aws eks update-kubeconfig --region us-east-1 --name prod-eks --alias prod-eks

# Verify
kubectl config get-contexts
```

---

## 4. Add Clusters to ArgoCD

```bash
# 1. Connect to ArgoCD control cluster
kubectl config use-context argocd-control

# 2. Port-forward ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# 3. Login
argocd login localhost:8080 \
  --username admin \
  --password $(argocd admin initial-password -n argocd | head -1) \
  --insecure

# 4. Add dev cluster
argocd cluster add dev-eks \
  --name dev-eks \
  --system-namespace argocd

# 5. Add uat cluster
argocd cluster add uat-eks \
  --name uat-eks \
  --system-namespace argocd

# 6. Add prod cluster
argocd cluster add prod-eks \
  --name prod-eks \
  --system-namespace argocd

# 7. Verify all 4 clusters
argocd cluster list
```

Expected output:
```
SERVER                          NAME           VERSION  STATUS
https://kubernetes.default.svc  in-cluster              Connected
https://ABCD.eks.amazonaws.com  dev-eks        v1.29    Connected
https://EFGH.eks.amazonaws.com  uat-eks        v1.29    Connected
https://IJKL.eks.amazonaws.com  prod-eks       v1.29    Connected
```

---

## 5. Update Manifests with Real Endpoints

All child Application manifests currently have placeholder endpoints:
- `https://dev-eks-endpoint.eks.amazonaws.com`
- `https://uat-eks-endpoint.eks.amazonaws.com`
- `https://prod-eks-endpoint.eks.amazonaws.com`

You MUST replace these with the actual cluster API endpoints from `argocd cluster list`.

### 5.1 Get Endpoints

```bash
declare -A ENDPOINTS

ENDPOINTS[dev]=$(argocd cluster list | grep dev-eks | awk '{print $1}')
ENDPOINTS[uat]=$(argocd cluster list | grep uat-eks | awk '{print $1}')
ENDPOINTS[prod]=$(argocd cluster list | grep prod-eks | awk '{print $1}')

echo "Dev:   ${ENDPOINTS[dev]}"
echo "UAT:   ${ENDPOINTS[uat]}"
echo "Prod:  ${ENDPOINTS[prod]}"
```

### 5.2 Replace in Child Apps

```bash
cd "GitOps Repo"

# Replace placeholder with actual dev endpoint
sed -i "s|https://dev-eks-endpoint.eks.amazonaws.com|${ENDPOINTS[dev]}|g" argocd/apps/dev/*.yaml

# Replace placeholder with actual uat endpoint
sed -i "s|https://uat-eks-endpoint.eks.amazonaws.com|${ENDPOINTS[uat]}|g" argocd/apps/uat/*.yaml

# Replace placeholder with actual prod endpoint
sed -i "s|https://prod-eks-endpoint.eks.amazonaws.com|${ENDPOINTS[prod]}|g" argocd/apps/prod/*.yaml

# Verify
head -n 3 argocd/apps/dev/java-app1.yaml argocd/apps/uat/java-app1.yaml argocd/apps/prod/java-app1.yaml
```

### 5.3 Replace in AppProjects

```bash
sed -i "s|https://dev-eks-endpoint.eks.amazonaws.com|${ENDPOINTS[dev]}|g" argocd/projects/dev.yaml
sed -i "s|https://uat-eks-endpoint.eks.amazonaws.com|${ENDPOINTS[uat]}|g" argocd/projects/uat.yaml
sed -i "s|https://prod-eks-endpoint.eks.amazonaws.com|${ENDPOINTS[prod]}|g" argocd/projects/prod.yaml
```

### 5.4 Commit & Push

```bash
git add argocd/projects argocd/apps
git commit -m "chore: update cluster endpoints for dev/uat/prod"
git push origin main
```

---

## 6. Apply ArgoCD Manifests

### 6.1 Apply in Order (Critical)

```bash
# Switch to control cluster
kubectl config use-context argocd-control

cd "GitOps Repo"

# Step 1: Apply AppProjects (security boundaries)
kubectl apply -f argocd/projects/dev.yaml
kubectl apply -f argocd/projects/uat.yaml
kubectl apply -f argocd/projects/prod.yaml

# Step 2: Apply parent Applications (creates child apps)
# Dev parent auto-syncs immediately
echo "Dev parent will auto-deploy all 12 child applications..."
kubectl apply -f argocd/parents/dev-environment.yaml

# UAT parent waits for manual sync
kubectl apply -f argocd/parents/uat-environment.yaml

# Prod parent waits for manual sync
kubectl apply -f argocd/parents/prod-environment.yaml
```

### 6.2 What Happens Now

| Parent App | Status | Action |
|-----------|--------|--------|
| `dev-environment` | 🟢 Green | Auto-created all 12 child apps → each child auto-synced → pods running on dev cluster |
| `uat-environment` | 🟡 Yellow | Shows "Out of Sync" — 12 child apps NOT created yet |
| `prod-environment` | 🟡 Yellow | Shows "Out of Sync" — 12 child apps NOT created yet |

---

## 7. Verify Deployments

### 7.1 ArgoCD UI

1. Open `https://localhost:8080`
2. Log in via SSO (GitHub)
3. **Applications tab** → see 3 tiles:
   - `dev-environment` → green ✅
   - `uat-environment` → yellow ⚠️
   - `prod-environment` → yellow ⚠️
4. Click `dev-environment` → **Managed Resources** → see 12 child apps (all green)

### 7.2 Verify Dev Cluster

```bash
kubectl config use-context dev-eks

# Check namespaces created by ArgoCD
kubectl get ns | grep -E '(java|dotnet|frontend)'
# Expected: 12 namespaces

# Check pods
kubectl get pods -n java-app1
kubectl get pods -n java-app2
kubectl get pods -n frontend1

# Test an app
kubectl port-forward svc/java-app1 -n java-app1 8080:80 &
curl http://localhost:8080/
# { "app": "java-app1", "message": "Hello from java-app1!" }
```

### 7.3 Trigger UAT

```bash
# Option A: CLI
argocd app sync uat-environment

# Option B: ArgoCD UI → click uat-environment → Sync button
```

What happens:
1. Parent `uat-environment` syncs → creates 12 child apps
2. Each child shows as "Missing" (not deployed yet, manual sync)
3. Click individual child app (e.g., `uat-java-app1`) → Sync → deploys to uat cluster

Or sync ALL UAT children at once:
```bash
argocd app sync app-of-apps --app uat-environment
```

### 7.4 Trigger Prod

```bash
argocd app sync prod-environment
```

Same flow as UAT, but with stricter controls.

---

## 8. Manager Demo Script

### Scene 1: Dashboard — 3 Tiles (15 sec)
> *"This is our GitOps platform. I manage production deployments across 3 separate EKS clusters from one dashboard. Notice only 3 tiles — not 36. Each tile represents an entire environment."*

Point to `dev-environment`, `uat-environment`, `prod-environment`.

### Scene 2: Dev Auto-Sync (30 sec)
> *"Dev automatically deploys. No human intervention. I applied the parent manifest and ArgoCD recursively created all 12 child apps and deployed them immediately."*

Click `dev-environment` → **Managed Resources** tab → show 12 green child apps.
Point to one child: `dev-java-app1` → show sync status `Automated`.

### Scene 3: UAT Manual Gate (1 min)
> *"UAT is entirely manual. The parent tile is yellow — nothing has been promoted yet. When I click Sync, ArgoCD creates the 12 child app objects. Then my team lead can sync individual apps."*

1. Click `uat-environment` → click **Sync**
2. Watch it turn green
3. Click back to `uat-environment` → Managed Resources → see 12 children
4. Click `uat-java-app1` → show "Missing" status
5. Click **Sync** on `uat-java-app1` → watch it turn green

### Scene 4: Prod Approval Gate (30 sec)
> *"Prod is the most protected. Auto-sync is completely disabled. Only an authorized lead can promote. Same App-of-Apps flow — locked behind manual approval."*

Click `prod-environment` → Sync Policy tab → show no automated sync.

### Scene 5: Multi-Cluster Proof (30 sec)
> *"None of these apps live on the ArgoCD cluster. Let me prove it."*

Open terminal:
```bash
kubectl config use-context argocd-control
kubectl get pods -n java-app1
# Output: No pods found in namespace java-app1 (or namespace doesn't exist)

kubectl config use-context dev-eks
kubectl get pods -n java-app1
# Output: java-app1-xxx pods running
```

> *"The control cluster only runs ArgoCD. All 12 apps live on the dev EKS cluster. Same for UAT and Prod — physically isolated clusters."*

### Scene 6: RBAC + SSO (30 sec)
> *"And all of this is protected by SSO + RBAC. Only people in the `argo-admins` GitHub team can sync Prod. Developers can sync UAT. Read-only users can only view."*

### Closing (10 sec)
> *"Three clusters. One dashboard. Zero kubectl. Git is the single source of truth. This is our GitOps production pipeline."*

---

## 9. Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `Unknown` on parent app | AppProject missing | `kubectl apply -f argocd/projects/dev.yaml` |
| `Permission denied` during sync | Wrong cluster in AppProject | Update `server:` in AppProject to match actual endpoint |
| Parent shows green but children don't appear | Parent synced before project | Delete + re-create parent: `kubectl delete app dev-environment -n argocd && kubectl apply -f argocd/parents/dev-environment.yaml` |
| Child shows `InvalidSpecError` | Wrong endpoint URL | Run Step 5.2 endpoint replacement again |
| `ImagePullBackOff` on workload cluster | Images not accessible | Ensure images are in public Docker Hub or ECR with correct pull permissions |
| `Pending` pods on workload cluster | Insufficient nodes | `eksctl scale nodegroup --cluster dev-eks --nodes 4` |
| ArgoCD can't reach external cluster | Security group / network | Ensure control cluster VPC can reach workload cluster API on 443 |
| `ComparisonError` on cluster | Kubeconfig expired | Re-add: `argocd cluster rm dev-eks && argocd cluster add dev-eks` |

---

## 10. Cost & Cleanup

### Costs (per month, 4 clusters × t3.small)

| Component | Monthly Cost |
|-----------|-------------|
| Control EKS cluster | ~$73 |
| Dev EKS cluster | ~$73 |
| UAT EKS cluster | ~$73 |
| Prod EKS cluster | ~$73 |
| 2× t3.small nodes per cluster (×4) | ~$200 |
| **Total** | **~$492/month** |

### Post-Demo Cleanup

Save money by deleting or scaling down:

```bash
# Delete dev cluster (stops billing for that cluster)
eksctl delete cluster --name dev-eks --region us-east-1 --wait

# Scale UAT cluster nodes to 0 (saves node cost, keeps cluster)
eksctl scale nodegroup --cluster uat-eks --region us-east-1 --nodes 0

# Scale Prod cluster nodes to 0
eksctl scale nodegroup --cluster prod-eks --region us-east-1 --nodes 0
```

**Keep the control cluster** (ArgoCD) so you can resume the demo later.

---

## Quick Reference Commands

```bash
# ArgoCD login
argocd login localhost:8080 --username admin \
  --password $(argocd admin initial-password -n argocd | head -1) --insecure

# List clusters
argocd cluster list

# List apps
argocd app list

# Sync a parent environment
argocd app sync dev-environment
argocd app sync uat-environment
argocd app sync prod-environment

# Sync a specific child app
argocd app sync dev-java-app1
argocd app sync uat-java-app1

# View app details
argocd app get dev-environment

# View managed resources (children)
argocd app get dev-environment -o json | jq '.status.resources'

# Check pods on dev cluster
kubectl config use-context dev-eks
kubectl get pods --all-namespaces

# Check pods on uat cluster
kubectl config use-context uat-eks
kubectl get pods --all-namespaces
```

---

## End of Guide
