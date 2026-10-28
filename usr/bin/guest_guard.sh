#!/bin/sh
# ==============================================================================
# Guest Guard: Auto-kick & permanent ban for unauthenticated guests
# Designed for OpenWrt with hostapd & nftables
# ==============================================================================

# User-Configurable Variables
GUEST_IF="br-guest"              # Guest bridge interface
BAN_TIMEOUT=600                  # Maximum unauthenticated time in seconds (default: 600s = 10m)
BAN_DURATION_MS=86400000         # hostapd deauth ban duration in ms (default: 24h)
TRACK_FILE="/tmp/guest_timer.txt"
PERM_BAN_FILE="/etc/guest_permanent_bans.txt"

touch "$TRACK_FILE" "$PERM_BAN_FILE"
NOW=$(date +%s)

# 1. Ensure all permanently banned MACs are populated in nftables
for BAN_MAC in $(cat "$PERM_BAN_FILE" 2>/dev/null); do
    nft add element inet fw4 guest_banned "{ $BAN_MAC }" 2>/dev/null
done

AUTH_SET=$(nft list set inet fw4 guest_authorized 2>/dev/null)

# Auto-detect guest subnet prefix from bridge interface
GUEST_SUBNET_PREFIX=$(ip -4 addr show dev "$GUEST_IF" 2>/dev/null | awk '$1=="inet"{print $2}' | cut -d. -f1-3)

# 2. Iterate across all Wi-Fi interfaces attached to the guest bridge
for IFACE in $(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}'); do
    ip link show "$IFACE" 2>/dev/null | grep -q "master $GUEST_IF" || continue

    for MAC in $(iw dev "$IFACE" station dump 2>/dev/null | awk '$1=="Station"{print tolower($2)}'); do
        # If client is already in the permanent ban list, deauthenticate immediately
        if grep -qi "^$MAC$" "$PERM_BAN_FILE"; then
            for H in $(ubus list hostapd.*); do
                ubus call "$H" del_client "{\"addr\":\"$MAC\",\"reason\":1,\"deauth\":true,\"ban_time\":$BAN_DURATION_MS}" 2>/dev/null
            done
            continue
        fi

        # Find the client IP from DHCP leases or ARP neighbor table
        CLIENT_IP=$(awk -v m="$MAC" -v p="$GUEST_SUBNET_PREFIX" 'tolower($2)==m && $3 ~ ("^" p "\\.") {print $3}' /tmp/dhcp.leases | head -n 1)
        [ -z "$CLIENT_IP" ] && CLIENT_IP=$(ip neigh show dev "$GUEST_IF" 2>/dev/null | awk -v m="$MAC" -v p="$GUEST_SUBNET_PREFIX" 'tolower($5)==m && $1 ~ ("^" p "\\.") {print $1}' | head -n 1)

        # If client has authenticated via TOTP, remove from timer tracking
        if [ -n "$CLIENT_IP" ] && echo "$AUTH_SET" | grep -qw "$CLIENT_IP"; then
            sed -i "/^$MAC /d" "$TRACK_FILE"
            continue
        fi

        # Track unauthenticated client duration
        FIRST_SEEN=$(awk -v m="$MAC" '$1==m {print $2}' "$TRACK_FILE")
        if [ -z "$FIRST_SEEN" ]; then
            echo "$MAC $NOW" >> "$TRACK_FILE"
        elif [ $(( NOW - FIRST_SEEN )) -ge "$BAN_TIMEOUT" ]; then
            # Timeout exceeded without TOTP authorization -> Permanent Ban
            logger -t guest_guard "Guest $MAC exceeded ${BAN_TIMEOUT}s without authentication. Permanently banning."
            echo "$MAC" >> "$PERM_BAN_FILE"
            nft add element inet fw4 guest_banned "{ $MAC }" 2>/dev/null

            for H in $(ubus list hostapd.*); do
                ubus call "$H" del_client "{\"addr\":\"$MAC\",\"reason\":1,\"deauth\":true,\"ban_time\":$BAN_DURATION_MS}" 2>/dev/null
            done

            sed -i "/^$MAC /d" "$TRACK_FILE"
        fi
    done
done
