#!/bin/bash

# ═══════════════════════════════════════════════════════
#   VLESS + XTLS-Reality AUTO-SETUP + SECURITY
#   v2.0 — fixed & improved
# ═══════════════════════════════════════════════════════

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════╗"
echo "║   VLESS + Reality + Security  Auto Setup   ║"
echo "║                  v2.0                      ║"
echo "╚════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Root Check ────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root: sudo bash setup.sh${NC}"
  exit 1
fi

# ── Warn if Xray already running ──────────────────────
if systemctl is-active --quiet xray 2>/dev/null; then
  echo -e "${YELLOW}⚠  Xray is already running. Reconfiguring...${NC}"
fi

# ── 1. Determine IP ──────────────────────────────────
SERVER_IP=$(curl -4 -s --max-time 5 https://api.ipify.org \
         || curl -4 -s --max-time 5 https://ifconfig.me \
         || curl -4 -s --max-time 5 https://icanhazip.com)
SERVER_IP=$(echo "$SERVER_IP" | tr -d '[:space:]')

if [[ -z "$SERVER_IP" ]]; then
  echo -e "${RED}Error: could not determine server IP. Check your internet connection.${NC}"
  exit 1
fi

PORT=$(shuf -i 47000-60000 -n 1)
echo -e "${GREEN}▶ Server IP : $SERVER_IP${NC}"
echo -e "${GREEN}▶ VPN port  : $PORT${NC}"

# ── 2. OS Update ──────────────────────────────────────
# Only update package lists; full upgrade is left to the admin
# to avoid long waits and kernel/config conflicts during setup.
echo -e "${YELLOW}▶ Updating package lists...${NC}"
apt-get update -qq

# Install required packages (no full dist-upgrade)
apt-get install -y -qq \
  curl unzip openssl \
  qrencode \
  ufw \
  fail2ban \
  unattended-upgrades \
  2>/dev/null

echo -e "${GREEN}▶ Required packages installed${NC}"

# ══════════════════════════════════════════════════════
#   SECURITY BLOCK
# ══════════════════════════════════════════════════════

echo -e "${CYAN}▶ Configuring server security...${NC}"

# ── 3. UFW — firewall ─────────────────────────────────
# Detect actual SSH port dynamically to avoid locking ourselves out
SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n1)
SSH_PORT=${SSH_PORT:-22}
echo -e "${GREEN}▶ Detected SSH port: $SSH_PORT${NC}"

# Make sure IPv6 support is enabled in UFW before resetting
if [ -f /etc/default/ufw ]; then
  sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
fi

ufw --force reset >/dev/null 2>&1
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}/tcp"  comment 'SSH'
ufw allow "${PORT}/tcp"      comment 'VLESS'
ufw --force enable >/dev/null
echo -e "${GREEN}▶ UFW firewall active (ports ${SSH_PORT} and ${PORT} are open)${NC}"

# ── 4. Fail2Ban — brute-force protection ───────────────
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
ignoreip = 127.0.0.1/8

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
backend  = systemd
maxretry = 3
bantime  = 86400
EOF

systemctl enable fail2ban --quiet
systemctl restart fail2ban
echo -e "${GREEN}▶ Fail2Ban active (ban after 3 failed attempts, 24h)${NC}"

# ── 5. Automatic security updates ─────────────────────
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
echo -e "${GREEN}▶ Automatic security updates enabled${NC}"

# ── 6. Kernel hardening (sysctl) ──────────────────────
# Remove any previous entries added by this script to stay idempotent
sed -i '/# --- vless-setup-start ---/,/# --- vless-setup-end ---/d' /etc/sysctl.conf

cat >> /etc/sysctl.conf << 'EOF'

# --- vless-setup-start ---
# Anti-spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# SYN-flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048

# BBR congestion control — critical for VPN throughput
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# --- vless-setup-end ---
EOF

sysctl -p >/dev/null 2>&1
echo -e "${GREEN}▶ Kernel hardening configured (BBR enabled)${NC}"

# ══════════════════════════════════════════════════════
#   XRAY + VLESS REALITY INSTALLATION
# ══════════════════════════════════════════════════════

echo -e "${CYAN}▶ Installing Xray...${NC}"
bash <(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) 1>/dev/null
echo -e "${GREEN}▶ Xray installed${NC}"

