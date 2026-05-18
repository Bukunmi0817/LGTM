#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# fix_monitor_part4.sh
# Run from repo root. Does three things:
#   1. Creates scripts/install-pushgateway.sh
#   2. Patches terraform/main.tf to run it during bootstrap
#   3. Patches .github/workflows/deploy.yml to push metrics to the
#      monitoring server instead of the app server
# ─────────────────────────────────────────────────────────────────────────────
set -e
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  Part 4 — monitoring server architecture fix                 │"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 1. scripts/install-pushgateway.sh
#    Runs on the monitoring server during terraform bootstrap.
#    Follows the same Nemeth-principle style as lgtm-stack.sh.
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [1/3] scripts/install-pushgateway.sh"
cat > scripts/install-pushgateway.sh << 'EOF'
#!/usr/bin/env bash
# =============================================================================
# Pushgateway installer — runs as part of LGTM monitoring server bootstrap.
# Prometheus Pushgateway receives DORA metrics pushed from GitHub Actions
# and exposes them on :9091 for Prometheus to scrape.
#
# Follows the Nemeth principle: install, verify, then move on.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; BLD='\033[1m'; RST='\033[0m'
ok()   { echo -e "${GRN}[OK]${RST}    $*"; }
info() { echo -e "[INFO]  $*"; }
fail() { echo -e "${RED}[FAIL]${RST}  $*"; exit 1; }

[[ "$EUID" -ne 0 ]] && fail "Run as root: sudo bash $0"

PUSHGATEWAY_VERSION="1.9.0"
ARCH=$(uname -m)
[[ "$ARCH" == "aarch64" ]] && GOARCH="arm64" || GOARCH="amd64"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Create data directory ─────────────────────────────────────────────────────
info "Creating Pushgateway data directory..."
mkdir -p /var/lib/pushgateway
# Prometheus user already exists from lgtm-stack.sh — reuse it
chown prometheus:prometheus /var/lib/pushgateway
chmod 750 /var/lib/pushgateway
ok "Directory: /var/lib/pushgateway (prometheus:prometheus, 750)"

# ── Download and install binary ───────────────────────────────────────────────
info "Downloading Pushgateway ${PUSHGATEWAY_VERSION}..."
URL="https://github.com/prometheus/pushgateway/releases/download/v${PUSHGATEWAY_VERSION}/pushgateway-${PUSHGATEWAY_VERSION}.linux-${GOARCH}.tar.gz"
wget -q --show-progress --tries=3 --timeout=60 -O "${TMP}/pushgateway.tar.gz" "$URL"
ok "Downloaded: pushgateway-${PUSHGATEWAY_VERSION}.linux-${GOARCH}.tar.gz"

tar -xzf "${TMP}/pushgateway.tar.gz" -C "$TMP" --strip-components=1
cp "${TMP}/pushgateway" /usr/local/bin/pushgateway
chown root:root /usr/local/bin/pushgateway
chmod 755       /usr/local/bin/pushgateway
ok "Binary installed: /usr/local/bin/pushgateway"

# Verify
ACTUAL_VER=$(/usr/local/bin/pushgateway --version 2>&1 | head -1)
if echo "$ACTUAL_VER" | grep -q "$PUSHGATEWAY_VERSION"; then
  ok "Version confirmed: $ACTUAL_VER"
else
  info "Version string: $ACTUAL_VER (may still be valid)"
fi

# ── Write systemd unit ────────────────────────────────────────────────────────
info "Writing systemd unit file..."
cat > /etc/systemd/system/pushgateway.service << 'UNIT'
[Unit]
Description=Prometheus Pushgateway
Documentation=https://github.com/prometheus/pushgateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/pushgateway \
  --web.listen-address=0.0.0.0:9091 \
  --persistence.file=/var/lib/pushgateway/metrics.db \
  --persistence.interval=5m \
  --log.level=info
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/pushgateway

[Install]
WantedBy=multi-user.target
UNIT

chown root:root /etc/systemd/system/pushgateway.service
chmod 644       /etc/systemd/system/pushgateway.service
ok "Unit written: /etc/systemd/system/pushgateway.service"

# Note: listen on 0.0.0.0 not 127.0.0.1 because GitHub Actions will push
# from outside the server. Port 9091 is controlled by the security group.

# ── Enable and start ──────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable pushgateway
systemctl start pushgateway
ok "Pushgateway enabled and started"

# ── Health check ──────────────────────────────────────────────────────────────
info "Waiting for Pushgateway to be healthy..."
for i in {1..15}; do
  if curl -sf http://localhost:9091/metrics -o /dev/null; then
    ok "Pushgateway healthy at :9091 (took $((i*2))s)"
    break
  fi
  sleep 2
  [[ "$i" -eq 15 ]] && fail "Pushgateway did not become healthy after 30s — check: journalctl -u pushgateway -n 30"
done

# ── Add to Prometheus scrape config ──────────────────────────────────────────
PROM_CONF=/etc/lgtm/prometheus/prometheus.yml
if grep -q '"pushgateway"' "$PROM_CONF" 2>/dev/null; then
  ok "Prometheus scrape config: pushgateway job already present"
