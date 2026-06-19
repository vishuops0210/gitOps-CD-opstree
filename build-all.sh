#!/bin/bash
# ============================================================
# Build & Push All Demo Apps + Update GitOps Values
# Usage: ./build-all.sh <dockerhub_username>
# Example: ./build-all.sh johndoe
# ============================================================

set -e

if [ -z "$1" ]; then
  echo "ERROR: Missing Docker Hub username"
  echo "Usage: ./build-all.sh <your-dockerhub-username>"
  echo "Example: ./build-all.sh johndoe"
  exit 1
fi

DH_USER="$1"
REGISTRY="docker.io/$DH_USER"

# If you use AWS ECR instead, set it here:
# REGISTRY="123456789012.dkr.ecr.us-east-1.amazonaws.com"

echo "========================================"
echo "Docker Registry: $REGISTRY"
echo "========================================"

# --- Step 1: Docker Login ---
echo ""
echo "Logging into Docker Hub..."
docker login || { echo "Docker login failed"; exit 1; }

# --- Step 2: Build & Push ---
cd demo-apps

# Build 7 Java apps
for i in $(seq 1 7); do
  echo ""
  echo "========================================"
  echo "Building java-app$i..."
  echo "========================================"
  docker build -t "$REGISTRY/java-app$i:latest" "java-app$i/"
  docker push "$REGISTRY/java-app$i:latest"
done

# Build 2 .NET apps
for i in $(seq 1 2); do
  echo ""
  echo "========================================"
  echo "Building dotnet-app$i..."
  echo "========================================"
  docker build -t "$REGISTRY/dotnet-app$i:latest" "dotnet-app$i/"
  docker push "$REGISTRY/dotnet-app$i:latest"
done

# Build 3 Frontend apps
for i in $(seq 1 3); do
  echo ""
  echo "========================================"
  echo "Building frontend$i..."
  echo "========================================"
  docker build -t "$REGISTRY/frontend$i:latest" "frontend$i/"
  docker push "$REGISTRY/frontend$i:latest"
done

# --- Step 3: Update GitOps Values Files ---
echo ""
echo "========================================"
echo "Updating GitOps values files..."
echo "========================================"

cd "../GitOps Repo"

# Replace myregistry with actual Docker Hub username (full registry path)
for f in applications/*/*-values.yaml; do
  sed -i "s|myregistry/|$REGISTRY/|g" "$f"
done

# Verify
APP1_REPO=$(grep "repository:" applications/app1/dev-values.yaml | head -1 | xargs)
echo "Updated: $APP1_REPO"

echo ""
echo "✅ All 12 images built, pushed, and GitOps values updated!"
echo ""
echo "Next steps:"
echo "  1. git add applications/"
echo "  2. git commit -m 'update image registry'"
echo "  3. git push origin main"
echo "  4. kubectl apply -f argocd/appproject-platform.yaml"
echo "  5. kubectl apply -f argocd/dev/"
