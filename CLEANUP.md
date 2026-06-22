# ArgoCD GCE Ingress — Cleanup Commands

> Delete everything in this order. **Order matters** — Google won't let you delete a subnet if a load balancer still uses it.

---

## Step 1: Delete ArgoCD (卸载 ArgoCD)

```bash
# Deletes ArgoCD + Ingress + Service + everything inside namespace
helm uninstall argocd -n argocd

# Delete namespace (catches anything leftover)
kubectl delete namespace argocd
```

> ⚠️ Wait 2 minutes after this. Google needs time to clean up load balancer resources.

---

## Step 2: Delete GCP Firewall Rules

```bash
gcloud compute firewall-rules delete allow-proxy-to-argocd --quiet
gcloud compute firewall-rules delete allow-gcp-health-checks --quiet
```

---

## Step 3: Delete Proxy-Only Subnet

```bash
gcloud compute networks subnets delete argocd-proxy-subnet --region=asia-south1 --quiet
```

---

## Step 4: Delete Static IP

```bash
gcloud compute addresses delete argocd-internal-ip --region=asia-south1 --quiet
```

---

## Step 5: Delete SSL Certificate

```bash
gcloud compute ssl-certificates delete argocd-selfsigned-cert --region=asia-south1 --quiet
```

---

## Step 6: Delete GKE Cluster

```bash
gcloud container clusters delete argocd-cluster --zone=asia-south1-a --quiet
```

---

## Step 7: Clean Up Local Files

```bash
rm -f argocd-values.yaml nginx-values.yaml argocd-backendconfig.yaml argocd-frontendconfig.yaml argocd-cm-patch.yaml argocd-rbac.yaml
rm -rf certs/
```

---

## Verify Everything Is Gone

```bash
# Check firewall rules
gcloud compute firewall-rules list --filter="name~allow-proxy OR name~allow-gcp"

# Check proxy subnet
gcloud compute networks subnets list --filter="purpose=REGIONAL_MANAGED_PROXY"

# Check static IP
gcloud compute addresses list --region=asia-south1 --filter="name=argocd-internal-ip"

# Check SSL cert
gcloud compute ssl-certificates list --region=asia-south1 --filter="name=argocd-selfsigned-cert"

# Check cluster
gcloud container clusters list --filter="name=argocd-cluster"
```

All of the above should return **empty** or `(no items found)`

---

## ⚠️ If Orphaned GCP Resources Remain

Sometimes the Ingress controller fails to clean up. If you still see forwarding rules / backend services after deleting ArgoCD:

```bash
# List what might be leftover
gcloud compute forwarding-rules list --region=asia-south1 --filter="name ~ k8s.*argocd"

# Delete manually (replace NAME with actual rule names)
gcloud compute forwarding-rules delete NAME --region=asia-south1 --quiet
gcloud compute backend-services delete NAME --region=asia-south1 --quiet
gcloud compute target-https-proxies list --region=asia-south1 | grep argocd
gcloud compute url-maps list --region=asia-south1 | grep argocd
```

> ⚠️ Only delete names matching `k8s-` prefix that are related to ArgoCD. Don't delete resources from your other apps.
