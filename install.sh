#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Install only on a clean Ubuntu 24.04 VPS. No server addresses or credentials
# are stored in this repository. The first Home peer and all passwords are new.
AWG_REVISION=930dc6021024db9c8bbda7d92944aa9fef7baf3c
AWG_IMAGE=ghcr.io/alexsemenovru/awg-easy-3@sha256:4a218ff42b401fd84a25c576090a42d52e204d8f3b4fd530ec352021580199ec
HYSTERIA_VERSION=v2.13.0
HYSTERIA_SHA256=907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691
AWG_PORT=443
HYSTERIA_PORT=8443
PANEL_PORT=51821
HYSTERIA_USERS=5
PUBLIC_IP=
NO_WEB=0
STATE_DIR=/opt/vps-install-stack
AWG_DIR=/opt/awg-easy-3-panel
ACCESS_DIR=/root/vps-access
STAGE_DIR=/root/.vps-install-stack-stage

usage() {
  cat <<'EOF'
Usage: sudo bash install.sh [--host PUBLIC_IPV4] [--awg-port UDP_PORT]
                            [--hysteria-port UDP_PORT] [--users COUNT]
                            [--no-web]

Ubuntu 24.04, x86_64. Installs AWG-Easy 3, Hysteria2 and a private panel.
Run on a fresh VPS. Provider firewall must permit both UDP ports, SSH and
optionally TCP/80. Credentials appear only in /root/vps-access after success.
EOF
}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
log() { printf '[stack] %s\n' "$*"; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
valid_ipv4() {
  local part
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$1"
  for part in "${parts[@]}"; do (( 10#$part <= 255 )) || return 1; done
  [[ $1 != 0.0.0.0 && $1 != 255.255.255.255 ]]
}

while (($#)); do
  case "$1" in
    --host|--awg-port|--hysteria-port|--users)
      (($# >= 2)) || die "$1 requires a value"
      case "$1" in
        --host) PUBLIC_IP=$2 ;;
        --awg-port) AWG_PORT=$2 ;;
        --hysteria-port) HYSTERIA_PORT=$2 ;;
        --users) HYSTERIA_USERS=$2 ;;
      esac
      shift 2 ;;
    --no-web) NO_WEB=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $(id -u) == 0 ]] || die 'run as root'
[[ $(uname -m) == x86_64 ]] || die 'x86_64 is required'
# shellcheck disable=SC1091
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || die 'Ubuntu 24.04 is required'
valid_port "$AWG_PORT" || die 'invalid AWG port'
valid_port "$HYSTERIA_PORT" || die 'invalid Hysteria port'
[[ $AWG_PORT != "$HYSTERIA_PORT" ]] || die 'AWG and Hysteria need distinct UDP ports'
[[ $HYSTERIA_USERS =~ ^[0-9]+$ ]] && (( HYSTERIA_USERS <= 20 )) || die 'users must be between 0 and 20'
[[ ! -e $ACCESS_DIR && ! -e $AWG_DIR && ! -e $STATE_DIR ]] || die 'an installation or access directory already exists'
[[ ! -e /etc/awg-easy-3-install-dir && ! -e /etc/hysteria/config.yaml ]] || die 'AWG-Easy or Hysteria already exists'
[[ ! -e /etc/nftables-vps-stack.conf && ! -e /etc/systemd/system/vps-stack-firewall.service ]] || die 'stack firewall already exists'
[[ ! -e /sys/class/net/awg0 ]] || die 'AWG network interface already exists'
command -v ss >/dev/null || die 'iproute2/ss is required on the base image'
ss -H -lun | awk '{print $4}' | grep -Eq ":(${AWG_PORT}|${HYSTERIA_PORT})$" && die 'a requested UDP port is occupied'
[[ $NO_WEB == 1 ]] || { ss -H -ltn | awk '{print $4}' | grep -Eq ':80$' && die 'TCP/80 is occupied; use --no-web'; }
command -v curl >/dev/null || die 'curl is required on the base image; install it or pass --host after installing it'

