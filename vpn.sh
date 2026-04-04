#!/bin/bash

# ═══════════════════════════════════════════════════════
#          VLESS + XTLS-Reality AUTO-SETUP
# ═══════════════════════════════════════════════════════

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG="/usr/local/etc/xray/config.json"
INFO_FILE="/root/vpn-info.txt"
LOG_FILE="/root/setup.log"
XRAY_CMD="$(command -v xray 2>/dev/null || echo /usr/local/bin/xray)"
SSH_PORT="22"
PORT="443"

# ── Checks ────────────────────────────────────────────
if [ "${EUID}" -ne 0 ]; then
  echo -e "${RED}Run as root: sudo bash menu.sh${NC}"
  exit 1
fi

if [ ! -f /etc/debian_version ]; then
  echo -e "${RED}Only Debian/Ubuntu are supported.${NC}"
  exit 1
fi

# ══════════════════════════════════════════════════════
#   HELPERS
# ══════════════════════════════════════════════════════

print_header() {
  echo ""
  echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║     VLESS + Reality — Management Menu      ║${NC}"
  echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
}

xray_installed() {
  command -v xray >/dev/null 2>&1 || [ -x "/usr/local/bin/xray" ]
}

get_xray_cmd() {
  XRAY_CMD="$(command -v xray 2>/dev/null || echo /usr/local/bin/xray)"
}

get_public_ip() {
  local ip=""
  ip=$(curl -4 -s --max-time 5 https://api.ipify.org \
    || curl -4 -s --max-time 5 https://ifconfig.me \
    || curl -4 -s --max-time 5 https://icanhazip.com \
    || true)
  echo "$ip" | tr -d '[:space:]'
}

