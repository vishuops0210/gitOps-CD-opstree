# ArgoCD + SSO + RBAC Demo on AWS EKS (Free Tier)

> **Current Goal**: Deploy ArgoCD on your existing EKS cluster, implement SSO, implement RBAC, and test it all on the ArgoCD UI. That's it. No app deployment yet.

---

## Table of Contents

0. [Part 0: Create EKS Cluster & Connect From Your Laptop](#0-part-0-create-eks-cluster--connect-from-your-laptop)
1. [Concepts You Need to Know](#1-concepts-you-need-to-know)
2. [Architecture Diagram](#2-architecture-diagram)
3. [Part 1: Prepare Your EKS Node](#3-part-1-prepare-your-eks-node)
4. [Part 2: Install ArgoCD](#4-part-2-install-argocd)
5. [Part 3: Configure SSO with GitHub](#5-part-3-configure-sso-with-github)
6. [Part 4: Configure RBAC](#6-part-4-configure-rbac)
7. [Part 5: Expose ArgoCD UI](#7-part-5-expose-argocd-ui)
8. [Part 6: Test SSO + RBAC](#8-part-6-test-sso--rbac)
9. [Part 7: Create a Dummy App for RBAC Testing](#9-part-7-create-a-dummy-app-for-rbac-testing)
10. [Manager Demo Script](#10-manager-demo-script)
11. [Cleanup](#11-cleanup)
12. [Alternative SSO](#12-alternative-sso)
13. [Troubleshooting](#13-troubleshooting)

---

---

## 0. Part 0: Create EKS Cluster & Connect From Your Laptop

> If you **already have an EKS cluster running**, skip to [Part 1](#3-part-1-prepare-your-eks-node). This section is for absolute beginners.

### What is EKS?

**Amazon EKS (Elastic Kubernetes Service)** is AWS's managed Kubernetes. Think of it as:
- AWS runs the Kubernetes "brain" (control plane) for you
- You just add worker computers (EC2 instances) that run your apps
- You connect to it from your laptop using `kubectl`

**Cost warning**: The EKS control plane costs **$0.10/hour (~$73/month)** regardless of whether you use it. Your $150 credits cover this easily, but be aware.

---

### Step 0.1: Install Local Tools on Your Laptop

These are the 4 tools you need on your computer to talk to AWS and Kubernetes.

| Tool | What It Does | Install Link |
|------|-------------|--------------|
| **AWS CLI** | Talks to AWS services from your terminal | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| **kubectl** | Talks to Kubernetes clusters | https://kubernetes.io/docs/tasks/tools/ |
| **eksctl** | Creates and manages EKS clusters easily | https://eksctl.io/installation/ |
| **Helm** | Package manager for Kubernetes apps | https://helm.sh/docs/intro/install/ |

**Verify installations:**

```bash
aws --version        # Should show 2.x
kubectl version      # Should show v1.27+
eksctl version       # Should show v0.170+
helm version         # Should show v3.12+
```

> 💡 **What are these tools?**
> - `aws` = your remote control for AWS
> - `kubectl` = your remote control for Kubernetes
> - `eksctl` = a helper that creates EKS clusters with one command instead of 50 clicks
> - `helm` = like `apt-get` or `brew`, but for Kubernetes apps

---

### Step 0.2: Configure AWS Credentials on Your Laptop

Your laptop needs permission to create resources in your AWS account.

#### Via AWS Console (UI)

1. Log into https://console.aws.amazon.com
2. Click your **name** (top right) → **Security credentials**
3. Scroll down to **Access keys** → Click **Create access key**
4. Choose **Command Line Interface (CLI)**
5. Click the checkbox **"I understand..."** → **Next**
6. Click **Create access key**
7. **IMPORTANT**: Click **Download .csv file** — you cannot see the Secret Access Key again
8. You now have:
   - **Access Key ID** (looks like `AKIA...`)
   - **Secret Access Key** (looks like `xxxxxxxxxxxxxxxx`)

#### Via Terminal (CLI)

```bash
# Run this and paste your keys when prompted
aws configure

# It will ask:
# AWS Access Key ID [None]: AKIAXXXXXXXXXXXXXXXX
# AWS Secret Access Key [None]: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# Default region name [None]: us-east-1
# Default output format [None]: json
```

**Verify it works:**

```bash
aws sts get-caller-identity
```

**Expected output:**
```json
{
    "UserId": "AIXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/your-username"
}
```

If this shows your account number, your laptop is connected to AWS.

---

### Step 0.3: Create the EKS Cluster

#### Option A: AWS Console (UI) — Click-by-Click

1. Go to https://console.aws.amazon.com/eks/home
2. Click **Clusters** (left menu) → **Add cluster** → **Create**
3. **Configure cluster**:
   - **Name**: `demo-eks-cluster-1`
   - **Kubernetes version**: `1.29` (latest stable)
   - **Cluster service role**: Click **Create recommended role** → follow the prompt → select the created role
4. **Networking**:
   - **VPC**: Create new VPC (or select existing default VPC)
   - **Subnets**: Select at least 2 subnets in different Availability Zones (e.g., `us-east-1a` and `us-east-1b`)
   - **Security groups**: Use default
   - **Cluster endpoint access**: Select **Public** (so you can access it from your laptop)
5. Click **Next** → **Next** → **Create**
6. Wait ~10-15 minutes. The cluster goes from **Creating** → **Active**

#### Option B: Terminal (CLI) — One Command

```bash
# Create a cluster with 1 t3.micro node in public subnets
# This is the cheapest possible setup for a demo

eksctl create cluster \
  --name demo-eks-cluster-1 \
  --region us-east-1 \
  --version 1.29 \
  --node-type t3.micro \
  --nodes 1 \
  --nodes-min 1 \
  --nodes-max 2 \
  --node-private-networking=false \
  --managed \
  --asg-access \
  --external-dns-access \
  --full-ecr-access \
  --appmesh-access \
  --alb-ingress-access

# This command does EVERYTHING:
# - Creates the EKS control plane ($0.10/hr)
# - Creates a VPC with public subnets
# - Creates a managed node group with t3.micro
# - Sets up IAM roles automatically
# - Configures security groups
```

**Wait time**: 10-15 minutes. You will see progress output.

---

### Step 0.4: Connect Your Laptop to the Cluster

After the cluster is created, you need to tell `kubectl` where your cluster is.

```bash
# Update your local kubeconfig file with cluster credentials
aws eks update-kubeconfig \
  --region us-east-1 \
  --name demo-eks-cluster-1

# Check if kubectl can talk to the cluster
kubectl get nodes
```

**Expected output:**
```
NAME                                           STATUS   ROLES    AGE   VERSION
ip-192-168-45-xx.us-east-1.compute.internal   Ready    <none>   2m    v1.29.0-eks-xxxxx
```

If you see a node listed, **you are connected**.

---

### Step 0.5: Verify Everything Works

Run these commands to confirm your setup is healthy:

```bash
# List all nodes (worker computers)
kubectl get nodes -o wide

# List all namespaces (folders in Kubernetes)
kubectl get namespaces

# Check system pods	kubectl get pods -n kube-system

# Check AWS Load Balancer Controller (if installed)
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

**If any command shows results, you are good to go.**

---

### Step 0.6: Troubleshooting Connection Issues

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| `Unable to connect to the server` | Wrong region or cluster name | Re-run `aws eks update-kubeconfig --region us-east-1 --name demo-eks-cluster-1` |
| `No nodes found` | Node group still creating | Wait 5 more minutes, re-run `kubectl get nodes` |
| `Unauthorized` | AWS credentials expired | Re-run `aws configure` with fresh keys |
| `context was not found` | Wrong cluster name in command | Check exact cluster name in AWS Console → EKS → Clusters |

---

## 1. Concepts You Need to Know

Before we do anything, here are the building blocks explained in simple terms.

| Term | What It Is (Simple) | What It Does Here |
|------|--------------------|--------------------|
| **Kubernetes (K8s)** | A system that runs your apps inside containers | EKS is Amazon's managed Kubernetes |
| **Namespace** | A "folder" inside Kubernetes that groups resources together | We create `argocd` namespace so ArgoCD lives in its own space |
| **Pod** | The smallest running unit in K8s — think: one running container | ArgoCD server, controller, Dex etc. each run in their own pods |
| **ConfigMap** | A K8s object that stores configuration data (like env variables) | ArgoCD stores its SSO and URL settings in a ConfigMap called `argocd-cm` |
| **Secret** | Like a ConfigMap but encrypted, stores passwords/keys | We store the GitHub OAuth client secret here |
| **Service** | Exposes a pod so other pods (or external users) can reach it | `argocd-server` service exposes the ArgoCD web UI |
| **Ingress** | K8s way of exposing apps to the internet (maps to an AWS ALB) | For public ArgoCD UI access without kubectl |
| **Helm** | A "package manager" for Kubernetes — installs apps with one command | We use Helm to install ArgoCD instead of typing hundreds of YAML lines |
| **ArgoCD** | A GitOps tool — it watches your Git repo and auto-deploys changes | It will watch our repo and deploy our app automatically |
| **Dex** | A "connector" that sits between ArgoCD and external identity providers | It reads your GitHub login, then tells ArgoCD "this user is verified" |
| **SSO (Single Sign-On)** | Log in once with your company/Google/GitHub credentials, access many apps | Instead of creating a new password for ArgoCD, you log in with GitHub |
| **RBAC (Role-Based Access Control)** | A security system: different users get different permissions | Admins can delete things. Developers can sync but not delete. Others can only read. |
| **OAuth** | A protocol that lets you log into App A using your login from App B | ArgoCD is "App A". GitHub is "App B". Dex handles the handshakes. |
| **IAM / IRSA** | AWS Identity system — tells AWS who your K8s pods are | We use IRSA so ArgoCD pods can talk to AWS services securely |
| **Workload Identity** (GCP) | Google's version of IRSA — same concept | Not needed for AWS, but same idea |

---

## 2. Architecture Diagram

```
        ┌──────────────────┐
        │  Your Laptop     │
        │  (Web Browser)   │
        └───────┬──────────┘
                │
                │ Browse to https://localhost:8080
                │
                ▼
        ┌──────────────────┐
        │ kubectl port-    │
        │ forward (tunnel  │
        │ from laptop      │
        │ to EKS)          │
        └───────┬──────────┘
                │
                ▼
┌──────────────────────────────────────────┐
│  AWS EKS Cluster                         │
│                                          │
│  ┌──────────────────────────────────┐   │
│  │  Namespace: argocd               │   │
│  │                                  │   │
│  │  ┌──────────────┐               │   │
│  │  │ ArgoCD Server│ ←── Web UI    │   │
│  │  └──────┬───────┘               │   │
│  │         │                        │   │
│  │         │ Talks to Dex           │   │
│  │         ▼                        │   │
│  │  ┌──────────────┐               │   │
│  │  │ Dex (SSO     │ ←── GitHub    │   │
│  │  │ Middleware)  │     OAuth     │   │
│  │  └──────┬───────┘               │   │
│  │         │                        │   │
│  │         │ Authenticates          │   │
│  │         │ via RBAC rules         │   │
│  │         ▼                        │   │
│  │  ┌──────────────────┐           │   │
│  │  │  configmap       │           │   │
│  │  │  argocd-rbac-cm  │           │   │
│  │  └──────────────────┘           │   │
│  └──────────────────────────────────┘   │
└──────────────────────────────────────────┘
```

---

## 3. Part 1: Prepare Your EKS Node

### What is an EKS Node?
An EKS cluster has a **control plane** (managed by AWS, costs $0.10/hr) and **worker nodes** (EC2 instances that actually run your containers). For ArgoCD to run, we need **at least 1 worker node**.

### Why do we need at least 1 proper node?
ArgoCD needs ~400MB RAM minimum. A `t3.micro` (1GB RAM) is very tight. A `t3.small` (2GB RAM) is much more comfortable for the demo.

### CLI Approach

```bash
export CLUSTER_NAME="your-eks-cluster"
export AWS_REGION="us-east-1"

# Check how many nodes you have and what type
kubectl get nodes -o wide
```

If you have **0 nodes** or only a `t3.micro`, add a `t3.small`:

```bash
eksctl create nodegroup \
  --cluster $CLUSTER_NAME \
  --region $AWS_REGION \
  --name argocd-demo-ng \
  --node-type t3.small \
  --nodes 1 \
  --nodes-min 1 \
  --nodes-max 2 \
  --node-private-networking=false \
  --managed

# Wait for the node to be ready
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# Verify
kubectl get nodes -o wide
```

**Expected output**:
```
NAME                                           STATUS   ROLES    AGE   VERSION
ip-192-168-45-xx.us-east-1.compute.internal   Ready    <none>   2m    v1.29.0-eks-5e0fdde
```

> ✅ You can also see this in the **AWS Console** → EC2 → Instances — you'll see a new instance running.

---

## 4. Part 2: Install ArgoCD

### What are we installing exactly?
ArgoCD is actually **multiple microservices** packaged together:
- `argocd-server` — the web UI and API you interact with
- `argocd-application-controller` — the brain that syncs Git state to your cluster
- `argocd-repo-server` — fetches your Git repo locally and generates manifests
- `argocd-dex-server` — the SSO connector we need for GitHub login
- `redis` — a tiny in-memory database ArgoCD uses for caching

### Why use Helm?
Without Helm, you'd need to run ~200 lines of raw YAML. Helm is a package manager: one command installs everything.

### Step-by-Step

```bash
# Create the "folder" (namespace) where ArgoCD lives
kubectl create namespace argocd

# Add the ArgoCD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 6.7.3 \
  --set server.replicas=1 \
  --set controller.replicas=1 \
  --set repoServer.replicas=1 \
  --set dex.enabled=true \
  --set notifications.enabled=false \
  --wait
```

### Verify Installation

```bash
# Watch pods come alive
kubectl get pods -n argocd -w
```

**Expected output**:
```
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          2m
argocd-dex-server-xxx                               1/1     Running   0          2m
argocd-redis-xxx                                    1/1     Running   0          2m
argocd-repo-server-xxx                              1/1     Running   0          2m
argocd-server-xxx                                   1/1     Running   0          2m
```

> ✅ All 5 pods should say `1/1 Running`. If any says `Pending` or `CrashLoopBackOff`, the node is too small.

---

## 5. Part 3: Configure SSO with GitHub

### What is SSO and Why Do We Need It?

**Without SSO**: Every user needs a separate password for ArgoCD. You manage users manually. If someone leaves the company, you manually delete their ArgoCD account.

**With SSO**: Users log in with their existing GitHub/company credentials. If they leave the GitHub org, they automatically lose ArgoCD access. Your company controls authentication, ArgoCD controls authorization.

**How it works**:

```
1. User clicks "Login via GitHub" in ArgoCD UI
2. ArgoCD redirects to GitHub
3. User logs into GitHub
4. GitHub says "Yes, this person is authenticated"
5. Dex (inside ArgoCD) receives that message
6. Dex tells ArgoCD: "This is 'john.doe' with teams ['argo-admins']"
7. ArgoCD checks RBAC rules: "argo-admins → role:admin"
8. User sees the Admin UI
```

### Step 3.1: Create a GitHub OAuth App

This tells GitHub: "ArgoCD is allowed to ask you who someone is."

**How to do it (UI steps)**:

1. Go to https://github.com/settings/developers
2. Click **OAuth Apps** on the left
3. Click **New OAuth App**
4. Fill in the form:

| Field | Value |
|-------|-------|
| Application name | `ArgoCD-Demo` |
| Homepage URL | `http://localhost:8080` |
| Application description | `ArgoCD GitOps Dashboard SSO` |
| Authorization callback URL | `http://localhost:8080/api/dex/callback` |

5. Click **Register application**
6. You now see a **Client ID** — copy it
7. Click **Generate a new client secret**
8. You now see a **Client Secret** — copy it (it looks like `gho_xxxxxxxx`)

### Step 3.2: Store the Secret in Kubernetes

We need to store the GitHub client secret securely. Kubernetes `Secret` objects are perfect for this.

```bash
# Replace these with YOUR actual values
export GITHUB_CLIENT_ID="paste-your-client-id-here"
export GITHUB_CLIENT_SECRET="paste-your-client-secret-here"

# Create a K8s secret in the argocd namespace
kubectl create secret generic github-oauth \
  --namespace argocd \
  --from-literal=dex.github.clientSecret="$GITHUB_CLIENT_SECRET"

# Verify it was created
kubectl get secret github-oauth -n argocd
```

### Step 3.3: Configure ArgoCD for GitHub SSO

ArgoCD stores its configuration in a K8s object called `argocd-cm` (ConfigMap). Think of it as ArgoCD's `settings.json` file.

**We need to tell ArgoCD:**
- What URL it lives on (`http://localhost:8080`)
- What Dex connector to use (GitHub OAuth)
- Your GitHub Client ID
- Which K8s Secret has the Client Secret

**CLI Approach:**

```bash
# We patch the configmap with SSO settings
kubectl patch configmap argocd-cm -n argocd --type merge -p '{
  "data": {
    "url": "http://localhost:8080",
    "dex.config": "connectors:\n  - type: github\n    id: github\n    name: GitHub\n    config:\n      clientID: '"$GITHUB_CLIENT_ID"'\n      clientSecret: \$github-oauth:dex.github.clientSecret\n      redirectURI: http://localhost:8080/api/dex/callback\n      loadAllGroups: true"
  }
}'
```


flow

![alt text](image.png)

**Line-by-line explanation of `dex.config`:**

```yaml
connectors:
  - type: github          # Tells Dex: use GitHub OAuth
    id: github            # Internal name for this connector
    name: GitHub          # Name shown on the login button
    config:
      clientID: abc123    # Your GitHub OAuth App's client ID
      clientSecret: $github-oauth:dex.github.clientSecret  # Reference to K8s Secret
      redirectURI: http://localhost:8080/api/dex/callback   # Where GitHub sends users back
      loadAllGroups: true # Ask GitHub what teams the user belongs to (needed for RBAC)
```

**Restart ArgoCD to pick up the new config:**

```bash
kubectl rollout restart deployment argocd-dex-server -n argocd
kubectl rollout restart deployment argocd-server -n argocd

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-dex-server -n argocd --timeout=120s
```

---

## 6. Part 4: Configure RBAC

### What is RBAC and Why Do We Need It?

**RBAC = Role-Based Access Control**

Just because someone can log in (authentication) doesn't mean they should have full access.

| Role | Can Do | Cannot Do |
|------|--------|-----------|
| **Admin** | Everything: create, delete, sync, change settings | Nothing — full power |
| **Developer** | View apps, sync apps, rollback apps | Create/delete apps, change global settings |
| **Readonly** | View apps and read data | Change anything |

### How RBAC Works in ArgoCD

ArgoCD reads a file called `policy.csv` inside a ConfigMap called `argocd-rbac-cm`.

**Format of a policy line:**
```
p, role:developer, applications, sync, */*, allow
├  ├──────────────  ├───────────  ├────  ├───  ├────┤
│  │                │             │      │     └─ Action: allow or deny
│  │                │             │      └─ Resource path: */* = all apps in all projects
│  │                │             └─ Action: sync, get, create, delete, update, override
│  │                └─ Resource type: applications, projects, repositories, certificates
│  └─ Role name: admin, developer, readonly
└─ Policy type: p = policy line, g = group mapping
```

### Step 4.1: Create the RBAC ConfigMap

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly
  policy.csv: |
    # ============================================
    # ADMIN ROLE — Full control over everything
    # Mapped to GitHub team: "argo-admins"
    # ============================================
    p, role:admin, applications, *, */*, allow
    p, role:admin, projects, *, *, allow
    p, role:admin, repositories, *, *, allow
    p, role:admin, certificates, *, *, allow
    p, role:admin, accounts, *, *, allow
    p, role:admin, gpgkeys, *, *, allow
    p, role:admin, exec, create, */*, allow

    # ============================================
    # DEVELOPER ROLE — Can deploy, but cannot create or delete
    # Mapped to GitHub team: "argo-developers"
    # ============================================
    p, role:developer, applications, get, */*, allow
    p, role:developer, applications, sync, */*, allow
    p, role:developer, applications, rollback, */*, allow
    p, role:developer, projects, get, *, allow
    p, role:developer, repositories, get, *, allow
    # Explicit DENY for create/delete/update
    p, role:developer, applications, create, */*, deny
    p, role:developer, applications, delete, */*, deny
    p, role:developer, applications, update, */*, deny

    # ============================================
    # READONLY ROLE — View only, change nothing
    # Default for users not in any team
    # ============================================
    p, role:readonly, applications, get, */*, allow
    p, role:readonly, projects, get, *, allow
    p, role:readonly, repositories, get, *, allow

    # ============================================
    # GROUP MAPPINGS
    # These map GitHub teams → ArgoCD roles
    # ============================================
    g, argo-admins, role:admin
    g, argo-developers, role:developer
EOF
```

**Restart the server to pick up RBAC changes:**

```bash
kubectl rollout restart deployment argocd-server -n argocd
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s
```

### Step 4.2: Create GitHub Teams for Testing

ArgoCD reads what **GitHub Teams** a user belongs to. So we need actual teams on GitHub.

**Option A: GitHub Organization (Best)**

If you're part of a GitHub Organization:
1. Go to `https://github.com/orgs/YOUR_ORG/teams`
2. Click **New Team**
   - Name: `argo-admins`
   - Description: `ArgoCD Administrators`
3. Click **New Team**
   - Name: `argo-developers`
   - Description: `ArgoCD Developers`
4. Add your GitHub account to `argo-admins`
5. Add a colleague/friend's account to `argo-developers`

**Option B: Personal GitHub Account (Fallback)**

If you don't have an org, use your **GitHub username** directly:

```bash
kubectl get configmap argocd-rbac-cm -n argocd -o yaml
```

Edit the `policy.csv` and replace:
```
g, argo-admins, role:admin
g, argo-developers, role:developer
```

With your actual GitHub usernames:
```
g, your-username, role:admin
g, friend-username, role:developer
```

Save and restart the server:
```bash
kubectl rollout restart deployment argocd-server -n argocd
```

---

## 7. Part 5: Expose ArgoCD UI

### Option A: Port-Forward (Recommended for Demo — $0)

**What is port-forwarding?**
It opens a tunnel from your laptop directly into the Kubernetes cluster. It's like a VPN for one specific service. Perfect for demos, costs nothing.

**How to do it:**

```bash
# Open a terminal and run:
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Leave this terminal running!
# The ArgoCD UI is now at: https://localhost:8080
```

**Open your browser and go to:** `https://localhost:8080`

> ⚠️ Your browser will warn about an insecure certificate — that's expected. Click **Advanced → Proceed** (or type `thisisunsafe` on the Chrome warning page).

### Option B: ALB Ingress (Public Access — Costs ~$16/mo)

Only do this if you need to access ArgoCD from outside (e.g., your manager viewing from their laptop).

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF

# Wait 2 minutes for the ALB to be created
sleep 120

# Get the public ALB URL
kubectl get ingress argocd-server-ingress -n argocd \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Result looks like:
# k8s-argocd-argocdserv-1234567890.us-east-1.elb.amazonaws.com
```

---

## 8. Part 6: Test SSO + RBAC

### 8.1 Initial Admin Login (CLI, One-Time Setup)

Before SSO takes over completely, we need the **local admin password** to do initial setup.

```bash
# Get the auto-generated admin password
argocd admin initial-password -n argocd

# Example output:
# xxxxxxxxxxxxxxxx
# (This password will be deleted after first login.)
```

Use this password to log into `https://localhost:8080` as `admin` if needed.

### 8.2 Test 1: Admin User (You)

**What to do:**

1. Open `https://localhost:8080` in your browser
2. You now see a **"LOG IN VIA GITHUB"** button
3. Click it — you get redirected to GitHub
4. Authorize the ArgoCD-Demo app
5. You get redirected back to ArgoCD

**What you should see:**
- Full navigation menu on the left
- **Settings** option visible
- **New App** button visible
- All buttons enabled

**Verify your role:**
1. Click **Settings** (bottom left gear icon)
2. Click **Accounts** on the left
3. Find your GitHub username
4. Under **Role**, it should say **admin**
5. Under **Groups**, it should show your team (`argo-admins`)

### 8.3 Test 2: Developer User (Colleague)

**What to do:**

1. Open an **incognito/private browser window**
2. Go to `https://localhost:8080`
3. Click **"LOG IN VIA GITHUB"**
4. Have your colleague/friend log in with their GitHub account

**What they should see:**
- The same apps listed
- **Sync** button is enabled
- **Settings** is NOT visible (or shows limited options)
- **New App** button is NOT visible

**Test the restriction:**
1. Try to click **New App** — it either doesn't exist or shows `Forbidden`
2. Try to delete an app — it shows `Permission denied`

### 8.4 Test 3: Random GitHub User (Readonly)

**What to do:**

1. Open another incognito window
2. Have someone NOT in any of your teams log in

**What they should see:**
- Apps are visible
- **Sync** button is disabled / greyed out
- **New App** button is not visible
- Everything is read-only

---

## 9. Part 7: Create a Dummy App for RBAC Testing

**Why create a dummy app?**
So you have something concrete to click on during the demo. This app deploys a simple `guestbook` app from ArgoCD's public examples.

### CLI Approach

```bash
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dummy-test-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd-demo-apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```

### UI Approach (How your admin does it)

1. Log in as Admin to `https://localhost:8080`
2. Click **Applications** on the left
3. Click **New App** (top right)
4. Fill in:
   - **Application Name**: `dummy-test-app`
   - **Project**: `default`
   - **Sync Policy**: `Automatic`
   - **Repository URL**: `https://github.com/argoproj/argocd-example-apps.git`
   - **Path**: `guestbook`
   - **Cluster**: `https://kubernetes.default.svc`
   - **Namespace**: `argocd-demo-apps`
5. Click **Create**
6. ArgoCD will auto-sync and turn green

**What different users can do with this app:**

| User Type | Can Sync? | Can Delete? | Can Edit Settings? |
|-----------|-----------|-------------|--------------------|
| **Admin** | ✅ Yes | ✅ Yes | ✅ Yes |
| **Developer** | ✅ Yes | ❌ No (Forbidden) | ❌ No |
| **Readonly** | ❌ No (Greyed out) | ❌ No | ❌ No |

---

## 10. Manager Demo Script

### Scene 0: Open ArgoCD (10 seconds)

> *"This is ArgoCD, our GitOps dashboard. Notice it says 'Authentication Required'. We don't use local passwords — everything goes through SSO."*

### Scene 1: SSO Login as Admin (1 min)

> *"Let me log in. I'll click 'LOG IN VIA GITHUB'."*

1. Click **"LOG IN VIA GITHUB"**
2. Browser redirects to GitHub, auto-logs in
3. Redirects back to ArgoCD
4. **Result**: You're logged in, name and avatar from GitHub shown in top-right

> *"No local password. No manual user management. If someone leaves the company and is removed from GitHub, they automatically lose access here."*

### Scene 2: RBAC for Admin (1 min)

> *"I am part of the 'argo-admins' team on GitHub. Let me verify what permissions I have."*

1. Click **Settings** (gear icon, bottom left)
2. Click **Accounts**
3. Point to your name → shows **Role: admin**, **Groups: argo-admins**

> *"Admin means full control. I can create apps, delete apps, change everything."*

### Scene 3: RBAC for Developer (2 min)

> *"Now let me show what a Developer sees. I'll open an incognito window."*

1. Open incognito, go to `https://localhost:8080`
2. Click **"LOG IN VIA GITHUB"**
3. Colleague logs in (in `argo-developers` team)
4. **Result**: They see the same apps, but:
   - **No "New App" button**
   - **No "Settings" menu**
5. Try to click **Sync** on the app → ✅ Works
6. Try to look for delete option → ❌ Not available

> *"Developers can deploy existing apps but they cannot create or delete anything. This prevents accidental infrastructure changes."*

### Scene 4: RBAC for External User (1 min)

> *"What about someone random with a GitHub account?"*

1. Open another incognito window
2. Random GitHub user logs in
3. **Result**: Apps are visible but **everything is read-only**
4. Sync buttons are greyed out

> *"Anyone with a GitHub account can view, but only authorized teams can make changes."*

---

## 11. Cleanup

### Save Money — Delete the Public Ingress

```bash
kubectl delete ingress argocd-server-ingress -n argocd
# Wait 2-3 minutes for AWS to delete the ALB ($16-20/mo saved)
```

### Keep ArgoCD (Cheap)

ArgoCD + 1 node costs ~$15-20 total per month. You can keep it running.

### Delete Everything (Zero Cost)

```bash
# Delete the demo app
kubectl delete application dummy-test-app -n argocd

# Uninstall ArgoCD completely
helm uninstall argocd -n argocd

# Delete ArgoCD namespace
kubectl delete namespace argocd

# Scale your node group to 0
eksctl scale nodegroup \
  --cluster $CLUSTER_NAME \
  --region $AWS_REGION \
  --name argocd-demo-ng \
  --nodes 0
```

---

## 12. Alternative SSO

When you have a real company IdP, the ONLY file that changes is the `dex.config` inside `argocd-cm`. The RBAC policies (`policy.csv`) stay exactly the same.

### Okta

```yaml
connectors:
  - type: oidc
    id: okta
    name: Okta
    config:
      issuer: https://your-org.okta.com
      clientID: YOUR_CLIENT_ID
      clientSecret: $okta-secret:client-secret
      redirectURI: http://localhost:8080/api/dex/callback
      scopes: [openid, profile, email, groups]
```

### Google Workspace

```yaml
connectors:
  - type: google
    id: google
    name: Google
    config:
      clientID: YOUR_CLIENT_ID
      clientSecret: $google-secret:client-secret
      redirectURI: http://localhost:8080/api/dex/callback
      hostedDomains:
        - yourcompany.com
      scopes:
        - https://www.googleapis.com/auth/userinfo.profile
        - https://www.googleapis.com/auth/userinfo.email
```

### AWS IAM Identity Center (SAML)

Use `type: saml` connector instead. See `ARGOCD_SETUP_AWS_EKS.md` for full SAML setup.

---

## 13. Troubleshooting

| Problem | Why It Happens | How to Fix |
|---------|---------------|------------|
| `Login Failed` after GitHub | The `redirectURI` doesn't match what GitHub expects | Make sure `argocd-cm` URL and GitHub callback URL are identical |
| SSO button disappears | `dex.enabled=false` or Dex pod crashed | Check `kubectl get pods -n argocd` and restart Dex |
| `403 Forbidden` after login | GitHub team name doesn't match `policy.csv` exactly | Check case sensitivity (`argo-admins` vs `Argo-Admins`) |
| Dex crashes on startup | Invalid YAML in `dex.config` | Verify indentation. Use `kubectl logs argocd-dex-server-xxx -n argocd` |
| `Log in via Github` button missing | `url` field missing in `argocd-cm` | Ensure `url: http://localhost:8080` is set |
| Port-forward disconnects | Terminal was closed | Re-run `kubectl port-forward` command |
| Can't access UI at all | Pod not ready | Run `kubectl get pods -n argocd` and wait for `1/1 Running` |

---

## Quick Command Cheat Sheet

```bash
# Port-forward ArgoCD UI (run and leave terminal open)
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get admin password (one-time)
argocd admin initial-password -n argocd

# View ArgoCD config
kubectl get configmap argocd-cm -n argocd -o yaml

# Edit ArgoCD config live
kubectl edit configmap argocd-cm -n argocd

# View RBAC config
kubectl get configmap argocd-rbac-cm -n argocd -o yaml

# Edit RBAC config live
kubectl edit configmap argocd-rbac-cm -n argocd

# Restart server after config changes
kubectl rollout restart deployment argocd-server -n argocd

# View Dex logs (for SSO debugging)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-dex-server --tail=50

# View all ArgoCD pods
kubectl get pods -n argocd
```
