#!/bin/bash
#
# Build the Docker image locally.
#
# Usage: ./build.sh

set -euo pipefail

cd "$(dirname "$0")"

echo "Copying dart-udx into build context..."
rm -rf dart-udx
cp -r ../dart-udx ./dart-udx

echo "Building Docker image..."
docker build -f Dockerfile.standalone -t bootstrap-anchor .

echo "Cleaning up..."
rm -rf dart-udx

echo ""
echo "Done! Run with:"
echo "  docker run -p 9514:9514/udp -v \$(pwd)/data:/app/data bootstrap-anchor \\"
echo "    --seed <ANCHOR_SEED_HEX> --owner <OWNER_PUBKEY_HEX>"
