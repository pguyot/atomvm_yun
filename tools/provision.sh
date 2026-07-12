#!/bin/bash
#
# Provision a stick's NVS over USB: WiFi credentials and optionally the
# device name (namespace atomvm_yun, blob-typed for AtomVM's esp:nvs_*).
# Credentials are prompted, never stored in the repo or shell history.
#
# CAUTION: this rewrites the whole NVS partition. Harmless side effects:
# M5GFX re-detects the board on next boot, and the log cursor resets to
# the start of the thermolog partition (old records get overwritten).
# Provision before first use, not mid-campaign.
#
# Usage: tools/provision.sh <serial-port> [device-name]
#
set -euo pipefail

PORT=${1:?usage: provision.sh <serial-port> [device-name]}
NAME=${2:-}

read -r -p "WiFi SSID: " SSID
read -r -s -p "WiFi PSK: " PSK
echo

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf %s "$SSID" > "$TMP/ssid.bin"
printf %s "$PSK" > "$TMP/psk.bin"
{
    echo "key,type,encoding,value"
    echo "atomvm_yun,namespace,,"
    echo "wifi_ssid,file,binary,$TMP/ssid.bin"
    echo "wifi_psk,file,binary,$TMP/psk.bin"
    if [ -n "$NAME" ]; then
        printf %s "$NAME" > "$TMP/name.bin"
        echo "name,file,binary,$TMP/name.bin"
    fi
} > "$TMP/nvs.csv"

source "$HOME/esp/esp-idf/export.sh" >/dev/null 2>&1

python "$IDF_PATH/components/nvs_flash/nvs_partition_generator/nvs_partition_gen.py" \
    generate "$TMP/nvs.csv" "$TMP/nvs.bin" 0x6000

esptool.py -p "$PORT" -b 1500000 write_flash 0x9000 "$TMP/nvs.bin"

echo "Provisioned. Reset the device (or press its button) to use the new settings."