# ── 7. Generate all parameters ────────────────────────
echo -e "${YELLOW}▶ Generating keys...${NC}"
XRAY_CMD=$(command -v xray || echo "/usr/local/bin/xray")

KEYS=$($XRAY_CMD x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS"  | grep -i "Public"  | awk '{print $NF}')
UUID=$($XRAY_CMD uuid)
SHORT_ID=$(openssl rand -hex 8)

# Targets with good global CDN — pick one at random
TARGETS=("www.microsoft.com" "www.samsung.com" "www.asus.com" "dl.google.com")
TARGET=${TARGETS[$RANDOM % ${#TARGETS[@]}]}

# Sanitize all values (strip spaces/CR that break the VLESS link)
PRIVATE_KEY=$(echo "$PRIVATE_KEY" | tr -d '[:space:]')
PUBLIC_KEY=$(echo "$PUBLIC_KEY"   | tr -d '[:space:]')
UUID=$(echo "$UUID"               | tr -d '[:space:]')
SHORT_ID=$(echo "$SHORT_ID"       | tr -d '[:space:]')
TARGET=$(echo "$TARGET"           | tr -d '[:space:]')

if [[ -z "$UUID" || -z "$PUBLIC_KEY" || -z "$PRIVATE_KEY" ]]; then
  echo -e "${RED}Error: key generation failed. Check xray binary.${NC}"
  exit 1
fi

# ── 8. Write Xray config ──────────────────────────────
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
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
          "serverNames": ["${TARGET}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"],
          "fingerprint": "chrome"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

# ── 9. Start Xray ─────────────────────────────────────
systemctl enable xray --quiet
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
  echo -e "${GREEN}▶ Xray started successfully!${NC}"
else
  echo -e "${RED}Error starting Xray. Last 20 log lines:${NC}"
  journalctl -u xray -n 20 --no-pager
  exit 1
fi

# ══════════════════════════════════════════════════════
#   BUILD VLESS LINK AND QR CODE
# ══════════════════════════════════════════════════════

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#MyVPN"

# ── Save info to file ─────────────────────────────────
INFO_FILE="/root/vpn-info.txt"
cat > "$INFO_FILE" << EOF
════════════════════════════════════════════════════
  VLESS + XTLS-Reality — connection details
════════════════════════════════════════════════════

Server IP    : ${SERVER_IP}
VPN Port     : ${PORT}
SSH Port     : ${SSH_PORT}
UUID         : ${UUID}
Public Key   : ${PUBLIC_KEY}
Short ID     : ${SHORT_ID}
SNI Target   : ${TARGET}
Fingerprint  : chrome
Flow         : disabled (DPI protection)

IMPORT LINK:
${VLESS_LINK}

════════════════════════════════════════════════════
  Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')
════════════════════════════════════════════════════
EOF

# ══════════════════════════════════════════════════════
#   FINAL OUTPUT
# ══════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         ✅ ALL DONE! YOUR LINK:                  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}${GREEN}${VLESS_LINK}${NC}"
echo ""
echo -e "${YELLOW}══════════ QR-CODE FOR PHONE ══════════${NC}"
qrencode -t ANSIUTF8 -m 2 "$VLESS_LINK"
echo -e "${YELLOW}═══════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}📁 All connection details saved to: ${BOLD}${INFO_FILE}${NC}"
echo ""
echo -e "${CYAN}📱 Client apps:${NC}"
echo "   Android / iOS / Windows / Mac: https://hiddify.com"
echo ""
echo -e "${GREEN}Security summary:${NC}"
echo "   ✅ Fail2Ban   — ban after 3 failed SSH attempts (24h)"
echo "   ✅ UFW        — all ports closed except SSH (${SSH_PORT}) and VPN (${PORT})"
echo "   ✅ Kernel     — SYN-flood, spoofing protection, BBR enabled"
echo "   ✅ Auto-updates — security patches applied automatically"
echo "   ✅ Reality    — TLS fingerprint masking (chrome)"
echo ""

# ── Self-delete prompt ────────────────────────────────
echo -e "${YELLOW}🗑  Delete this setup script from disk? (recommended) [y/N]${NC}"
read -r -t 15 CLEANUP_ANSWER
if [[ "${CLEANUP_ANSWER,,}" == "y" ]]; then
  echo -e "${GREEN}▶ Script deleted.${NC}"
  rm -- "$0"
else
  echo -e "${CYAN}▶ Script kept at: $0${NC}"
fi
