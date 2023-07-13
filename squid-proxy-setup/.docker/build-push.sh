#!/usr/bin/env bash
set -x
SQUID_IMG="${SQUID_IMG:-"nascarsayan/squid-proxy"}"
TAG="${1:-"latest"}"
sudo docker build --no-cache . -t "${SQUID_IMG}:${TAG}"
sudo docker push "${SQUID_IMG}:${TAG}"
set +x
