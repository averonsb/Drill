#!/usr/bin/env bash
set -euo pipefail

if [ ! -f .env ]; then
  echo "ERROR: .env file not found"
  exit 1
fi

if [ ! -f hysteria.yaml.template ]; then
  echo "ERROR: hysteria.yaml.template file not found"
  exit 1
fi

set -a
source .env
set +a

envsubst < hysteria.yaml.template > hysteria.yaml

docker compose up -d
