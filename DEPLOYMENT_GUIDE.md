# CD Pipeline Deployment Guide — ArgoCD + GKE (GitOps)

> **Reference**: This guide is aligned with the official `CD Pipeline Approach Document` and adapted for the Spring Boot RealWorld demo application as a POC. When the actual application arrives tomorrow, the same pipeline, repo structure, and ArgoCD manifests will be used unchanged.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Overview](#2-architecture-overview)
3. [Pre-Requisites](#3-pre-requisites)
4. [Repository Structure](#4-repository-structure)
5. [Jenkins CI → CD Handoff](#5-jenkins-ci--cd-handoff)
6. [Environment Promotion Strategy](#6-environment-promotion-strategy)
7. [Rolling Deployment & Rollback](#7-rolling-deployment--rollback)
8. [ArgoCD Configuration](#8-argocd-configuration)
9. [Notifications](#9-notifications)
10. [Application Readiness Checklist](#10-application-readiness-checklist)
11. [Step-by-Step Implementation for Demo Project](#11-step-by-step-implementation-for-demo-project)
12. [Quick Reference Commands](#12-quick-reference-commands)

---

## 1. Executive Summary

This guide implements a **GitOps-first Continuous Deployment** pipeline using **ArgoCD** on **GCP**.

**Key principles**:
- **Git is the single source of truth** for all deployed state.
- **No manual `kubectl`** in any environment — ArgoCD applies everything.
- **Dev auto-deploys** on every successful CI run.
- **UAT** requires a manual trigger by a team lead.
- **Prod** requires an explicit approval gate before deploy.
- All environments use **rolling deployments** for zero downtime.
- ArgoCD **continuously reconciles** live cluster state against Git — drift is auto-corrected in Dev.

**Platform**: GCP (GKE + Artifact Registry + Secret Manager + Cloud Build / Jenkins CI)

---

## 2. Architecture Overview

```mermaid
graph TB
    subgraph "Source Code Repository"
        SRC[Application Source Code<br/>+ Dockerfile / build.gradle]
    end

    subgraph "GitOps Repository"
        GITOPS_HELM[charts/spring-boot-realworld/]
        GITOPS_DEV[values-dev.yaml]
        GITOPS_UAT[values-uat.yaml]
        GITOPS_PROD[values-prod.yaml]
        GITOPS_ARGO[argocd/ applications.yaml]
    end

    subgraph "CI (Jenkins)"
        JENKINS_BUILD[1. Build + Test]
        JENKINS_IMAGE[2. Build Image]
        JENKINS_PUSH[3. Push to Artifact Registry]
        JENKINS_TAG[4. Update image tag in GitOps]
        JENKINS_TRIGGER[5. Trigger ArgoCD sync]
    end

    subgraph "ArgoCD Cluster (GKE - Control Plane VPC)"
        ARGO_APP[ArgoCD Applications]
        ARGO_SERVER[ArgoCD Server + UI/API]
    end

    subgraph "Dev Environment (GKE)"
        DEV_ING[Ingress]
        DEV_SVC[Service]
        DEV_DEP[Deployment]
        DEV_PVC[PVC for SQLite]
    end

    subgraph "UAT Environment (GKE)"
        UAT_ING[Ingress]
        UAT_SVC[Service]
        UAT_DEP[Deployment]
        UAT_PVC[PVC for SQLite]
    end

    subgraph "Prod Environment (GKE)"
        PROD_ING[Ingress]
        PROD_SVC[Service]
        PROD_DEP[Deployment]
        PROD_PVC[PVC for SQLite]
    end

    SRC --> JENKINS_BUILD
    JENKINS_BUILD --> JENKINS_IMAGE --> JENKINS_PUSH
    JENKINS_PUSH --> JENKINS_TAG
    JENKINS_TAG --> GITOPS_DEV
    JENKINS_TRIGGER --> ARGO_SERVER

    GITOPS_HELM --> ARGO_APP
    GITOPS_DEV --> ARGO_APP
    GITOPS_UAT --> ARGO_APP
    GITOPS_PROD --> ARGO_APP
    GITOPS_ARGO --> ARGO_APP

    ARGO_APP -->|Auto-sync| DEV_DEP
    ARGO_APP -->|Manual sync| UAT_DEP
    ARGO_APP -->|Manual + Approval| PROD_DEP
```

---

## 3. Pre-Requisites

### 3.1 GKE Clusters

| Cluster | Purpose | Nodes | Workload Identity |
|---------|---------|-------|-------------------|
| `argocd-gke` | ArgoCD control plane only | 2+ nodes, `e2-medium` or higher | Enabled |
| `dev-gke` | Dev workloads | 2+ nodes | Enabled |
| `uat-gke` | UAT workloads | 2+ nodes | Enabled |
| `prod-gke` | Prod workloads | 2+ nodes | Enabled |

### 3.2 Infrastructure Provisioning

The **Infrastructure / Platform team** must provide:

1. **GKE Clusters**: All 4 clusters provisioned and reachable over private Google backbone.
2. **ArgoCD Namespace**: `argocd` namespace pre-created on the ArgoCD cluster with resource quotas.
3. **Ingress Controller**: NGINX or GKE native Ingress installed on the **ArgoCD cluster** (to expose ArgoCD UI/API privately).
4. **Artifact Registry**: Registry provisioned with pull access granted to all GKE node service accounts.
5. **Secret Manager**: For runtime secrets (JWT_SECRET, DB passwords, etc.).
6. **Service Accounts** in each target cluster (dev/uat/prod) with namespace-scoped RBAC:
   - `apply`, `patch`, `delete` permissions in the target namespace only.
7. **Kubeconfig / API endpoint** details for each target cluster.
8. **VPC Connectivity**: Control Plane VPC ↔ Dev/UAT/Prod VPC on port 443.

### 3.3 Git / SCM Setup

| Repository | Contents | Access |
|------------|----------|--------|
| `app-repo` | Application source code, Dockerfile, build scripts | Dev team: RW, CI service account: R |
| `gitops-repo` | Helm charts, ArgoCD manifests, environment values | DevOps team: RW, CI service account: R+tag-push |

> **For this POC**, both code and GitOps can live in the **same repository** under separate directories (`charts/` and `argocd/`). When the real app arrives, split the GitOps directory into a dedicated repo.

---

## 4. Repository Structure

This repo structure follows the CD Pipeline Approach Document exactly.

```
spring-boot-realworld-example-app/
├── src/                               # Application source code
├── Dockerfile                         # Container image build
├── build.gradle                       # Gradle build
├── Jenkinsfile                        # CI pipeline (builds image, updates GitOps)
├── charts/                            # GitOps: Helm charts
│   └── spring-boot-realworld/
│       ├── Chart.yaml
│       ├── values.yaml                # Base defaults
│       ├── values-dev.yaml            # Dev-specific config
│       ├── values-uat.yaml            # UAT-specific config
│       ├── values-prod.yaml           # Prod-specific config
│       └── templates/
│           ├── _helpers.tpl
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── ingress.yaml
│           ├── configmap.yaml
│           ├── secret.yaml
│           ├── pvc.yaml
│           ├── hpa.yaml
│           ├── pdb.yaml
│           └── serviceaccount.yaml
├── argocd/                            # GitOps: ArgoCD manifests
│   ├── appproject.yaml
│   └── applications.yaml
└── docs/
    ├── PROJECT_OVERVIEW.md
    ├── CI_OPTIMIZATION.md
    └── DEPLOYMENT_GUIDE.md            # This file
```

### 4.1 Why a dedicated `charts/` directory?

Per the approach document, the GitOps repo (or directory) keeps **Helm charts separate from application code**. This ensures:
- ArgoCD only watches `charts/` and `argocd/` — not your source code.
- CI only writes image tag bumps to `values-*.yaml` — never touches templates.

---

## 5. Jenkins CI → CD Handoff

The handoff consists of **5 steps** after CI completes:

1. **CI completes all stages** (build, test, security scan, Docker build).
2. **Jenkins pushes the verified image** to Artifact Registry with a semantic version tag.
3. **Jenkins commits** the updated image tag to `charts/spring-boot-realworld/values-dev.yaml` in the GitOps repo.
4. **Jenkins triggers**: `argocd app sync spring-boot-realworld-dev`
5. **ArgoCD detects** the new desired state and begins a rolling deployment to Dev.

### 5.1 Jenkinsfile Extension

The `Jenkinsfile` in this repo should include a **CD stage** after artifact publish:

```groovy
// --- After image is pushed to Artifact Registry ---

stage('Update GitOps for Dev') {
    steps {
        script {
            sh """
                git clone https://github.com/your-org/gitops-repo.git gitops
                cd gitops/charts/spring-boot-realworld
                
                # Update image tag in values-dev.yaml
                sed -i "s|tag: .*|tag: \"${VERSION_TAG}\"|" values-dev.yaml
                
                git config user.email "jenkins@example.com"
                git config user.name "Jenkins CI"
                git add values-dev.yaml
                git commit -m "[Jenkins] Deploy ${VERSION_TAG} to dev"
                git push origin main
            """
        }
    }
}

stage('Trigger ArgoCD Dev Sync') {
    steps {
        script {
            // Install argocd CLI in your Jenkins agent or use a container
            sh """
                argocd login argocd-server.argocd.svc.cluster.local:443 \
                    --username admin \
                    --password \$ARGOCD_PASSWORD \
                    --insecure
                    
                argocd app sync spring-boot-realworld-dev
            """
        }
    }
}
```

> **Note**: For the POC, you can skip the Jenkinsfile changes if you prefer to update tags manually or via a GitHub Action. The real application will have a full Jenkins shared library.

---

## 6. Environment Promotion Strategy

### 6.1 Dev — Auto-Sync

- **Trigger**: Every successful CI merge to `dev` branch.
- **Sync mode**: Auto + self-heal + prune.
- **Human approval**: None.
- **Behavior**: Any drift from Git is automatically corrected.

### 6.2 UAT — Manual Sync

- **Trigger**: After Dev validation, team lead raises a PR to update `values-uat.yaml`.
- **Sync mode**: Manual — team lead clicks **Sync** in ArgoCD UI or runs `argocd app sync`.
- **Human approval**: Team lead.
- **Behavior**: Prevents unvalidated builds from reaching UAT.

### 6.3 Prod — Manual Approval Gate

- **Trigger**: Semantic version tag (`v1.2.3`) cut from `main` after UAT sign-off.
- **Sync mode**: Manual + approval gate.
- **Human approval**: Dev Lead + Ops Lead.
- **Auto-sync**: **Explicitly disabled** for Prod. No automated deployment path.
- **Behavior**: ArgoCD audit log captures who triggered the sync.

### 6.4 Branch-to-Environment Mapping

| Branch Event | CD Action | Target Cluster | Sync Mode |
|--------------|-----------|----------------|-----------|
| Merge to `dev` | Jenkins updates `values-dev.yaml`, triggers sync | Dev GKE | **Auto** — immediate |
| Dev → UAT (merge/PR) | Team lead merges tag bump to `values-uat.yaml` | UAT GKE | **Manual** — team lead triggers |
| UAT → `main` (tag) | PR to `values-prod.yaml` approved by Dev Lead + Ops Lead | Prod GKE | **Manual** — explicit approval required |

---

## 7. Rolling Deployment & Rollback

### 7.1 RollingUpdate Strategy

All environments use Kubernetes `RollingUpdate`:

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
```

**Benefits**:
- Zero downtime during deploys.
- New pods must pass readiness probe before old pods terminate.

### 7.2 Deployment Verification & Rollback

1. **ArgoCD monitors rollout**: Waits for` progressDeadlineSeconds`.
2. **Post-sync health check**: Polls `/health` (or `/tags` for this demo app).
3. **Auto rollback**: If health check fails, ArgoCD marks sync as failed.
4. **Manual rollback**: Revert the image tag commit in GitOps → ArgoCD auto-rolls back.

> **Important**: For the real application, add `spring-boot-starter-actuator` and use `/actuator/health`. For this demo POC, `/tags` is used as the health probe.

---

## 8. ArgoCD Configuration

### 8.1 Install ArgoCD on the Control Plane GKE

```bash
# Connect to ArgoCD cluster
gcloud container clusters get-credentials argocd-gke --region=us-central1

# Create namespace
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd

# Port-forward for initial setup
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get admin password
argocd admin initial-password -n argocd
```

> **Ingress on ArgoCD cluster**: Install NGINX Ingress Controller (or GKE native) and create an Ingress for ArgoCD UI so Jenkins and DevOps team can access it internally.

### 8.2 Register Target Clusters

```bash
# Dev cluster
argocd cluster add gke_your-project_us-central1_dev-gke \
  --name dev-gke \
  --system-namespace argocd

# UAT cluster
argocd cluster add gke_your-project_us-central1_uat-gke \
  --name uat-gke \
  --system-namespace argocd

# Prod cluster
argocd cluster add gke_your-project_us-central1_prod-gke \
  --name prod-gke \
  --system-namespace argocd
```

> **Tip**: Use Workload Identity to give ArgoCD service account permission to access target clusters. This avoids storing kubeconfig secrets in ArgoCD.

### 8.3 AppProject (see `argocd/appproject.yaml`)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: spring-boot-realworld
  namespace: argocd
spec:
  description: RealWorld Spring Boot — Dev / UAT / Prod
  sourceRepos:
    - 'https://github.com/your-org/spring-boot-realworld-example-app.git'
  destinations:
    - namespace: spring-boot-realworld
      server: https://dev-gke-endpoint  # Dev cluster
    - namespace: spring-boot-realworld
      server: https://uat-gke-endpoint  # UAT cluster
    - namespace: spring-boot-realworld
      server: https://prod-gke-endpoint # Prod cluster
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceWhitelist:
    - group: 'apps'
      kind: Deployment
    - group: ''
      kind: Service
    - group: 'networking.k8s.io'
      kind: Ingress
    - group: ''
      kind: ConfigMap
    - group: ''
      kind: Secret
    - group: ''
      kind: PersistentVolumeClaim
    - group: 'policy'
      kind: PodDisruptionBudget
    - group: 'autoscaling'
      kind: HorizontalPodAutoscaler
```

### 8.4 Applications (see `argocd/applications.yaml`)

| Application | Source Path | Target Cluster | Sync Policy |
|-------------|-------------|----------------|-------------|
| `spring-boot-realworld-dev` | `charts/spring-boot-realworld` + `values-dev.yaml` | Dev GKE | **Auto** + self-heal + prune |
| `spring-boot-realworld-uat` | `charts/spring-boot-realworld` + `values-uat.yaml` | UAT GKE | **Manual** only |
| `spring-boot-realworld-prod` | `charts/spring-boot-realworld` + `values-prod.yaml` | Prod GKE | **Manual** + approval gate |

**Dev Application**:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: spring-boot-realworld-dev
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: spring-boot-realworld
  source:
    repoURL: https://github.com/your-org/spring-boot-realworld-example-app.git
    targetRevision: HEAD
    path: charts/spring-boot-realworld
    helm:
      valueFiles:
        - values.yaml
        - values-dev.yaml
  destination:
    server: https://dev-gke-endpoint
    namespace: spring-boot-realworld
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**UAT Application** (no auto-sync):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: spring-boot-realworld-uat
  namespace: argocd
spec:
  project: spring-boot-realworld
  source:
    repoURL: https://github.com/your-org/spring-boot-realworld-example-app.git
    targetRevision: HEAD
    path: charts/spring-boot-realworld
    helm:
      valueFiles:
        - values.yaml
        - values-uat.yaml
  destination:
    server: https://uat-gke-endpoint
    namespace: spring-boot-realworld
  syncPolicy: {}  # Manual sync only
```

**Prod Application** (manual + approval):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: spring-boot-realworld-prod
  namespace: argocd
spec:
  project: spring-boot-realworld
  source:
    repoURL: https://github.com/your-org/spring-boot-realworld-example-app.git
    targetRevision: HEAD
    path: charts/spring-boot-realworld
    helm:
      valueFiles:
        - values.yaml
        - values-prod.yaml
  destination:
    server: https://prod-gke-endpoint
    namespace: spring-boot-realworld
  syncPolicy: {}  # Manual sync + approval gate enforced by process
```

### 8.5 Sync Policy Summary

| Setting | Dev | UAT | Prod |
|---------|-----|-----|------|
| Auto-sync | ✅ Enabled | ❌ Disabled | ❌ Disabled |
| Self-heal | ✅ Enabled | ❌ Disabled | ❌ Disabled |
| Prune     | ✅ Enabled | ❌ Disabled | ❌ Disabled |
| Retry limit | 3 | 2 | 1 |

---

## 9. Notifications

ArgoCD notifications should be configured for:

| Event | Channel | Recipients |
|-------|---------|------------|
| Sync succeeded | `#deploy-dev`, `#deploy-uat`, `#deploy-prod` | DevOps team + service owner |
| Sync failed | `#deploy-alerts` | DevOps team + on-call |
| Health check failed | `#deploy-alerts` | On-call + Ops Lead |
| Rollback triggered | `#deploy-alerts` | On-call + Ops Lead + Dev Lead |
| Prod approval needed | `#deploy-prod` | Dev Lead + Ops Lead |

**Setup**:
```bash
# Install ArgoCD Notifications
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-notifications/release-1.0/manifests/install.yaml

# Configure Slack token
kubectl create secret generic argocd-notifications-secret \
  -n argocd \
  --from-literal=slack-token=xoxb-your-token
```

See `argocd/notifications.yaml` for a sample notification configuration.

---

## 10. Application Readiness Checklist

Before onboarding the real application to this CD pipeline, verify:

- [ ] **Health endpoint** exposed at `/health` or `/healthz` returning HTTP 200 within 5 seconds.
- [ ] **Readiness and liveness probes** defined in the Helm chart values.
- [ ] **CPU and memory requests/limits** set per environment in Helm values files.
- [ ] **Stateless OR persistent storage documented**: For the real app, replace SQLite with Cloud SQL / AlloyDB and remove PVC. For this demo, PVC is acceptable.
- [ ] **No hardcoded secrets**: All credentials injected at runtime via **External Secrets Operator** from Secret Manager (or via Kubernetes Secrets for the POC).
- [ ] **Resource quotas** set on target namespaces.
- [ ] **RollingUpdate strategy** configured (`maxSurge=1`, `maxUnavailable=0`).
- [ ] **PodDisruptionBudget** configured for Prod (after moving away from SQLite).

---

## 11. Step-by-Step Implementation for Demo Project

### Step 1: Build & Push Docker Image

```bash
cd /home/vishaltyagi/Desktop/spring-boot-realworld-example-app
./gradlew bootBuildImage --imageName=gcr.io/PROJECT_ID/spring-boot-realworld:0.0.1-SNAPSHOT
docker push gcr.io/PROJECT_ID/spring-boot-realworld:0.0.1-SNAPSHOT
```

### Step 2: Update values-dev.yaml with Image Tag

```bash
# Edit charts/spring-boot-realworld/values-dev.yaml
image:
  repository: gcr.io/PROJECT_ID/spring-boot-realworld
  tag: "0.0.1-SNAPSHOT"
```

### Step 3: Create Target Namespaces on Dev Cluster

```bash
gcloud container clusters get-credentials dev-gke --region=us-central1
kubectl create namespace spring-boot-realworld
```

### Step 4: Apply ArgoCD AppProject + Applications

```bash
gcloud container clusters get-credentials argocd-gke --region=us-central1
kubectl apply -f argocd/appproject.yaml
kubectl apply -f argocd/applications.yaml
```

### Step 5: Trigger Dev Sync and Verify

```bash
argocd app sync spring-boot-realworld-dev
argocd app wait spring-boot-realworld-dev --health

# Verify pods
kubectl get pods -n spring-boot-realworld --context=dev-gke

# Verify service
kubectl get svc -n spring-boot-realworld --context=dev-gke

# Verify ingress (if you have an Ingress on dev cluster)
kubectl get ingress -n spring-boot-realworld --context=dev-gke
```

### Step 6: Repeat for UAT and Prod

UAT: Update `values-uat.yaml` → `argocd app sync spring-boot-realworld-uat`
Prod: Update `values-prod.yaml` → get approval → `argocd app sync spring-boot-realworld-prod`

---

## 12. Quick Reference Commands

```bash
# ArgoCD login
argocd login ARGOCD_SERVER:443 --username admin --password $(argocd admin initial-password -n argocd | head -1)

# List applications
argocd app list

# Sync dev
argocd app sync spring-boot-realworld-dev

# Sync uat (manual)
argocd app sync spring-boot-realworld-uat

# View app diff
argocd app diff spring-boot-realworld-dev

# View app status
argocd app get spring-boot-realworld-dev

# Rollback (revert Git commit, then re-sync)
# Or use: argocd app rollback spring-boot-realworld-dev 0

# Helm lint (local validation)
helm lint charts/spring-boot-realworld

# Helm template preview (dev)
helm template spring-boot-realworld-dev charts/spring-boot-realworld \
  --values charts/spring-boot-realworld/values.yaml \
  --values charts/spring-boot-realworld/values-dev.yaml
```

---

## 13. Transitioning to the Real Application (Tomorrow)

When the actual application arrives, the **only changes** required are:

1. **Database**: Replace SQLite with Cloud SQL / AlloyDB / PostgreSQL.
   - Remove the `pvc.yaml` template.
   - Update `spring.datasource.url` in `ConfigMap` to point to managed DB.
   - Inject DB credentials via External Secrets Operator from Secret Manager.
2. **Secrets**: Move `jwt.secret` from hardcoded K8s Secret to Secret Manager + External Secrets.
3. **Image repository**: Update `repository` in all `values-*.yaml` files.
4. **Scaling**: Enable HPA and PDB in `values-prod.yaml` now that SQLite is gone.
5. **Health checks**: Switch probe path from `/tags` to `/actuator/health`.
6. **Ingress domain**: Replace `realworld.example.com` with your actual domain.

**What stays exactly the same**:
- ArgoCD AppProject and Application structure.
- Jenkins CI → CD handoff flow (build → push → update GitOps → trigger sync).
- Environment promotion strategy (auto → manual → approval gate).
- RollingUpdate strategy.
- Notification channels.

---

## End of Guide

For questions or issues, contact the **COE – Infrastructure & DevOps Division**.
