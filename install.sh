#!/bin/bash
# ============================================================
#  Binance P2P Monitor — Ubuntu 22.04 VPS Installer
#  - Python monitor as systemd service
#  - Web dashboard served via Nginx on port 80
#  - Firewall ports 80 & 443 opened
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
step()    { echo -e "\n${BOLD}▶ $*${RESET}"; }

# ── Config ────────────────────────────────────────────────────
REPO_URL="https://github.com/thematveev/binance-p2p-monitor.git"
INSTALL_DIR="/opt/binance-p2p-monitor"
SERVICE_NAME="p2p-monitor"
VENV_DIR="$INSTALL_DIR/.venv"
SCRIPT="$INSTALL_DIR/binance_p2p_monitor.py"
LOG_DIR="/var/log/p2p-monitor"
DATA_DIR="/var/lib/p2p-monitor"
RUN_USER="p2pmonitor"
WEB_ROOT="/var/www/p2p-monitor"
NGINX_SITE="/etc/nginx/sites-available/p2p-monitor"

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash install.sh"

echo -e "\n${BOLD}╔══════════════════════════════════════════╗"
echo -e "║   Binance P2P Monitor — Installer        ║"
echo -e "║   Ubuntu 22.04 VPS                       ║"
echo -e "╚══════════════════════════════════════════╝${RESET}\n"

# ── 1. System packages ────────────────────────────────────────
step "Installing system packages"
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv git curl ca-certificates nginx ufw > /dev/null
success "Installed: python3, nginx, ufw, git, curl"

# ── 2. Firewall ───────────────────────────────────────────────
step "Configuring firewall"
ufw allow OpenSSH  > /dev/null 2>&1 || true
ufw allow 80/tcp   > /dev/null 2>&1 || true
ufw allow 443/tcp  > /dev/null 2>&1 || true
ufw --force enable > /dev/null 2>&1 || true
success "Ports 22, 80, 443 open"
warn "Oracle Cloud: also open 80/443 in VCN Security List in the web console"

# ── 3. Service user ───────────────────────────────────────────
step "Setting up service user"
if id "$RUN_USER" &>/dev/null; then
  warn "User '$RUN_USER' already exists, skipping"
else
  useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
  success "Created system user: $RUN_USER"
fi

# ── 4. Directories ────────────────────────────────────────────
step "Creating directories"
mkdir -p "$LOG_DIR" "$DATA_DIR" "$WEB_ROOT"
chown "$RUN_USER":"$RUN_USER" "$LOG_DIR" "$DATA_DIR"
success "Directories ready"

# ── 5. Clone / update repo ────────────────────────────────────
step "Fetching code from GitHub"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "Repo found — pulling latest changes"
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone --depth=1 "$REPO_URL" "$INSTALL_DIR"
fi
success "Code ready at $INSTALL_DIR"

# ── 6. Python venv ────────────────────────────────────────────
step "Setting up Python virtual environment"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip --quiet
"$VENV_DIR/bin/pip" install requests --quiet
success "Virtualenv + requests installed"

# ── 7. Patch script paths ─────────────────────────────────────
step "Patching script paths"
sed -i "s|CSV_FILE = \"binance_p2p_uah_usdt.csv\"|CSV_FILE = \"$DATA_DIR/binance_p2p_uah_usdt.csv\"|" "$SCRIPT" 2>/dev/null || true
sed -i "s|LOG_FILE = \"binance_p2p_monitor.log\"|LOG_FILE = \"$LOG_DIR/binance_p2p_monitor.log\"|" "$SCRIPT" 2>/dev/null || true
chown -R "$RUN_USER":"$RUN_USER" "$INSTALL_DIR"
success "CSV and log paths configured"

# ── 8. systemd service ────────────────────────────────────────
step "Installing systemd service"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << UNIT
[Unit]
Description=Binance P2P UAH/USDT Price Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${DATA_DIR}
ExecStart=${VENV_DIR}/bin/python3 ${SCRIPT}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths=${LOG_DIR} ${DATA_DIR}

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
success "systemd service installed and enabled"

# ── 9. logrotate ──────────────────────────────────────────────
step "Setting up log rotation"
cat > "/etc/logrotate.d/${SERVICE_NAME}" << LOGR
${LOG_DIR}/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGR
success "logrotate: 14 days, daily, compressed"

# ── 10. Web dashboard via Nginx ───────────────────────────────
step "Deploying web dashboard"
if [[ -f "$INSTALL_DIR/p2p-dashboard.html" ]]; then
  cp "$INSTALL_DIR/p2p-dashboard.html" "$WEB_ROOT/index.html"
  success "Dashboard copied to $WEB_ROOT/index.html"
else
  warn "p2p-dashboard.html not in repo — skipping web copy"
fi

cat > "$NGINX_SITE" << NGINX
server {
    listen 80;
    server_name _;

    root ${WEB_ROOT};
    index index.html;

    # Expose collected CSV so dashboard can fetch it directly
    location /data/ {
        alias ${DATA_DIR}/;
        add_header Access-Control-Allow-Origin *;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
}
NGINX

ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/p2p-monitor
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx && systemctl enable nginx
success "Nginx running on port 80"

# ── 11. Start monitor ─────────────────────────────────────────
step "Starting P2P monitor"
systemctl restart "$SERVICE_NAME"
sleep 2

if systemctl is-active --quiet "$SERVICE_NAME"; then
  success "Monitor service is running!"
else
  warn "Service failed to start — showing last logs:"
  journalctl -u "$SERVICE_NAME" -n 20 --no-pager
  exit 1
fi

# ── Summary ───────────────────────────────────────────────────
VPS_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo -e "\n${GREEN}${BOLD}✔ All done!${RESET}\n"
echo -e "  ${BOLD}Dashboard URL:${RESET}   http://${VPS_IP}"
echo -e ""
echo -e "  ${BOLD}Monitor commands:${RESET}"
echo -e "  ${CYAN}systemctl status  ${SERVICE_NAME}${RESET}"
echo -e "  ${CYAN}systemctl restart ${SERVICE_NAME}${RESET}"
echo -e "  ${CYAN}journalctl -u     ${SERVICE_NAME} -f${RESET}"
echo -e "  ${CYAN}tail -f           ${LOG_DIR}/binance_p2p_monitor.log${RESET}"
echo -e ""
echo -e "  ${BOLD}Data files:${RESET}"
echo -e "  CSV  → ${DATA_DIR}/binance_p2p_uah_usdt.csv"
echo -e "  Logs → ${LOG_DIR}/binance_p2p_monitor.log"
echo -e "  Web  → ${WEB_ROOT}/index.html"
echo -e ""
echo -e "  ${YELLOW}⚠ Oracle Cloud:${RESET} open ports 80 & 443 in"
echo -e "    VCN → Security Lists → Ingress Rules"
echo ""
