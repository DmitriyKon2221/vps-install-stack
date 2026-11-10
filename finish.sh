#!/usr/bin/env bash
# Shared finalization. Source only from install.sh or resume.sh.
if [[ $NO_WEB == 0 ]]; then
  log 'Installing an ordinary HTTP status page'
  install -d -m 755 /var/www/vps-stack
  install -m 644 "$(dirname "$(realpath "$0")")/assets/index.html" /var/www/vps-stack/index.html
  cat > /etc/nginx/sites-available/vps-stack <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/vps-stack;
    index index.html;
    server_tokens off;
    location / { try_files $uri $uri/ =404; }
}
EOF
  rm -f /etc/nginx/sites-enabled/default
  ln -s /etc/nginx/sites-available/vps-stack /etc/nginx/sites-enabled/vps-stack
  nginx -t > "$STAGE_DIR/nginx.log" 2>&1
  systemctl enable --now nginx > "$STAGE_DIR/nginx.log" 2>&1
  systemctl reload nginx
fi

log 'Applying persistent ingress firewall'
cat > /etc/nftables-vps-stack.conf <<EOF
table inet vps_stack_guard {
  chain input {
    type filter hook input priority -5; policy drop;
    ct state invalid drop
    ct state established,related accept
    iifname "lo" accept
    iifname "awg0" tcp dport $PANEL_PORT ip saddr != 10.8.0.2 drop
    iifname "awg0" accept
    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept
    udp sport 67 udp dport 68 accept
    udp sport 547 udp dport 546 accept
    tcp dport 22 accept
    $( [[ $NO_WEB == 0 ]] && printf 'tcp dport 80 accept' )
    udp dport { $AWG_PORT, $HYSTERIA_PORT } accept
  }
  chain forward {
    type filter hook forward priority -5; policy accept;
    iifname "awg0" tcp dport { 25, 465, 587 } reject with tcp reset
  }
  chain output {
    type filter hook output priority -5; policy accept;
    tcp dport { 25, 465, 587 } reject with tcp reset
  }
}
EOF
nft -c -f /etc/nftables-vps-stack.conf > "$STAGE_DIR/firewall.log" 2>&1
cat > /etc/systemd/system/vps-stack-firewall.service <<'EOF'
[Unit]
Description=VPN stack ingress firewall
After=network.target docker.service
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/nft delete table inet vps_stack_guard
ExecStart=/usr/sbin/nft -f /etc/nftables-vps-stack.conf
ExecReload=/bin/sh -c '/usr/sbin/nft delete table inet vps_stack_guard 2>/dev/null || true; /usr/sbin/nft -f /etc/nftables-vps-stack.conf'
ExecStop=-/usr/sbin/nft delete table inet vps_stack_guard

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now vps-stack-firewall.service > "$STAGE_DIR/firewall-service.log" 2>&1

[[ $(docker inspect -f '{{.State.Health.Status}}' awg-easy-3) == healthy ]] || die 'AWG health check failed after firewall'
systemctl is-active --quiet hysteria-server.service || die 'Hysteria health check failed after firewall'
systemctl is-active --quiet vps-stack-firewall.service || die 'firewall service failed'
curl -fsS --max-time 5 -o /dev/null "http://10.8.0.1:${PANEL_PORT}/" || die 'panel health check failed after firewall'
[[ $NO_WEB == 1 ]] || curl -fsS --max-time 5 -o /dev/null http://127.0.0.1/ || die 'HTTP page failed'

HY2_PIN=$(openssl x509 -in /etc/hysteria/server.crt -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
[[ $HY2_PIN =~ ^[0-9a-f]{64}$ ]] || die 'invalid certificate fingerprint'
BASE="@${PUBLIC_IP}:${HYSTERIA_PORT}/?insecure=1&sni=www.cloudflare.com&obfs=salamander&obfs-password=${HY2_OBFS}&pinSHA256=${HY2_PIN}"

# Publish access files atomically only after every local health check passes.
install -d -m 700 "$STAGE_DIR/access"
printf 'Panel: http://10.8.0.1:%s/\nPassword: %s\nAWG endpoint: %s:%s/udp\n' \
  "$PANEL_PORT" "$PANEL_PASSWORD" "$PUBLIC_IP" "$AWG_PORT" > "$STAGE_DIR/access/panel.txt"
printf '%s\n' "$AWG_LINK" > "$STAGE_DIR/access/awg-admin.txt"
printf 'hysteria2://primary:%s%s#HY2-PRIMARY\n' "$HY2_PRIMARY" "$BASE" > "$STAGE_DIR/access/hysteria-primary.txt"
: > "$STAGE_DIR/access/hysteria-users.txt"
for ((i=1; i<=HYSTERIA_USERS; i++)); do
  password=$(<"$STAGE_DIR/device-${i}.password")
  printf 'hysteria2://device-%s:%s%s#HY2-%s\n' "$i" "$password" "$BASE" "$i" \
    >> "$STAGE_DIR/access/hysteria-users.txt"
done
printf 'Public IPv4: %s\nAWG: UDP/%s\nHysteria2: UDP/%s\nPanel: http://10.8.0.1:%s/\n' \
  "$PUBLIC_IP" "$AWG_PORT" "$HYSTERIA_PORT" "$PANEL_PORT" > "$STAGE_DIR/access/server.txt"
chmod 600 "$STAGE_DIR/access/"*.txt
mv "$STAGE_DIR/access" "$ACCESS_DIR"
install -d -m 700 "$STATE_DIR"
printf 'AWG revision: %s\nAWG image: %s\nHysteria version: %s\nHysteria SHA-256: %s\n' \
  "$AWG_REVISION" "$AWG_IMAGE" "$HYSTERIA_VERSION" "$HYSTERIA_SHA256" > "$STATE_DIR/versions.txt"
chmod 600 "$STATE_DIR/versions.txt"
rm -f "$STAGE_DIR/"*.password "$STAGE_DIR/awg-install.log"
trap - ERR
log "Installation succeeded. Read credentials with: sudo ls -la ${ACCESS_DIR}"
log 'Copy only the needed client profile to each device. Keep the access directory private.'
