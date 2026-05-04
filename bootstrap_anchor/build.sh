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
docker build -f Dockerfile.standalone -t rendezvous-server .

echo "Cleaning up..."
rm -rf dart-udx

echo ""
echo "Done! Run with:"
echo "  docker run -p 9514:9514/udp -p 9516:9516/udp -v \$(pwd)/data:/app/data rendezvous-server"
echo ""
echo "On first run, the server generates an Ed25519 keypair and prints its"
echo "public key to stdout. Share this key with agents that should use it."
