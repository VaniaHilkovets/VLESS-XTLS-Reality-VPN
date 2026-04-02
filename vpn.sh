#!/bin/bash

# ═══════════════════════════════════════════════════════
#   VLESS + XTLS-Reality AUTO-SETUP + SECURITY
# ═══════════════════════════════════════════════════════

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════╗"
echo "║   VLESS + Reality + Security  Auto Setup   ║"
echo "╚════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Root Check ────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root: sudo bash setup.sh${NC}"
  exit 1
fi

# ── 1. Determine IP ──────────────────────────────────
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
PORT=$(shuf -i 47000-60000 -n 1)
echo -e "${GREEN}▶ Server IP: $SERVER_IP${NC}"
echo -e "${GREEN}▶ Generated random VPN port: $PORT${NC}"

# ── 2. OS Update and Dependencies Installation ─────────
echo -e "${YELLOW}▶ Updating system and installing packages...${NC}"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl unzip openssl \
  qrencode \
  ufw \
  fail2ban \
  unattended-upgrades \
  2>/dev/null

echo -e "${GREEN}▶ All packages installed (including qrencode)${NC}"

# ══════════════════════════════════════════════════════
#   SECURITY BLOCK
# ══════════════════════════════════════════════════════

echo -e "${CYAN}▶ Configuring server security...${NC}"

# ── 3. UFW — firewall ─────────────────────────────────
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'SSH'
ufw allow $PORT/tcp comment 'VLESS'  # our VPN
ufw --force enable >/dev/null
echo -e "${GREEN}▶ UFW firewall active (ports 22 and $PORT are open)${NC}"

# ── 4. Fail2Ban — bruteforce protection ────────────────
cat > /etc/fail2ban/jail.local << 'EOF'
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

systemctl enable fail2ban --quiet
systemctl restart fail2ban
echo -e "${GREEN}▶ Fail2Ban active (ban after 3 failed attempts)${NC}"

# ── 5. Automatic security updates ────────────────────
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
echo -e "${GREEN}▶ Automatic security updates enabled${NC}"

# ── 6. Kernel protection (sysctl) ──────────────────────
cat >> /etc/sysctl.conf << 'EOF'

# Anti-spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# SYN-flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048

# Disable ping (optional, but hides the server)
net.ipv4.icmp_echo_ignore_all = 1
EOF

sysctl -p >/dev/null 2>&1
echo -e "${GREEN}▶ Kernel protection configured${NC}"

# ══════════════════════════════════════════════════════
#   XRAY + VLESS REALITY INSTALLATION
# ══════════════════════════════════════════════════════

echo -e "${CYAN}▶ Installing Xray...${NC}"
bash <(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) 1>/dev/null
echo -e "${GREEN}▶ Xray installed${NC}"

# ── 7. Generating all parameters ───────────────────────
echo -e "${YELLOW}▶ Generating keys...${NC}"
XRAY_CMD=$(command -v xray || echo "/usr/local/bin/xray")
KEYS=$($XRAY_CMD x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS"  | grep -i "Public"  | awk '{print $NF}')
UUID=$($XRAY_CMD uuid)
SHORT_ID=$(openssl rand -hex 8)
TARGETS=("www.samsung.com" "www.asus.com" "dl.google.com" "www.yahoo.com")
TARGET=${TARGETS[$RANDOM % ${#TARGETS[@]}]}

# ── 8. Xray config ────────────────────────────────────
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$TARGET:443",
          "serverNames": ["$TARGET"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
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

# ── 9. Start Xray ───────────────────────────────────
systemctl enable xray --quiet
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
  echo -e "${GREEN}▶ Xray started successfully!${NC}"
else
  echo -e "${RED}Error! Log:${NC}"
  journalctl -u xray -n 20 --no-pager
  exit 1
fi

# ══════════════════════════════════════════════════════
#   GENERATE LINK AND QR
# ══════════════════════════════════════════════════════

# Clean variables from possible spaces and \r (otherwise Hiddify/v2ray crashes with parsing error)
SERVER_IP=$(echo "$SERVER_IP" | tr -d '[:space:]')
UUID=$(echo "$UUID" | tr -d '[:space:]')
PUBLIC_KEY=$(echo "$PUBLIC_KEY" | tr -d '[:space:]')
TARGET=$(echo "$TARGET" | tr -d '[:space:]')
SHORT_ID=$(echo "$SHORT_ID" | tr -d '[:space:]')

if [[ -z "$UUID" || -z "$PUBLIC_KEY" || -z "$SERVER_IP" ]]; then
  echo -e "${RED}Error: empty variables (IP: $SERVER_IP, UUID: $UUID, PUB: $PUBLIC_KEY). Link will not be working!${NC}"
  exit 1
fi

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#MyVPN"

# Save to file
INFO_FILE="/root/vpn-info.txt"
cat > $INFO_FILE << EOF
════════════════════════════════════════════════════
  VLESS + XTLS-Reality — connection details
════════════════════════════════════════════════════

Server IP:   $SERVER_IP
VPN Port:    $PORT
UUID:        $UUID
Public Key:  $PUBLIC_KEY
Short ID:    $SHORT_ID
SNI:         $TARGET
Flow:        disabled (DPI protection)
Fingerprint: chrome

IMPORT LINK:
$VLESS_LINK

════════════════════════════════════════════════════
EOF

# ══════════════════════════════════════════════════════
#   FINAL OUTPUT
# ══════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         ✅ ALL DONE! YOUR LINK:                 ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}${GREEN}$VLESS_LINK${NC}"
echo ""
echo -e "${YELLOW}══════════ QR-CODE FOR PHONE ══════════${NC}"
qrencode -t ANSIUTF8 -m 2 "$VLESS_LINK"
echo -e "${YELLOW}══════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}📁 All data saved to: ${BOLD}/root/vpn-info.txt${NC}"
echo ""
echo -e "${CYAN}📱 Apps:${NC}"
echo "   Android/iOS/Windows/Mac: https://hiddify.com"
echo ""
echo -e "${GREEN}What is protected:${NC}"
echo "   ✅ Fail2Ban  — ban after 3 failed login attempts"
echo "   ✅ UFW       — all unused ports are closed"
echo "   ✅ Kernel    — SYN-flood and spoofing protection"
echo "   ✅ Automatic security updates"
