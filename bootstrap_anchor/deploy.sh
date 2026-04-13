#!/bin/bash
#
# Deploy the Bitchat Bootstrap Anchor to GCP.
#
# Prerequisites:
#   - gcloud CLI installed and authenticated
#   - Docker installed
#   - A GCP project with Artifact Registry and Compute Engine enabled
#
# Usage:
#   ./deploy.sh <ANCHOR_SEED_HEX> <OWNER_PUBKEY_HEX> [PROJECT_ID] [REGION] [ZONE]
#
# The anchor seed is derived from the owner's key on the mobile device:
#   anchorSeed = SHA-256(ownerSeed || "bitchat-anchor")
# Export it once and deploy it here.
#
# The script:
#   1. Builds and pushes the Docker image to Artifact Registry
#   2. Creates a GCE VM with IPv6 and the container
#   3. Opens UDP port 9514 in the firewall

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: ./deploy.sh <ANCHOR_SEED_HEX> <OWNER_PUBKEY_HEX> [PROJECT_ID] [REGION] [ZONE]"
  echo ""
  echo "ANCHOR_SEED_HEX:  64-char hex (32 bytes). Derived from owner's key:"
  echo "                  SHA-256(ownerSeed || \"bitchat-anchor\")"
  echo "OWNER_PUBKEY_HEX: 64-char hex public key of the anchor's owner."
  exit 1
fi

ANCHOR_SEED="${1}"
OWNER_PUBKEY="${2}"
PROJECT_ID="${3:-bitchat-anchor}"
REGION="${4:-us-central1}"
ZONE="${5:-us-central1-a}"
IMAGE_NAME="bootstrap-anchor"
VM_NAME="bitchat-anchor"
REPO_NAME="bitchat"
PORT=9514

if [ ${#ANCHOR_SEED} -ne 64 ]; then
  echo "Error: ANCHOR_SEED_HEX must be exactly 64 hex characters (32 bytes)"
  exit 1
fi

if [ ${#OWNER_PUBKEY} -ne 64 ]; then
  echo "Error: OWNER_PUBKEY_HEX must be exactly 64 hex characters"
  exit 1
fi

echo "=== Bitchat Bootstrap Anchor Deployment ==="
echo "Owner:   ${OWNER_PUBKEY:0:16}..."
echo "Seed:    ${ANCHOR_SEED:0:16}..."
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Zone:    $ZONE"
echo ""

# 1. Create Artifact Registry repo (if not exists)
echo "--- Creating Artifact Registry repo ---"
gcloud artifacts repositories create "$REPO_NAME" \
  --repository-format=docker \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --quiet 2>/dev/null || echo "Repo already exists"

# 2. Build Docker image
echo "--- Building Docker image ---"
cd "$(dirname "$0")/.."
docker build \
  -f bootstrap_anchor/Dockerfile \
  -t "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:latest" \
  .

# 3. Push to Artifact Registry
echo "--- Pushing image ---"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker push "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:latest"

# 4. Create firewall rule for UDP
echo "--- Creating firewall rule ---"
gcloud compute firewall-rules create allow-bitchat-udp \
  --project="$PROJECT_ID" \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=udp:${PORT} \
  --source-ranges=0.0.0.0/0,::/0 \
  --target-tags=bitchat-anchor \
  --quiet 2>/dev/null || echo "Firewall rule already exists"

# 5. Create VM with IPv6
echo "--- Creating VM ---"
gcloud compute instances create-with-container "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --machine-type=e2-micro \
  --tags=bitchat-anchor \
  --stack-type=IPV4_IPV6 \
  --container-image="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:latest" \
  --container-arg="--port" --container-arg="$PORT" \
  --container-arg="--seed" --container-arg="$ANCHOR_SEED" \
  --container-arg="--owner" --container-arg="$OWNER_PUBKEY" \
  --container-arg="--friends" --container-arg="/app/data/friends.json" \
  --container-mount-disk=mount-path=/app/data \
  --boot-disk-size=10GB \
  --metadata=google-logging-enabled=true \
  --quiet 2>/dev/null || {
    echo "VM already exists, updating container..."
    gcloud compute instances update-container "$VM_NAME" \
      --project="$PROJECT_ID" \
      --zone="$ZONE" \
      --container-image="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:latest" \
      --container-arg="--port" --container-arg="$PORT" \
      --container-arg="--seed" --container-arg="$ANCHOR_SEED" \
      --container-arg="--owner" --container-arg="$OWNER_PUBKEY" \
      --container-arg="--friends" --container-arg="/app/data/friends.json" \
      --quiet
  }

# 6. Report
echo ""
echo "--- Deployment complete ---"
echo ""
gcloud compute instances describe "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)' | {
  read -r IPV4
  echo "VM IPv4: $IPV4"
}
gcloud compute instances describe "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --format='get(networkInterfaces[0].ipv6AccessConfigs[0].externalIpv6)' 2>/dev/null | {
  read -r IPV6
  echo "VM IPv6: $IPV6"
  echo ""
  echo "Anchor address (for clients): [$IPV6]:$PORT"
}
echo ""
echo "Next steps:"
echo "  1. On your phone, go to Settings → Anchor Server"
echo "  2. Enter the anchor address shown above"
echo "  3. Save — the server's identity is derived from your key automatically"
echo "  4. Your friend list will sync to the anchor on first connect"