else
  info "Adding pushgateway scrape job to $PROM_CONF..."
  cat >> "$PROM_CONF" << 'SCRAPE'

  # ── Pushgateway — receives DORA metrics pushed from GitHub Actions ───────
  - job_name: "pushgateway"
    honor_labels: true
    scrape_interval: 15s
    static_configs:
      - targets: ["127.0.0.1:9091"]
        labels:
          environment: "production"
SCRAPE
  ok "Pushgateway scrape job added to prometheus.yml"

  # Reload Prometheus config (it must already be running)
  if curl -sf -X POST http://127.0.0.1:9090/-/reload; then
    ok "Prometheus config reloaded — pushgateway target active"
  else
    info "Could not reload Prometheus yet — it will pick up the config on next start"
  fi
fi

# ── Add to lgtm-health script ─────────────────────────────────────────────────
HEALTH_SCRIPT=/usr/local/bin/lgtm-health
if [[ -f "$HEALTH_SCRIPT" ]] && ! grep -q "pushgateway" "$HEALTH_SCRIPT"; then
  info "Adding pushgateway to lgtm-health check script..."
  sed -i '/check "grafana"/a check "pushgateway"     "http://127.0.0.1:9091/metrics"' "$HEALTH_SCRIPT"
  ok "pushgateway added to lgtm-health"
fi

echo ""
echo -e "${GRN}${BLD}✓ Pushgateway ${PUSHGATEWAY_VERSION} installed and running on :9091${RST}"
echo ""
echo "  Test with:"
echo "    curl http://localhost:9091/metrics | head -5"
echo ""
echo "  Push a test metric:"
echo "    echo 'test_metric 1' | curl -s --data-binary @- http://localhost:9091/metrics/job/test"
echo ""
EOF

chmod +x scripts/install-pushgateway.sh
echo "  ✅ created"

# ─────────────────────────────────────────────────────────────────────────────
# 2. terraform/main.tf — add file upload + remote-exec for Pushgateway
#    Inserted after the existing bootstrap null_resource closes.
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [2/3] terraform/main.tf (add Pushgateway provisioner)"

cat > /tmp/old_tf.txt << 'EOF'
      "chmod +x /tmp/lgtm-stack.sh",
      "sudo bash /tmp/lgtm-stack.sh",
      "rm -f /tmp/lgtm-stack.sh"
    ]
  }
}
EOF

cat > /tmp/new_tf.txt << 'EOF'
      "chmod +x /tmp/lgtm-stack.sh",
      "sudo bash /tmp/lgtm-stack.sh",
      "rm -f /tmp/lgtm-stack.sh"
    ]
  }

  # ── Pushgateway: receives DORA metrics pushed from GitHub Actions ──────────
  # Installed separately so lgtm-stack.sh does not need modification.
  # Runs after the main stack is up so Prometheus can be reloaded immediately.
  provisioner "file" {
    source      = "../scripts/install-pushgateway.sh"
    destination = "/tmp/install-pushgateway.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/install-pushgateway.sh",
      "sudo bash /tmp/install-pushgateway.sh",
      "rm -f /tmp/install-pushgateway.sh"
    ]
  }
}
EOF

python3 - << 'PYEOF'
old = open('/tmp/old_tf.txt').read().rstrip('\n')
new = open('/tmp/new_tf.txt').read().rstrip('\n')
f   = 'terraform/main.tf'
c   = open(f).read()
if old in c:
    open(f, 'w').write(c.replace(old, new, 1))
    print("  ✅ Pushgateway provisioner added to main.tf")
elif "install-pushgateway" in c:
    print("  ⏭  already applied")
else:
    print("  ❌ patch target not found — add manually")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# 3. .github/workflows/deploy.yml
#    Three changes:
#    a) Add monitoring server SSH key setup step
#    b) Change the metrics push SSH target from app server → monitoring server
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [3/3] .github/workflows/deploy.yml (point metrics push at monitoring server)"

# Patch 3a — add monitoring server key setup after the existing SSH key setup step
cat > /tmp/old_3a.txt << 'EOF'
      - name: Set up SSH key
        if: ${{ vars.DEPLOY_ENABLED == 'true' }}
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.SSH_PRIVATE_KEY }}" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          ssh-keyscan -H ${{ secrets.SERVER_IP }} >> ~/.ssh/known_hosts
EOF

cat > /tmp/new_3a.txt << 'EOF'
      - name: Set up SSH key
        if: ${{ vars.DEPLOY_ENABLED == 'true' }}
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.SSH_PRIVATE_KEY }}" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          ssh-keyscan -H ${{ secrets.SERVER_IP }} >> ~/.ssh/known_hosts

      # Monitoring server key — used to push DORA metrics to Pushgateway.
      # MONITOR_SSH_KEY is the private key whose public key was passed to
      # Terraform as ssh_public_key_path when the monitoring server was provisioned.
      - name: Set up monitoring server SSH key
        if: ${{ vars.DEPLOY_ENABLED == 'true' }}
        run: |
          echo "${{ secrets.MONITOR_SSH_KEY }}" > ~/.ssh/monitor_key
          chmod 600 ~/.ssh/monitor_key
          ssh-keyscan -H ${{ secrets.MONITOR_SERVER_IP }} >> ~/.ssh/known_hosts
