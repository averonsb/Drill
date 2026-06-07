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

ENC_PASS=$(jq -rn --arg x "$HYSTERIA_PASSWORD" '$x|@uri')

URI="hy2://${ENC_PASS}@${DOMAIN}:443/?sni=${DOMAIN}&insecure=0#Hysteria2: ${DOMAIN}"
qrencode -t ANSIUTF8 "$URI"
qrencode -o "qr-hysteria2-${DOMAIN}.png" "$URI"
echo "$URI" > "txt-hysteria2-${DOMAIN}.txt"