wait_xray_active() {
  local i
  for i in {1..12}; do
    if systemctl is-active --quiet xray; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_xray_stopped() {
  local i
  for i in {1..12}; do
    if ! systemctl is-active --quiet xray; then
      return 0
    fi
    sleep 1
  done
  return 1
}

json_get() {
  local py="$1"
  python3 - <<PY 2>/dev/null
import json
with open("$CONFIG","r") as f:
    d = json.load(f)
$py
PY
}

get_server_info() {
  SERVER_IP="$(get_public_ip)"
  [ -f "$CONFIG" ] || return 0

  PORT_CFG="$(json_get 'print(d["inbounds"][0]["port"])' || echo 443)"
  UUID="$(json_get 'print(d["inbounds"][0]["settings"]["clients"][0]["id"])' || echo "")"
  TARGET="$(json_get 'print(d["inbounds"][0]["streamSettings"]["realitySettings"]["serverNames"][0])' || echo "")"
  PRIVATE_KEY="$(json_get 'print(d["inbounds"][0]["streamSettings"]["realitySettings"]["privateKey"])' || echo "")"
  SHORT_ID="$(json_get 'print(d["inbounds"][0]["streamSettings"]["realitySettings"]["shortIds"][0])' || echo "")"

  get_xray_cmd
  PUBLIC_KEY="$("$XRAY_CMD" x25519 -i "$PRIVATE_KEY" 2>/dev/null | awk '
    /Public key/ {print $3}
    /PublicKey/ {print $2}
    /Password:/ {print $2}
  ' | tail -n1 | tr -d "[:space:]")"
}

make_link() {
  local uuid="$1"
  local label="${2:-MyVPN}"
  echo "vless://${uuid}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision&headerType=none#${label}"
}

generate_reality_keys() {
  get_xray_cmd

  local out priv pub
  out="$("$XRAY_CMD" x25519 2>/dev/null || true)"

  priv="$(echo "$out" | awk '
    /Private key/ {print $3}
    /PrivateKey/ {print $2}
  ' | tail -n1 | tr -d "[:space:]")"

  pub="$(echo "$out" | awk '
    /Public key/ {print $3}
    /PublicKey/ {print $2}
    /Password:/ {print $2}
  ' | tail -n1 | tr -d "[:space:]")"

  if [ -n "$priv" ] && [ -z "$pub" ]; then
    pub="$("$XRAY_CMD" x25519 -i "$priv" 2>/dev/null | awk '
      /Public key/ {print $3}
      /PublicKey/ {print $2}
      /Password:/ {print $2}
    ' | tail -n1 | tr -d "[:space:]")"
  fi

  PRIVATE_KEY="$priv"
  PUBLIC_KEY="$pub"

  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    return 1
  fi
  return 0
}

ensure_packages() {
  echo -e "${YELLOW}▶ Installing packages...${NC}"
  apt-get update -qq
  apt-get install -y -qq \
    curl unzip openssl netcat-openbsd qrencode ufw fail2ban \
    unattended-upgrades ca-certificates python3 >/dev/null
  echo -e "${GREEN}▶ Packages installed${NC}"
}

setup_ufw() {
  echo -e "${YELLOW}▶ Configuring UFW...${NC}"
  [ -f /etc/default/ufw ] && sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw || true
  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp comment 'SSH'
  ufw allow 443/tcp comment 'VLESS-Reality'
  ufw --force enable >/dev/null
  echo -e "${GREEN}▶ UFW active (SSH:22, VPN:443)${NC}"
}

setup_fail2ban() {
  echo -e "${YELLOW}▶ Configuring Fail2Ban...${NC}"
  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
ignoreip = 127.0.0.1/8

[sshd]
enabled  = true
port     = 22
logpath  = %(sshd_log)s
backend  = systemd
maxretry = 3
bantime  = 86400
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  echo -e "${GREEN}▶ Fail2Ban active${NC}"
}

setup_auto_updates() {
  echo -e "${YELLOW}▶ Enabling auto security updates...${NC}"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  echo -e "${GREEN}▶ Auto security updates enabled${NC}"
}

setup_sysctl() {
  echo -e "${YELLOW}▶ Applying kernel tuning...${NC}"
  sed -i '/# --- vless-setup-start ---/,/# --- vless-setup-end ---/d' /etc/sysctl.conf
  cat >> /etc/sysctl.conf <<'EOF'

# --- vless-setup-start ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# --- vless-setup-end ---
EOF
  sysctl -p >/dev/null 2>&1 || true
  echo -e "${GREEN}▶ Kernel hardening + BBR enabled${NC}"
}

install_xray() {
  echo -e "${YELLOW}▶ Installing Xray...${NC}"
  bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install >/dev/null
  get_xray_cmd
  if ! xray_installed; then
    echo -e "${RED}Error: Xray install failed.${NC}"
    return 1
  fi
  echo -e "${GREEN}▶ Xray installed${NC}"
}

pick_target() {
  echo -e "${YELLOW}▶ Selecting SNI target...${NC}"
  local targets target
  targets=(
    "www.microsoft.com"
    "www.cloudflare.com"
    "www.apple.com"
    "www.amazon.com"
  )
  TARGET=""
  for target in "${targets[@]}"; do
    if nc -z -w3 "$target" 443 >/dev/null 2>&1; then
      TARGET="$target"
      break
    fi
  done
  [ -n "$TARGET" ] || TARGET="www.microsoft.com"
  echo -e "${GREEN}▶ SNI target  : ${TARGET}${NC}"
}

write_xray_config() {
  mkdir -p "$(dirname "$CONFIG")"
  cat > "$CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "comment": "default"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${TARGET}:443",
          "serverNames": [
            "${TARGET}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
}

setup_xray_restart_policy() {
  mkdir -p /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
EOF
  systemctl daemon-reload
}

show_current_link() {
  if [ ! -f "$CONFIG" ]; then
    echo -e "${RED}Config not found.${NC}"
    return 1
  fi

  get_server_info
  if [ -z "${UUID:-}" ] || [ -z "${PUBLIC_KEY:-}" ] || [ -z "${SHORT_ID:-}" ] || [ -z "${TARGET:-}" ] || [ -z "${SERVER_IP:-}" ]; then
    echo -e "${RED}Failed to build current link.${NC}"
    return 1
  fi

  echo ""
  echo -e "${CYAN}Current link:${NC}"
  echo -e "${BOLD}${GREEN}$(make_link "$UUID" "MyVPN")${NC}"
  echo ""
}

# ══════════════════════════════════════════════════════
#   ACTIONS
# ══════════════════════════════════════════════════════

do_install_and_start() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║         Installing + Starting VLESS Reality     ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

  : > "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1

  SERVER_IP="$(get_public_ip)"
  if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}Error: cannot determine server IP.${NC}"
    return 1
  fi

  echo -e "${GREEN}▶ Server IP   : ${SERVER_IP}${NC}"
  echo -e "${GREEN}▶ VPN port    : ${PORT}${NC}"
  echo -e "${GREEN}▶ SSH port    : ${SSH_PORT}${NC}"

  if ss -ltnp 2>/dev/null | grep -q ":${PORT} "; then
    echo -e "${RED}Error: port 443 is already in use.${NC}"
    ss -ltnp | grep ":${PORT} "
    return 1
  fi

  ensure_packages || return 1
  setup_ufw || return 1
  setup_fail2ban || return 1
  setup_auto_updates || return 1
  setup_sysctl || return 1
  install_xray || return 1

  echo -e "${YELLOW}▶ Generating Reality keys...${NC}"
  if ! generate_reality_keys; then
    echo -e "${RED}Error: failed to generate Reality credentials.${NC}"
    echo -e "${YELLOW}Debug:${NC}"
    "$XRAY_CMD" version 2>/dev/null || true
    "$XRAY_CMD" x25519 2>/dev/null || true
    return 1
  fi
  echo -e "${GREEN}▶ Reality keys generated${NC}"

  UUID="$("$XRAY_CMD" uuid 2>/dev/null | tr -d '[:space:]')"
  SHORT_ID="$(openssl rand -hex 8 | tr -d '[:space:]')"

  if [ -z "$UUID" ] || [ -z "$SHORT_ID" ]; then
    echo -e "${RED}Error: failed to generate UUID or Short ID.${NC}"
    return 1
  fi

  pick_target
  write_xray_config
  setup_xray_restart_policy

  echo -e "${YELLOW}▶ Starting Xray...${NC}"
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray

  if ! wait_xray_active; then
    echo -e "${RED}Error: Xray failed to start.${NC}"
    journalctl -u xray -n 50 --no-pager
    return 1
  fi

  if ! ss -ltnp 2>/dev/null | grep -q ":443 "; then
    echo -e "${RED}Error: Xray is running but port 443 is not listening.${NC}"
    journalctl -u xray -n 50 --no-pager
    return 1
  fi

  VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision&headerType=none#MyVPN"

  cat > "$INFO_FILE" <<EOF
════════════════════════════════════════════════════
  VLESS + XTLS-Reality — connection details
════════════════════════════════════════════════════

Server IP    : ${SERVER_IP}
VPN Port     : ${PORT}
SSH Port     : 22
UUID         : ${UUID}
Public Key   : ${PUBLIC_KEY}
Short ID     : ${SHORT_ID}
SNI Target   : ${TARGET}
Fingerprint  : chrome
Flow         : xtls-rprx-vision
Connections  : unlimited

IMPORT LINK:
${VLESS_LINK}

════════════════════════════════════════════════════
Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')
Manage    : bash $(realpath "$0")
════════════════════════════════════════════════════
EOF

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║          ✅ Installed and started!               ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}${GREEN}${VLESS_LINK}${NC}"
  echo ""
  echo -e "${YELLOW}══════════ QR CODE ══════════${NC}"
  qrencode -t ANSIUTF8 -m 2 "$VLESS_LINK"
  echo -e "${YELLOW}════════════════════════════${NC}"
  echo ""
  echo -e "${CYAN}📁 Details : ${BOLD}${INFO_FILE}${NC}"
  echo -e "${CYAN}📋 Log     : ${BOLD}${LOG_FILE}${NC}"
  echo ""
}

