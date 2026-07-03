#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root (sudo)." >&2
  exit 1
fi

install -d -m 0755 /usr/local/sbin
cat >/usr/local/sbin/podman-docker-forwarding.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
iptables -C DOCKER-USER -i podman0 -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 1 -i podman0 -j ACCEPT
iptables -C DOCKER-USER -o podman0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 2 -o podman0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
EOF
chmod 0755 /usr/local/sbin/podman-docker-forwarding.sh

cat >/etc/systemd/system/podman-docker-forwarding.service <<'EOF'
[Unit]
Description=Allow Podman bridge traffic through Docker forwarding policy
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/podman-docker-forwarding.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now podman-docker-forwarding.service
systemctl status --no-pager podman-docker-forwarding.service

echo "Installed and enabled podman-docker-forwarding.service"