EOF

python3 - << 'PYEOF'
old = open('/tmp/old_3a.txt').read().rstrip('\n')
new = open('/tmp/new_3a.txt').read().rstrip('\n')
f   = '.github/workflows/deploy.yml'
c   = open(f).read()
if old in c:
    open(f, 'w').write(c.replace(old, new, 1))
    print("  ✅ 3a: monitoring server key setup step added")
elif "monitor_key" in c:
    print("  ⏭  3a: already applied")
else:
    print("  ❌ 3a: patch target not found — apply manually")
PYEOF

# Patch 3b — change the metrics push SSH target from app server to monitoring server
cat > /tmp/old_3b.txt << 'EOF'
          # Upload both files and push to Pushgateway on the server
          scp -i ~/.ssh/deploy_key /tmp/dora_run.txt /tmp/dora_latest.txt \
            ${{ secrets.SSH_USER }}@${{ secrets.SERVER_IP }}:/tmp/

          ssh -i ~/.ssh/deploy_key ${{ secrets.SSH_USER }}@${{ secrets.SERVER_IP }} "
            curl -sf --data-binary @/tmp/dora_run.txt \
              http://localhost:9091/metrics/job/github-deploy/runid/${RUN_ID} &&
            curl -sf --data-binary @/tmp/dora_latest.txt \
              http://localhost:9091/metrics/job/github-deploy-latest/branch/${BRANCH} &&
            rm -f /tmp/dora_run.txt /tmp/dora_latest.txt &&
            echo 'DORA metrics pushed to Pushgateway'
          "
EOF

cat > /tmp/new_3b.txt << 'EOF'
          # Upload both files and push to Pushgateway on the MONITORING server.
          # Uses monitor_key (not deploy_key) — monitoring server is separate from app server.
          scp -i ~/.ssh/monitor_key /tmp/dora_run.txt /tmp/dora_latest.txt \
            ubuntu@${{ secrets.MONITOR_SERVER_IP }}:/tmp/

          ssh -i ~/.ssh/monitor_key ubuntu@${{ secrets.MONITOR_SERVER_IP }} "
            curl -sf --data-binary @/tmp/dora_run.txt \
              http://localhost:9091/metrics/job/github-deploy/runid/${RUN_ID} &&
            curl -sf --data-binary @/tmp/dora_latest.txt \
              http://localhost:9091/metrics/job/github-deploy-latest/branch/${BRANCH} &&
            rm -f /tmp/dora_run.txt /tmp/dora_latest.txt &&
            echo 'DORA metrics pushed to Pushgateway on monitoring server'
          "
EOF

python3 - << 'PYEOF'
old = open('/tmp/old_3b.txt').read().rstrip('\n')
new = open('/tmp/new_3b.txt').read().rstrip('\n')
f   = '.github/workflows/deploy.yml'
c   = open(f).read()
if old in c:
    open(f, 'w').write(c.replace(old, new, 1))
    print("  ✅ 3b: metrics push target changed to monitoring server")
elif "MONITOR_SERVER_IP" in c:
    print("  ⏭  3b: already applied")
else:
    print("  ❌ 3b: patch target not found — apply manually")
PYEOF

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "┌──────────────────────────────────────────────────────────────────────┐"
echo "│  Files updated. Now do these steps in order:                        │"
echo "│                                                                      │"
echo "│  1. Fix terraform/terraform.tfvars (see chat for template)          │"
echo "│                                                                      │"
echo "│  2. Spin up the monitoring server:                                   │"
echo "│       cd terraform                                                   │"
echo "│       terraform init                                                 │"
echo "│       terraform apply                                                │"
echo "│     Note the Elastic IP in the output.                              │"
echo "│                                                                      │"
echo "│  3. Add these GitHub secrets (repo Settings → Secrets → Actions):  │"
echo "│       MONITOR_SERVER_IP  = <Elastic IP from terraform output>       │"
echo "│       MONITOR_SSH_KEY    = <contents of ~/.ssh/id_ed25519>          │"
echo "│         (the private key whose public key is in ssh_public_key_path)│"
echo "│                                                                      │"
echo "│  4. Commit and push:                                                 │"
echo "│       git add .                                                      │"
echo "│       git commit -m 'feat: Part 4 monitoring server architecture'   │"
echo "│       git push                                                       │"
echo "│                                                                      │"
echo "│  5. Go to GitHub Actions → trigger deploy manually → watch the      │"
echo "│     'Push DORA metrics to Pushgateway' step in the logs.            │"
echo "│                                                                      │"
echo "│  6. Open Grafana at http://<MONITOR_IP>:3000 → DORA Metrics         │"
echo "└──────────────────────────────────────────────────────────────────────┘"
echo ""
