#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Continue only an installation interrupted after Hysteria was configured.
# The original stage files and server config are used; no VPN keys are replaced.
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
log() { printf '[stack] %s\n' "$*"; }
[[ $(id -u) == 0 ]] || die 'run as root'
[[ $# == 0 ]] || die 'resume.sh takes no arguments; it supports the default ports only'

STAGE_DIR=/root/.vps-install-stack-stage
ACCESS_DIR=/root/vps-access
STATE_DIR=/opt/vps-install-stack
AWG_DIR=/opt/awg-easy-3-panel
AWG_PORT=443
HYSTERIA_PORT=8443
PANEL_PORT=51821
NO_WEB=0
AWG_REVISION=930dc6021024db9c8bbda7d92944aa9fef7baf3c
AWG_IMAGE=ghcr.io/alexsemenovru/awg-easy-3@sha256:4a218ff42b401fd84a25c576090a42d52e204d8f3b4fd530ec352021580199ec
HYSTERIA_VERSION=v2.13.0
HYSTERIA_SHA256=907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691

[[ -d $STAGE_DIR && -f $STAGE_DIR/awg-install.log ]] || die 'original stage files missing'
[[ -f /etc/hysteria/config.yaml && -f /etc/hysteria/server.crt ]] || die 'Hysteria config missing'
[[ -d $AWG_DIR && ! -e $ACCESS_DIR && ! -e $STATE_DIR ]] || die 'unexpected install state; inspect before resuming'
[[ ! -e /etc/nftables-vps-stack.conf && ! -e /etc/systemd/system/vps-stack-firewall.service ]] || die 'firewall stage already started; inspect before resuming'
[[ ! -e /etc/nginx/sites-available/vps-stack ]] || die 'web stage already started; inspect before resuming'
[[ -n ${SSH_CONNECTION:-} && ${SSH_CONNECTION##* } == 22 ]] || die 'run from an SSH session connected to port 22; firewall permits TCP/22'
[[ $(sed -n '1p' /etc/hysteria/config.yaml) == "listen: :${HYSTERIA_PORT}" ]] || die 'unexpected Hysteria port'
[[ $(docker inspect -f '{{.State.Health.Status}}' awg-easy-3) == healthy ]] || die 'AWG container unhealthy'
systemctl is-active --quiet hysteria-server.service || die 'Hysteria service inactive'
ss -H -lun | awk -v port="$HYSTERIA_PORT" '$4 ~ (":" port "$") { found=1 } END { exit !found }' || die 'Hysteria UDP listener missing'
curl -fsS --max-time 5 -o /dev/null "http://10.8.0.1:${PANEL_PORT}/" || die 'private panel not responding'

PANEL_PASSWORD=$(sed -n 's/^Panel password (shown once): //p' "$STAGE_DIR/awg-install.log" | head -n 1)
AWG_LINK=$(sed -n '/^vpn:\/\//{p;q;}' "$STAGE_DIR/awg-install.log")
[[ -n $PANEL_PASSWORD && $AWG_LINK == vpn://* ]] || die 'original AWG credentials missing; stop here to avoid losing access'
HY2_PRIMARY=$(awk '$1 == "primary:" {print $2; exit}' /etc/hysteria/config.yaml)
HY2_OBFS=$(awk '$1 == "obfs:" {found=1; next} found && $1 == "password:" {print $2; exit}' /etc/hysteria/config.yaml)
[[ $HY2_PRIMARY =~ ^[0-9a-f]{64}$ && $HY2_OBFS =~ ^[0-9a-f]{64}$ ]] || die 'Hysteria credentials invalid'

HYSTERIA_USERS=5
for ((i=1; i<=HYSTERIA_USERS; i++)); do
  [[ -f $STAGE_DIR/device-${i}.password ]] || die "device-${i} password missing"
  password=$(<"$STAGE_DIR/device-${i}.password")
  [[ $password =~ ^[0-9a-f]{64}$ ]] || die "device-${i} password invalid"
done

PUBLIC_IP=$(curl -4fsS --max-time 12 https://api.ipify.org) || die 'cannot discover public IPv4'
[[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'invalid public IPv4'
log 'Completing web, firewall and private access files without replacing VPN keys'
# shellcheck disable=SC1091
source "$(dirname "$(realpath "$0")")/finish.sh"
