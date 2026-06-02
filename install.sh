#!/bin/bash
# ============================================================
#  Binance P2P Monitor — Full Reset & Install
#  Wipes previous installation, sets up fresh from scratch
#  Includes: systemd service, Nginx, firewall, self-check
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
NGINX_CONF="/etc/nginx/sites-available/p2p-monitor"
NGINX_LINK="/etc/nginx/sites-enabled/p2p-monitor"

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash install.sh"

echo -e "\n${BOLD}╔══════════════════════════════════════════╗"
echo -e "║  Binance P2P Monitor — Clean Reinstall   ║"
echo -e "╚══════════════════════════════════════════╝${RESET}\n"

# ── 1. WIPE previous installation ─────────────────────────────
step "Wiping previous installation"

# Stop & disable services
systemctl stop "$SERVICE_NAME"  2>/dev/null && info "Stopped $SERVICE_NAME" || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload

# Remove nginx config
rm -f "$NGINX_CONF" "$NGINX_LINK"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Remove old files (keep CSV data!)
if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
  info "Removed $INSTALL_DIR"
fi
rm -rf "$WEB_ROOT"
rm -f "/etc/logrotate.d/${SERVICE_NAME}"

# Remove old user
if id "$RUN_USER" &>/dev/null; then
  userdel "$RUN_USER" 2>/dev/null || true
  info "Removed user $RUN_USER"
fi

success "Previous installation wiped"

# ── 2. System packages ────────────────────────────────────────
step "Installing/updating system packages"
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv git curl ca-certificates nginx ufw > /dev/null
success "Packages ready"

# ── 3. Firewall ───────────────────────────────────────────────
step "Configuring firewall"
ufw allow OpenSSH > /dev/null 2>&1 || true
ufw allow 80/tcp  > /dev/null 2>&1 || true
ufw allow 443/tcp > /dev/null 2>&1 || true
ufw --force enable > /dev/null 2>&1 || true
success "UFW: ports 22, 80, 443 open"
warn "Oracle Cloud: also open ports 80/443 in VCN → Security Lists → Ingress Rules"

# ── 4. Create user & directories ─────────────────────────────
step "Creating user and directories"
useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
mkdir -p "$LOG_DIR" "$DATA_DIR" "$WEB_ROOT" "$INSTALL_DIR"
chown "$RUN_USER":"$RUN_USER" "$LOG_DIR" "$DATA_DIR"
success "User '$RUN_USER' and directories created"

# ── 5. Clone repo ─────────────────────────────────────────────
step "Cloning repository"
git config --global --add safe.directory "$INSTALL_DIR" 2>/dev/null || true
git clone --depth=1 "$REPO_URL" "$INSTALL_DIR"
chown -R root:root "$INSTALL_DIR"
success "Repo cloned to $INSTALL_DIR"

# ── 6. Python venv ────────────────────────────────────────────
step "Setting up Python virtual environment"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip --quiet
"$VENV_DIR/bin/pip" install requests --quiet
success "Virtualenv + requests ready"

# ── 7. Patch script paths ─────────────────────────────────────
step "Patching script paths"
if [[ -f "$SCRIPT" ]]; then
  sed -i "s|CSV_FILE = \"binance_p2p_uah_usdt.csv\"|CSV_FILE = \"$DATA_DIR/binance_p2p_uah_usdt.csv\"|" "$SCRIPT" || true
  sed -i "s|LOG_FILE = \"binance_p2p_monitor.log\"|LOG_FILE = \"$LOG_DIR/binance_p2p_monitor.log\"|" "$SCRIPT" || true
  success "Paths patched in script"
else
  warn "Monitor script not found at $SCRIPT — skipping patch"
fi

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
success "systemd service installed"

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
success "logrotate configured"

# ── 10. Nginx ─────────────────────────────────────────────────
step "Configuring Nginx"

# Purge nginx state
rm -f /etc/nginx/sites-enabled/*

# Write fresh config
cat > "$NGINX_CONF" << NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root ${WEB_ROOT};
    index index.html;

    location /data/ {
        alias ${DATA_DIR}/;
        add_header Access-Control-Allow-Origin *;
        autoindex on;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
}
NGINX

ln -sf "$NGINX_CONF" "$NGINX_LINK"

# Test config
if nginx -t 2>/dev/null; then
  success "Nginx config valid"
else
  error "Nginx config invalid — check $NGINX_CONF"
fi

# Copy dashboard
if [[ -f "$INSTALL_DIR/p2p-dashboard.html" ]]; then
  cp "$INSTALL_DIR/p2p-dashboard.html" "$WEB_ROOT/index.html"
  success "Dashboard copied to $WEB_ROOT/index.html"
else
  # Create minimal placeholder
  echo "<html><body><h1>Dashboard loading...</h1></body></html>" > "$WEB_ROOT/index.html"
  warn "p2p-dashboard.html not found — placeholder created"
fi

systemctl restart nginx
systemctl enable nginx
success "Nginx running on port 80"

# ── 11. Start monitor ─────────────────────────────────────────
step "Starting P2P monitor service"
systemctl restart "$SERVICE_NAME"
sleep 3

if systemctl is-active --quiet "$SERVICE_NAME"; then
  success "Monitor service is running"
else
  warn "Monitor failed — last logs:"
  journalctl -u "$SERVICE_NAME" -n 15 --no-pager
fi

# ── 12. Self-check ────────────────────────────────────────────
step "Running self-check"
sleep 2

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost)
if [[ "$HTTP_CODE" == "200" ]]; then
  success "HTTP check: localhost returns 200 OK"
else
  warn "HTTP check: localhost returned $HTTP_CODE"
fi

TITLE=$(curl -s http://localhost | grep -o '<title>[^<]*' | head -1)
info "Page title: $TITLE"

if systemctl is-active --quiet "$SERVICE_NAME"; then
  success "Monitor: active"
else
  warn "Monitor: NOT running"
fi

if systemctl is-active --quiet nginx; then
  success "Nginx: active"
else
  warn "Nginx: NOT running"
fi

# ── Summary ───────────────────────────────────────────────────
VPS_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo -e "\n${GREEN}${BOLD}══════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Installation complete!${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${RESET}\n"
echo -e "  ${BOLD}Dashboard:${RESET}  http://${VPS_IP}"
echo -e ""
echo -e "  ${BOLD}Monitor:${RESET}"
echo -e "  ${CYAN}journalctl -u ${SERVICE_NAME} -f${RESET}          (live logs)"
echo -e "  ${CYAN}systemctl status ${SERVICE_NAME}${RESET}          (status)"
echo -e ""
echo -e "  ${BOLD}Data:${RESET}"
echo -e "  CSV  → ${DATA_DIR}/binance_p2p_uah_usdt.csv"
echo -e "  Logs → ${LOG_DIR}/binance_p2p_monitor.log"
echo -e "  Web  → ${WEB_ROOT}/index.html"
echo -e ""
echo -e "  ${YELLOW}Oracle Cloud:${RESET} VCN → Security Lists → Ingress Rules → add TCP 80"
echo ""
