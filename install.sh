#!/bin/bash
# ============================================================
#  Binance P2P Monitor — Ubuntu 22.04 VPS Installer
#  Installs Python deps, clones repo, sets up systemd service
# ============================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
step()    { echo -e "\n${BOLD}▶ $*${RESET}"; }

# ── Config (edit if needed) ───────────────────────────────────
REPO_URL="https://github.com/thematveev/binance-p2p-monitor.git"
INSTALL_DIR="/opt/binance-p2p-monitor"
SERVICE_NAME="p2p-monitor"
VENV_DIR="$INSTALL_DIR/.venv"
SCRIPT="$INSTALL_DIR/binance_p2p_monitor.py"
LOG_DIR="/var/log/p2p-monitor"
DATA_DIR="/var/lib/p2p-monitor"
RUN_USER="p2pmonitor"

# ── Root check ────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Run as root: sudo bash install.sh"
fi

echo -e "\n${BOLD}╔══════════════════════════════════════════╗"
echo -e "║   Binance P2P Monitor — Installer        ║"
echo -e "║   Ubuntu 22.04 VPS                       ║"
echo -e "╚══════════════════════════════════════════╝${RESET}\n"

# ── 1. System packages ─────────────────────────────────────────
step "Installing system packages"
apt-get update -qq
apt-get install -y -qq \
  python3 python3-pip python3-venv \
  git curl ca-certificates \
  > /dev/null
success "System packages installed"

# ── 2. Create dedicated user ───────────────────────────────────
step "Setting up service user"
if id "$RUN_USER" &>/dev/null; then
  warn "User '$RUN_USER' already exists, skipping"
else
  useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
  success "Created user: $RUN_USER"
fi

# ── 3. Directories ─────────────────────────────────────────────
step "Creating directories"
mkdir -p "$LOG_DIR" "$DATA_DIR"
chown "$RUN_USER":"$RUN_USER" "$LOG_DIR" "$DATA_DIR"
success "Directories ready"

# ── 4. Clone / update repo ─────────────────────────────────────
step "Fetching code from GitHub"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "Repo already cloned — pulling latest changes"
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone --depth=1 "$REPO_URL" "$INSTALL_DIR"
fi
success "Code ready at $INSTALL_DIR"

# ── 5. Python virtual environment ──────────────────────────────
step "Creating Python virtual environment"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip --quiet
"$VENV_DIR/bin/pip" install requests --quiet
success "Virtual environment ready"

# ── 6. Patch script paths for VPS layout ──────────────────────
step "Configuring script paths"
# Replace CSV_FILE and LOG_FILE paths so data lands in /var/lib and /var/log
sed -i \
  "s|CSV_FILE = \"binance_p2p_uah_usdt.csv\"|CSV_FILE = \"$DATA_DIR/binance_p2p_uah_usdt.csv\"|" \
  "$SCRIPT" 2>/dev/null || warn "CSV_FILE path already patched or not found"

sed -i \
  "s|LOG_FILE = \"binance_p2p_monitor.log\"|LOG_FILE = \"$LOG_DIR/binance_p2p_monitor.log\"|" \
  "$SCRIPT" 2>/dev/null || warn "LOG_FILE path already patched or not found"

chown -R "$RUN_USER":"$RUN_USER" "$INSTALL_DIR"
success "Paths configured"

# ── 7. systemd service ─────────────────────────────────────────
step "Installing systemd service"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
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

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths=${LOG_DIR} ${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
success "Systemd service installed and enabled"

# ── 8. logrotate ───────────────────────────────────────────────
step "Setting up log rotation"
cat > "/etc/logrotate.d/${SERVICE_NAME}" << EOF
${LOG_DIR}/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
success "logrotate configured (14 days, daily)"

# ── 9. Start service ───────────────────────────────────────────
step "Starting service"
systemctl restart "$SERVICE_NAME"
sleep 2

if systemctl is-active --quiet "$SERVICE_NAME"; then
  success "Service is running!"
else
  warn "Service failed to start — check logs below"
  journalctl -u "$SERVICE_NAME" -n 20 --no-pager
  exit 1
fi

# ── Done ───────────────────────────────────────────────────────
echo -e "\n${GREEN}${BOLD}✔ Installation complete!${RESET}\n"
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "  ${CYAN}systemctl status  ${SERVICE_NAME}${RESET}         — service status"
echo -e "  ${CYAN}systemctl stop    ${SERVICE_NAME}${RESET}         — stop monitor"
echo -e "  ${CYAN}systemctl restart ${SERVICE_NAME}${RESET}         — restart monitor"
echo -e "  ${CYAN}journalctl -u     ${SERVICE_NAME} -f${RESET}      — live logs (systemd)"
echo -e "  ${CYAN}tail -f ${LOG_DIR}/binance_p2p_monitor.log${RESET}  — live log file"
echo -e "  ${CYAN}cat ${DATA_DIR}/binance_p2p_uah_usdt.csv${RESET}  — view CSV data"
echo -e ""
echo -e "  ${BOLD}Data files:${RESET}"
echo -e "  CSV  → ${DATA_DIR}/binance_p2p_uah_usdt.csv"
echo -e "  Logs → ${LOG_DIR}/binance_p2p_monitor.log"
echo -e ""
