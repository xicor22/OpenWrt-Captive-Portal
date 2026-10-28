#!/bin/sh
# ==============================================================================
# Generate 160-bit (20-byte) RFC 6238 TOTP Secret Key & Output Base32
#
# Generates a random cryptographic seed from /dev/urandom, saves it in hex
# format to /etc/guest_totp.hex, and converts it to standard Base32 for addition
# to any standard Authenticator app (Google Authenticator, Proton, Aegis, etc.).
# ==============================================================================

set -e

KEY_FILE="/etc/guest_totp.hex"

echo "-> Generating 160-bit cryptographically secure random TOTP seed..."
head -c 20 /dev/urandom | hexdump -v -e '1/1 "%02x"' > "$KEY_FILE"
chmod 600 "$KEY_FILE"

HEX_KEY=$(cat "$KEY_FILE")
B32_CHARS="ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
B32_KEY=""

# Convert 40 hex characters (20 bytes) to 32 Base32 characters (5 bits per character)
for i in 1 6 11 16 21 26 31 36; do
    CHUNK=$(echo "$HEX_KEY" | cut -c $i-$((i+4)))
    [ ${#CHUNK} -lt 5 ] && break
    VAL=$(( 0x$CHUNK ))
    for shift in 15 10 5 0; do
        IDX=$(( ((VAL >> shift) & 31) + 1 ))
        B32_KEY="${B32_KEY}$(echo "$B32_CHARS" | cut -c $IDX)"
    done
done

echo "======================================================"
echo "TOTP Secret Generated Successfully!"
echo "Secret Key File: $KEY_FILE"
echo ""
echo "Add this token to your Authenticator App:"
echo "Secret Key (Base32): $B32_KEY"
echo "Algorithm: SHA1"
echo "Type: Time-based (TOTP)"
echo "Digits: 6"
echo "Period: 30 seconds"
echo "======================================================"