do_stop() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║                  Stopping Xray                   ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

  if ! xray_installed; then
    echo -e "${RED}Xray is not installed.${NC}"
    return 1
  fi

  systemctl stop xray

  if wait_xray_stopped; then
    echo -e "${GREEN}▶ Xray stopped successfully.${NC}"
  else
    echo -e "${RED}Error: failed to stop Xray.${NC}"
    systemctl status xray --no-pager -l || true
    return 1
  fi
}

do_uninstall() {
  echo ""
  echo -e "${RED}This will completely remove Xray, config, and firewall rules.${NC}"
  read -rp "$(echo -e "${YELLOW}Are you sure? [y/N]: ${NC}")" CONFIRM
  [[ "${CONFIRM,,}" != "y" ]] && { echo "Cancelled."; return; }

  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true

  rm -rf /etc/systemd/system/xray.service.d
  systemctl daemon-reload

  bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) remove >/dev/null 2>&1 || true

  rm -f "$CONFIG" "$INFO_FILE" "$LOG_FILE"

  ufw --force reset >/dev/null 2>&1 || true
  ufw --force disable >/dev/null 2>&1 || true

  sed -i '/# --- vless-setup-start ---/,/# --- vless-setup-end ---/d' /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true

  rm -f /etc/fail2ban/jail.local
  systemctl restart fail2ban 2>/dev/null || true

  echo ""
  echo -e "${GREEN}✅ Uninstall complete. Server is clean.${NC}"
}

# ══════════════════════════════════════════════════════
#   MENU
# ══════════════════════════════════════════════════════

while true; do
  print_header

  if systemctl is-active --quiet xray 2>/dev/null; then
    echo -e "   Status : ${GREEN}● running${NC}"
  elif xray_installed; then
    echo -e "   Status : ${RED}● stopped${NC}"
  else
    echo -e "   Status : ${YELLOW}● not installed${NC}"
  fi

  echo ""
  echo "   1)  Install + Start"
  echo "   2)  Stop"
  echo "   3)  Uninstall"
  echo "   0)  Exit"
  echo ""
  read -rp "$(echo -e "${YELLOW}  Choice: ${NC}")" MENU_CHOICE

  case "$MENU_CHOICE" in
    1) do_install_and_start ;;
    2) do_stop ;;
    3) do_uninstall ;;
    0) echo "Bye."; exit 0 ;;
    *) echo -e "${RED}Unknown option.${NC}" ;;
  esac
done
