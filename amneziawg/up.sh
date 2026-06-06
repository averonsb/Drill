#!/usr/bin/env bash
set -e

# Checking if amneziawg kernel module already in the system and building it if not
if ! modinfo "amneziawg" >/dev/null 2>&1; then
	apt update
	apt install -y ca-certificates curl gnupg dkms linux-headers-$(uname -r)

	gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 57290828
	gpg --export 57290828 | gpg --dearmor -o /usr/share/keyrings/amnezia-ppa.gpg

	apt update
	cat > /etc/apt/sources.list.d/amneziawg.list <<'EOF'
	deb [signed-by=/usr/share/keyrings/amnezia-ppa.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
	deb-src [signed-by=/usr/share/keyrings/amnezia-ppa.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
EOF

	apt update
	apt install -y amneziawg
fi

cd "$(dirname "$0")"

set -a
source .env
set +a

modprobe amneziawg || true

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.src_valid_mark=1

export WG_HOST=$(curl -4 -s https://api.ipify.org)
export INIT_HOST="$WG_HOST"

if [ -z "${INIT_PASSWORD:-}" ]; then
    read -rsp "Enter admin password: " INIT_PASSWORD
    echo
    export INIT_PASSWORD
fi

nft add rule inet host_filter input udp dport "$WG_PORT" accept
nft list ruleset > /etc/nftables.conf

docker compose up -d