if [[ -z $PUBLIC_IP ]]; then
  PUBLIC_IP=$(curl -4fsS --max-time 12 https://api.ipify.org) || die 'cannot discover public IPv4; pass --host'
fi
valid_ipv4 "$PUBLIC_IP" || die 'public endpoint must be an IPv4 address'
[[ $PUBLIC_IP != 10.* && $PUBLIC_IP != 192.168.* && $PUBLIC_IP != 172.1[6-9].* && $PUBLIC_IP != 172.2[0-9].* && $PUBLIC_IP != 172.3[01].* ]] || die 'private IPv4 detected; pass the public address'

install -d -m 700 "$STAGE_DIR"
on_error() {
  local status=$?
  printf 'Installation failed (exit %s). Diagnostic files remain in %s (root only).\n' "$status" "$STAGE_DIR" >&2
  printf 'Some services may already be installed. Do not rerun blindly.\n' >&2
}
trap on_error ERR
export DEBIAN_FRONTEND=noninteractive
log 'Installing required packages'
apt-get update -qq > "$STAGE_DIR/apt.log" 2>&1
apt-get install -yq --no-install-recommends ca-certificates curl git openssl nftables nginx python3 docker.io docker-compose-v2 > "$STAGE_DIR/apt.log" 2>&1
systemctl enable --now docker > "$STAGE_DIR/docker.log" 2>&1

log 'Installing pinned AWG-Easy 3'
git clone -q https://github.com/alexsemenovru/awg-easy-3.git "$AWG_DIR" > "$STAGE_DIR/awg-git.log" 2>&1
git -C "$AWG_DIR" checkout -q --detach "$AWG_REVISION"
[[ $(git -C "$AWG_DIR" rev-parse HEAD) == "$AWG_REVISION" ]] || die 'AWG source revision mismatch'
printf 'AWG_IMAGE=%s\n' "$AWG_IMAGE" > "$AWG_DIR/.env"
chmod 600 "$AWG_DIR/.env"
AWG_IMAGE=$AWG_IMAGE AWG_HOST=$PUBLIC_IP AWG_PORT=$AWG_PORT AWG_PANEL_PORT=$PANEL_PORT AWG_LANG=ru \
  bash "$AWG_DIR/install.sh" --host "$PUBLIC_IP" --port "$AWG_PORT" --panel-port "$PANEL_PORT" --lang ru \
  > "$STAGE_DIR/awg-install.log" 2>&1
awg-easy-3 auto-update disable > "$STAGE_DIR/awg-update.log" 2>&1

PANEL_PASSWORD=$(sed -n 's/^Panel password (shown once): //p' "$STAGE_DIR/awg-install.log" | head -n 1)
AWG_LINK=$(sed -n '/^vpn:\/\//{p;q;}' "$STAGE_DIR/awg-install.log")
[[ -n $PANEL_PASSWORD && $AWG_LINK == vpn://* ]] || die 'AWG did not return a panel password and first profile'
[[ $(docker inspect -f '{{.State.Health.Status}}' awg-easy-3) == healthy ]] || die 'AWG container unhealthy'
curl -fsS --max-time 5 -o /dev/null "http://10.8.0.1:${PANEL_PORT}/" || die 'private panel is not responding'

log 'Installing verified Hysteria2 binary and generating new credentials'
curl -fsSL --retry 3 --max-time 120 \
  "https://github.com/HyNetworks/hysteria/releases/download/app/${HYSTERIA_VERSION}/hysteria-linux-amd64" \
  -o "$STAGE_DIR/hysteria-linux-amd64"
printf '%s  %s\n' "$HYSTERIA_SHA256" "$STAGE_DIR/hysteria-linux-amd64" | sha256sum -c - > "$STAGE_DIR/hysteria-sha256.log"
install -m 755 "$STAGE_DIR/hysteria-linux-amd64" /usr/local/bin/hysteria
install -d -m 700 /etc/hysteria
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
  -subj '/CN=www.cloudflare.com' -addext 'subjectAltName=DNS:www.cloudflare.com' > "$STAGE_DIR/cert.log" 2>&1
chmod 600 /etc/hysteria/server.key /etc/hysteria/server.crt
HY2_OBFS=$(openssl rand -hex 32)
HY2_PRIMARY=$(openssl rand -hex 32)
{
  printf 'listen: :%s\n' "$HYSTERIA_PORT"
  printf 'tls:\n  cert: /etc/hysteria/server.crt\n  key: /etc/hysteria/server.key\n'
  printf 'auth:\n  type: userpass\n  userpass:\n    primary: %s\n' "$HY2_PRIMARY"
  for ((i=1; i<=HYSTERIA_USERS; i++)); do
    password=$(openssl rand -hex 32)
    printf '    device-%s: %s\n' "$i" "$password"
    printf '%s\n' "$password" > "$STAGE_DIR/device-${i}.password"
  done
  printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$HY2_OBFS"
  printf 'ignoreClientBandwidth: true\nquic:\n  disablePathMTUDiscovery: true\n  maxIdleTimeout: 60s\n'
  printf 'outbounds:\n  - name: direct\n    type: direct\n'
} > /etc/hysteria/config.yaml
chmod 600 /etc/hysteria/config.yaml
install -d -m 755 /etc/systemd/system/hysteria-server.service.d
printf '[Service]\nEnvironment=QUIC_GO_DISABLE_GSO=1\nEnvironment=QUIC_GO_DISABLE_ECN=1\n' \
  > /etc/systemd/system/hysteria-server.service.d/network-compat.conf
systemctl daemon-reload
cat > /etc/systemd/system/hysteria-server.service <<'EOF'
[Unit]
Description=Hysteria2 server
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now hysteria-server.service > "$STAGE_DIR/hysteria-service.log" 2>&1
for ((attempt=1; attempt<=30; attempt++)); do
  if systemctl is-active --quiet hysteria-server.service &&
    ss -H -lun | awk -v port="$HYSTERIA_PORT" '$4 ~ (":" port "$") { found=1 } END { exit !found }'; then
    break
  fi
  sleep 1
done
systemctl is-active --quiet hysteria-server.service || die 'Hysteria service failed'
ss -H -lun | awk -v port="$HYSTERIA_PORT" '$4 ~ (":" port "$") { found=1 } END { exit !found }' || die 'Hysteria UDP listener missing'

# shellcheck disable=SC1091
source "$(dirname "$(realpath "$0")")/finish.sh"
