#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVER="${1:-}"
SSH_KEY="${2:-}"

if [[ -z "$SERVER" ]]; then
  echo "Usage:"
  echo "  $0 <server-from-ssh-config-or-ip> [ssh-key-path]"
  echo
  echo "Examples:"
  echo "  $0 srv-alg1"
  echo "  $0 root@xxx.xxx.xxx.xxx ~/.ssh/id_ed25519"
  exit 1
fi

SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
)

if [[ -n "$SSH_KEY" ]]; then
  SSH_OPTS+=(-i "$SSH_KEY")
fi

echo "==> Connecting to $SERVER"
ssh "${SSH_OPTS[@]}" "$SERVER" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  -y upgrade

apt-get \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  -y full-upgrade

apt-get -y autoremove
echo "==> Update & upgrade is done"
echo "==> Rebooting..."

systemctl reboot

REMOTE_SCRIPT

W_TIMER=30
echo "==> Waiting for server to boot for $W_TIMER seconds..."
STEP=$((W_TIMER / 3))

for ((i=3; i>0; i--)); do
    sleep "$STEP"
    echo "==> $((STEP * (i - 1))) seconds left"
done

echo "==> Connecting to $SERVER to copy sshd_conf..."
scp "${SSH_OPTS[@]}" "$SCRIPT_DIR/sshd_config" "$SERVER:/tmp/sshd_config"

echo "==> Connecting to $SERVER"

ssh "${SSH_OPTS[@]}" "$SERVER" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

echo "==> Checking sudo/root access"

if [[ "$EUID" -eq 0 ]]; then
  SUDO=""
else
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: sudo is not installed and current user is not root"
    exit 1
  fi

  if ! sudo -n true 2>/dev/null; then
    echo "ERROR: current user needs passwordless sudo or you must connect as root"
    exit 1
  fi

  SUDO="sudo"
fi

echo "==> Detecting OS"

if [[ ! -r /etc/os-release ]]; then
  echo "ERROR: /etc/os-release not found"
  exit 1
fi

. /etc/os-release

case "${ID}" in
  ubuntu|debian)
    OS_ID="$ID"
    ;;
  *)
    echo "ERROR: unsupported OS: ${ID}. This script supports only Debian/Ubuntu."
    exit 1
    ;;
esac

CODENAME="${VERSION_CODENAME:-}"

if [[ -z "$CODENAME" ]]; then
  echo "ERROR: VERSION_CODENAME not found in /etc/os-release"
  exit 1
fi

ARCH="$(dpkg --print-architecture)"

echo "==> OS: $PRETTY_NAME"
echo "==> Docker repo: $OS_ID $CODENAME $ARCH"

echo "==> Removing conflicting old Docker packages if present"

$SUDO apt-get remove -y \
  docker.io \
  docker-compose \
  docker-compose-v2 \
  docker-doc \
  podman-docker \
  containerd \
  runc \
  2>/dev/null || true

echo "==> Installing prerequisite packages"

$SUDO apt-get update
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  git \
  jq \
  htop \
  nano \
  vim \
  unzip \
  tar \
  rsync \
  net-tools \
  iproute2 \
  dnsutils \
  traceroute \
  tcpdump \
  qrencode

echo "==> Adding Docker official GPG key"

$SUDO install -m 0755 -d /etc/apt/keyrings

curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | \
  $SUDO gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg

$SUDO chmod a+r /etc/apt/keyrings/docker.gpg

echo "==> Adding Docker apt repository"

echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${CODENAME} stable" | \
  $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

echo "==> Installing Docker Engine and Compose plugin"

$SUDO apt-get update
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

echo "==> Enabling Docker service"

$SUDO systemctl enable docker
$SUDO systemctl start docker

echo "==> Adding current user to docker group if not root"

REMOTE_USER="$(id -un)"

if [[ "$REMOTE_USER" != "root" ]]; then
  $SUDO usermod -aG docker "$REMOTE_USER"
  echo "==> User '$REMOTE_USER' added to docker group"
  echo "==> You need to reconnect SSH session for docker group membership to apply"
fi

echo "==> Docker version"
$SUDO docker version

echo "==> Docker Compose version"
$SUDO docker compose version

echo "==> Running test container"
$SUDO docker run --rm hello-world >/dev/null

echo "==> Configuring baseline nftables firewall"

$SUDO systemctl enable nftables

# Do not flush the whole nftables ruleset here:
# Docker and other services may own their own tables/chains.
$SUDO nft -f - <<'NFT_RULES'
add table inet host_filter
flush table inet host_filter
NFT_RULES

$SUDO nft -f - <<'NFT_RULES'
table inet host_filter {
  chain input {
    type filter hook input priority filter; policy drop;

    iifname "lo" accept
    ct state established,related accept
    ct state invalid drop

    # SSH
    tcp dport 22 accept
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }

  chain forward {
    type filter hook forward priority filter; policy accept;
  }
}
NFT_RULES

$SUDO nft list table inet host_filter > /etc/nftables.conf 
$SUDO systemctl enable nftables

echo "==> Firewall baseline enabled: inbound default deny, SSH/22 allowed"

echo "==> Configuring sysctl"

cat >/etc/sysctl.d/99-host.conf <<'EOF'

net.ipv4.ip_forward = 1

# Disable IPv6 completely
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

$SUDO sysctl --system

echo "==> Installing sshd_config"

$SUDO sshd -t -f /tmp/sshd_config
$SUDO mv /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
$SUDO cp /tmp/sshd_config /etc/ssh/sshd_config
$SUDO systemctl restart ssh

echo
echo "SUCCESS: Docker, utilities, and baseline firewall installed"
REMOTE_SCRIPT
