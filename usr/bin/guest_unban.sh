#!/bin/sh
# Guest Unban Utility for OpenWrt
# Usage: guest_unban.sh [mac_address | all]

TARGET=$(echo "$1" | tr 'A-Z' 'a-z')

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <mac_address | all>"
    exit 1
fi

if [ "$TARGET" = "all" ]; then
    > /etc/guest_permanent_bans.txt
    nft flush set inet fw4 guest_banned 2>/dev/null
    echo "Successfully cleared all permanent guest MAC bans."
else
    # Remove MAC from permanent ban file
    sed -i "/^$TARGET$/d" /etc/guest_permanent_bans.txt
    # Remove from live nftables banned set
    nft delete element inet fw4 guest_banned "{ $TARGET }" 2>/dev/null
    echo "Successfully unbanned MAC: $TARGET"
fi
