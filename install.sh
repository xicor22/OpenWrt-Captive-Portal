#!/bin/sh
# ==============================================================================
# Automated Installation Script for OpenWrt TOTP Captive Portal
# Designed for OpenWrt 22.03, 23.05, 24+ (fw4 / nftables)
# ==============================================================================

set -e

# ==================== CONFIGURATION (CUSTOMIZE AS NEEDED) ====================
GUEST_IF="br-guest"              # Name of guest bridge device
GUEST_IP="192.168.10.1"          # Guest Gateway IP
GUEST_NETMASK="255.255.255.0"    # Guest Subnet Mask
GUEST_DHCP_START="100"           # DHCP pool start (e.g. .100)
GUEST_DHCP_LIMIT="150"           # DHCP pool size (e.g. 150 leases -> .100 to .249)
GUEST_LEASE_TIME="1h"            # DHCP lease time
PORTAL_PORT="8080"               # Web server port for captive portal
# ==============================================================================

echo "=== OpenWrt TOTP Captive Portal Installer ==="

# 1. Install prerequisites
echo "-> Checking and installing dependencies..."
which openssl >/dev/null 2>&1 || {
    if which apk >/dev/null 2>&1; then
        apk update && apk add openssl-util
    else
        opkg update && opkg install openssl-util
    fi
}

# 2. Configure Guest Bridge Network
echo "-> Setting up $GUEST_IF bridge and IP addressing ($GUEST_IP)..."
uci set network.br_guest=device
uci set network.br_guest.name="$GUEST_IF"
uci set network.br_guest.type='bridge'
uci set network.br_guest.bridge_empty='1'

uci set network.guest=interface
uci set network.guest.device="$GUEST_IF"
uci set network.guest.proto='static'
uci set network.guest.ipaddr="$GUEST_IP"
uci set network.guest.netmask="$GUEST_NETMASK"
uci set network.guest.ip6assign='0'
uci commit network

# 3. Configure Guest DHCP Server
echo "-> Setting up DHCP server on guest interface..."
uci set dhcp.guest=dhcp
uci set dhcp.guest.interface='guest'
uci set dhcp.guest.dhcpv4='server'
uci set dhcp.guest.start="$GUEST_DHCP_START"
uci set dhcp.guest.limit="$GUEST_DHCP_LIMIT"
uci set dhcp.guest.leasetime="$GUEST_LEASE_TIME"
uci set dhcp.guest.ra='disabled'
uci set dhcp.guest.dhcpv6='disabled'
uci set dhcp.guest.ndp='disabled'
uci commit dhcp

# 4. Configure Firewall Zone and Rules
echo "-> Configuring firewall zones and forwarding..."
uci add firewall zone 2>/dev/null || true
uci set firewall.@zone[-1].name='guest'
uci set firewall.@zone[-1].network='guest'
uci set firewall.@zone[-1].input='DROP'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='DROP'

uci add firewall forwarding 2>/dev/null || true
uci set firewall.@forwarding[-1].src='guest'
uci set firewall.@forwarding[-1].dest='wan'

uci add firewall forwarding 2>/dev/null || true
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='guest'

uci add firewall rule 2>/dev/null || true
uci set firewall.@rule[-1].name='Guest-DHCP'
uci set firewall.@rule[-1].src='guest'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].dest_port='67-68'
uci set firewall.@rule[-1].target='ACCEPT'

uci add firewall rule 2>/dev/null || true
uci set firewall.@rule[-1].name='Guest-DNS'
uci set firewall.@rule[-1].src='guest'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].target='ACCEPT'

uci add firewall rule 2>/dev/null || true
uci set firewall.@rule[-1].name='Guest-Portal-HTTP'
uci set firewall.@rule[-1].src='guest'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port="$PORTAL_PORT"
uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall

# 5. Copy Files
echo "-> Deploying scripts and nftables rules..."
mkdir -p /etc/nftables.d /www/guest/cgi-bin /usr/bin
cp -f etc/nftables.d/20-guest-portal.nft /etc/nftables.d/20-guest-portal.nft
cp -f www/guest/index.html /www/guest/index.html
cp -f www/guest/cgi-bin/splash /www/guest/cgi-bin/splash
cp -f www/guest/cgi-bin/auth /www/guest/cgi-bin/auth
cp -f usr/bin/guest_guard.sh /usr/bin/guest_guard.sh
cp -f usr/bin/guest_unban.sh /usr/bin/guest_unban.sh

chmod +x /www/guest/cgi-bin/splash /www/guest/cgi-bin/auth /usr/bin/guest_guard.sh /usr/bin/guest_unban.sh

# 6. Configure uhttpd Instance for Captive Portal
echo "-> Configuring uhttpd instance on $GUEST_IP:$PORTAL_PORT..."
uci set uhttpd.guest=uhttpd
uci set uhttpd.guest.listen_http="${GUEST_IP}:${PORTAL_PORT}"
uci set uhttpd.guest.home='/www/guest'
uci set uhttpd.guest.cgi_prefix='/cgi-bin'
uci set uhttpd.guest.error_page='/cgi-bin/splash'
uci set uhttpd.guest.no_symlinks='1'
uci commit uhttpd

# 7. Configure Crontab for 10-Minute Guard
echo "-> Registering 10-minute auto-kick guard in cron..."
mkdir -p /etc/crontabs
touch /etc/crontabs/root
grep -q "guest_guard.sh" /etc/crontabs/root || echo "* * * * * /usr/bin/guest_guard.sh" >> /etc/crontabs/root
/etc/init.d/cron enable
/etc/init.d/cron restart

# 8. Configure LuCI Custom Commands
echo "-> Registering LuCI management commands..."
uci add luci command 2>/dev/null || true
uci set luci.@command[-1].name='Unban Guest MAC (enter MAC or "all")'
uci set luci.@command[-1].command='/usr/bin/guest_unban.sh'
uci set luci.@command[-1].param='1'

uci add luci command 2>/dev/null || true
uci set luci.@command[-1].name='Show Banned Guest MACs'
uci set luci.@command[-1].command='cat /etc/guest_permanent_bans.txt'
uci commit luci 2>/dev/null || true

# 9. Generate TOTP Seed if not present
if [ ! -f /etc/guest_totp.hex ]; then
    echo "-> Generating fresh TOTP secret seed..."
    sh generate_totp.sh
else
    echo "-> Existing TOTP secret found in /etc/guest_totp.hex, keeping it."
fi

# 10. Restart Services
echo "-> Reloading network, firewall, and web services..."
/etc/init.d/network reload || /etc/init.d/network restart
ifup guest 2>/dev/null || true
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/uhttpd restart

echo ""
echo "=== Installation Complete! ==="
echo "Attach your wireless guest AP to network 'guest' (bridge: $GUEST_IF)."
