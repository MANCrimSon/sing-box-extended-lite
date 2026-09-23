#!/bin/sh
set -e

# ==============================================================================
# sing-box-extended-lite Installer for OpenWrt
# Repository: https://github.com/MANCrimSon/sing-box-extended-lite
# Based on the installer concept by EikeiDev (https://github.com/EikeiDev/OpenWRT-sing-box-extended)
# ==============================================================================

REPO="MANCrimSon/sing-box-extended-lite"
DEST_BIN="/usr/bin/sing-box"
REAL_BIN="/usr/libexec/sing-box-core"
VERSION_CACHE="/etc/sing-box-version.cache"
BACKUP_BIN="/tmp/sing-box.bak"
BACKUP_REAL="/tmp/sing-box-core.bak"
WORK_DIR="/tmp/sing-box-install"
PROXY_PREFIX="https://ghproxy.net/"

# Terminal colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

cleanup() {
    rm -rf "$WORK_DIR"
    rm -f "/usr/bin/.sing-box.tmp.$$" "/usr/libexec/.sing-box-core.tmp.$$"
}

fail() {
    printf "${RED}[!] Error: %s${NC}\n" "$1"
    if [ -f "$BACKUP_BIN" ]; then
        printf "${YELLOW}[*] Restoring previous binary from backup...${NC}\n"
        cp -f "$BACKUP_BIN" "$DEST_BIN"
        chmod +x "$DEST_BIN"
    fi
    if [ -f "$BACKUP_REAL" ]; then
        cp -f "$BACKUP_REAL" "$REAL_BIN"
        chmod +x "$REAL_BIN"
    fi
    cleanup
    [ "$SERVICE_STOPPED" = "1" ] && restart_services
    exit 1
}

trap 'fail "Installation aborted by signal"' INT TERM

# Check OpenWrt environment
if [ -f "/etc/openwrt_release" ]; then
    . /etc/openwrt_release
else
    fail "This system is not running OpenWrt."
fi

# Detect architecture
case "$DISTRIB_ARCH" in
    aarch64*) ARCH="arm64" ;;
    x86_64) ARCH="amd64" ;;
    mipsel_24kc) ARCH="mipsle-softfloat" ;;
    mips_24kc) ARCH="mips-softfloat" ;;
    arm_cortex-a7* | arm_cortex-a15*) ARCH="armv7" ;;
    *)
        case "$(uname -m)" in
            aarch64) ARCH="arm64" ;;
            x86_64) ARCH="amd64" ;;
            mipsle) ARCH="mipsle-softfloat" ;;
            mips) ARCH="mips-softfloat" ;;
            armv7*) ARCH="armv7" ;;
            *) fail "Unsupported architecture: $DISTRIB_ARCH ($(uname -m))" ;;
        esac
        ;;
esac

# Detect downloader
if command -v curl >/dev/null 2>&1; then
    DOWNLOAD="curl -fsSL --insecure --connect-timeout 20 -o"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOAD="wget -q --no-check-certificate --timeout=20 -O"
elif command -v uclient-fetch >/dev/null 2>&1; then
    DOWNLOAD="uclient-fetch -q --no-check-certificate --timeout=20 -O"
else
    fail "Neither curl, wget, nor uclient-fetch was found."
fi

# Detect managed services
SERVICE_NAME=""
if [ -f "/etc/init.d/podkop" ]; then
    SERVICE_NAME="podkop"
elif [ -f "/etc/init.d/sing-box" ]; then
    SERVICE_NAME="sing-box"
fi

ZB_SERVICE=""
if [ -f "/etc/init.d/zeroblock" ]; then
    ZB_SERVICE="zeroblock"
fi

CURRENT_VER=""
if [ -x "$DEST_BIN" ]; then
    CURRENT_VER=$("$DEST_BIN" version 2>/dev/null | head -n 1 | awk '{print $NF}' || echo "")
fi

# Parse CLI arguments (--compressed, --normal, [version_tag])
WANT_COMPRESSED=""
REQ_TAG=""
USER_CHOSE_NORMAL=""

for arg in "$@"; do
    case "$arg" in
        --compressed|-c) WANT_COMPRESSED="1"; USER_CHOSE_NORMAL="" ;;
        --normal|-n)     WANT_COMPRESSED="0"; USER_CHOSE_NORMAL="1" ;;
        v*|1.*)          REQ_TAG="$arg" ;;
    esac
done

# Auto-detect flash capacity if not explicitly requested
FLASH_AVAIL_MB=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}' | tr -cd '0-9')
[ -z "$FLASH_AVAIL_MB" ] && FLASH_AVAIL_MB=0

if [ "$USER_CHOSE_NORMAL" = "1" ] && [ "$FLASH_AVAIL_MB" -lt 50 ]; then
    fail "Flash protection: Root partition has only ${FLASH_AVAIL_MB} MB free (< 50 MB required for normal build). Installing uncompressed binary (~46 MB) may brick your router. Please use --compressed instead."
fi

if [ -z "$WANT_COMPRESSED" ]; then
    if [ "$FLASH_AVAIL_MB" -lt 55 ]; then
        WANT_COMPRESSED="1"
    else
        WANT_COMPRESSED="0"
    fi
fi

VARIANT_LABEL="Normal (Uncompressed ~46MB)"
[ "$WANT_COMPRESSED" = "1" ] && VARIANT_LABEL="Compressed (UPX Lite ~9.5–12.5MB)"

printf "\n${CYAN}====================================================${NC}\n"
printf "${CYAN}  sing-box-extended-lite OpenWrt Installer${NC}\n"
printf "${CYAN}====================================================${NC}\n"
printf "  OS Release:    ${YELLOW}%s${NC}\n" "${DISTRIB_RELEASE:-unknown}"
printf "  Architecture:  ${YELLOW}%s${NC} -> ${YELLOW}%s${NC}\n" "$DISTRIB_ARCH" "$ARCH"
printf "  Variant:       ${YELLOW}%s${NC}\n" "$VARIANT_LABEL"
printf "  Active Target: ${YELLOW}%s${NC}\n" "${SERVICE_NAME:-manual/none}"
printf "  Installed Ver: ${YELLOW}%s${NC}\n\n" "${CURRENT_VER:-not found}"

# Resolve download filename
SUFFIX=""
[ "$WANT_COMPRESSED" = "1" ] && SUFFIX="-compressed"

if [ -n "$REQ_TAG" ]; then
    REQ_VER="${REQ_TAG#v}"
    FILE_NAME="sing-box-extended-lite-${REQ_VER}-linux-${ARCH}${SUFFIX}.tar.gz"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${REQ_TAG}/${FILE_NAME}"
else
    FILE_NAME="sing-box-extended-lite-linux-${ARCH}${SUFFIX}.tar.gz"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${FILE_NAME}"
fi

# Check free space in /tmp (65 MB for normal, 25 MB for compressed)
REQ_TMP_KB=65000
[ "$WANT_COMPRESSED" = "1" ] && REQ_TMP_KB=25000

TMP_FREE_KB=$(df -Pk /tmp 2>/dev/null | awk 'NR==2 {print $4}' | tr -cd '0-9')
if [ -n "$TMP_FREE_KB" ] && [ "$TMP_FREE_KB" -lt "$REQ_TMP_KB" ]; then
    fail "Insufficient free space in /tmp (${TMP_FREE_KB} KB available, ${REQ_TMP_KB} KB required)."
fi

cleanup
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

printf "${CYAN}[*] Downloading %s...${NC}\n" "$FILE_NAME"
if ! $DOWNLOAD "$FILE_NAME" "$DOWNLOAD_URL"; then
    printf "${YELLOW}[!] Direct download failed. Trying mirror (ghproxy)...${NC}\n"
    if ! $DOWNLOAD "$FILE_NAME" "${PROXY_PREFIX}${DOWNLOAD_URL}"; then
        fail "Failed to download $FILE_NAME."
    fi
fi

if [ ! -s "$FILE_NAME" ]; then
    fail "Downloaded archive is empty."
fi

printf "${CYAN}[*] Extracting archive...${NC}\n"
tar -xzf "$FILE_NAME" || fail "Failed to extract archive."

EXTRACTED_BIN=$(find "$WORK_DIR" -type f -name "sing-box" | head -n 1)
if [ -z "$EXTRACTED_BIN" ]; then
    fail "Executable 'sing-box' not found in downloaded archive."
fi

stop_services() {
    if [ -n "$ZB_SERVICE" ] && /etc/init.d/"$ZB_SERVICE" status >/dev/null 2>&1; then
        printf "${CYAN}[*] Stopping %s...${NC}\n" "$ZB_SERVICE"
        /etc/init.d/"$ZB_SERVICE" stop >/dev/null 2>&1 || true
    fi
    if [ -n "$SERVICE_NAME" ] && /etc/init.d/"$SERVICE_NAME" status >/dev/null 2>&1; then
        printf "${CYAN}[*] Stopping %s...${NC}\n" "$SERVICE_NAME"
        /etc/init.d/"$SERVICE_NAME" stop >/dev/null 2>&1 || true
    fi
    killall sing-box >/dev/null 2>&1 || true
    killall sing-box-core >/dev/null 2>&1 || true
    SERVICE_STOPPED=1
    sleep 1
}

restart_services() {
    if [ -n "$SERVICE_NAME" ]; then
        printf "${CYAN}[*] Starting %s...${NC}\n" "$SERVICE_NAME"
        /etc/init.d/"$SERVICE_NAME" start >/dev/null 2>&1 || printf "${YELLOW}[!] Warning: Failed to restart %s.${NC}\n" "$SERVICE_NAME"
    fi
    if [ -n "$ZB_SERVICE" ]; then
        printf "${CYAN}[*] Starting %s...${NC}\n" "$ZB_SERVICE"
        /etc/init.d/"$ZB_SERVICE" start >/dev/null 2>&1 || printf "${YELLOW}[!] Warning: Failed to restart %s.${NC}\n" "$ZB_SERVICE"
    fi
    sleep 2
}

stop_services

# Backup existing binaries
if [ -f "$DEST_BIN" ]; then
    cp -f "$DEST_BIN" "$BACKUP_BIN"
fi
if [ -f "$REAL_BIN" ]; then
    cp -f "$REAL_BIN" "$BACKUP_REAL"
fi

STAGE_BIN="/usr/bin/.sing-box.tmp.$$"
STAGE_REAL="/usr/libexec/.sing-box-core.tmp.$$"

if [ "$WANT_COMPRESSED" = "1" ]; then
    # Compressed variant: install to REAL_BIN atomically and install smart version-cache wrapper
    mkdir -p "$(dirname "$REAL_BIN")"
    cp -f "$EXTRACTED_BIN" "$STAGE_REAL"
    chmod +x "$STAGE_REAL"
    mv -f "$STAGE_REAL" "$REAL_BIN"

    # Query banner from real binary once to populate cache
    "$REAL_BIN" version > "$VERSION_CACHE" 2>/dev/null || true

    cat > "$STAGE_BIN" << 'EOF'
#!/bin/sh
REAL_BIN="/usr/libexec/sing-box-core"
VERSION_CACHE="/etc/sing-box-version.cache"

if [ "$#" -eq 1 ] && [ "$1" = "version" ]; then
    if [ -s "$VERSION_CACHE" ]; then
        cat "$VERSION_CACHE"
        exit 0
    fi
fi

exec "$REAL_BIN" "$@"
EOF
    chmod +x "$STAGE_BIN"
    mv -f "$STAGE_BIN" "$DEST_BIN"
else
    # Normal uncompressed variant: direct ELF, no wrapper
    rm -f "$REAL_BIN" "$VERSION_CACHE"
    cp -f "$EXTRACTED_BIN" "$STAGE_BIN"
    chmod +x "$STAGE_BIN"
    mv -f "$STAGE_BIN" "$DEST_BIN"
fi

# Validate installed binary
NEW_BANNER=$("$DEST_BIN" version 2>/dev/null | head -n 1 || echo "")
if [ -z "$NEW_BANNER" ]; then
    fail "Installed sing-box failed execution test."
fi

NEW_VER=$(echo "$NEW_BANNER" | awk '{print $NF}')
TARGET_FILE="$DEST_BIN"
[ "$WANT_COMPRESSED" = "1" ] && TARGET_FILE="$REAL_BIN"

BIN_SIZE_MB=$(ls -lh "$TARGET_FILE" | awk '{print $5}')
FLASH_FREE_MB=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
RAM_FREE_MB=$(free -m 2>/dev/null | awk '/Mem:/ {print $7}')
[ -z "$RAM_FREE_MB" ] && RAM_FREE_MB=$(free -m 2>/dev/null | awk '/Mem:/ {print $4}')

restart_services
cleanup
rm -f "$BACKUP_BIN" "$BACKUP_REAL"

printf "\n${GREEN}[+] Installation Successful!${NC}\n"
printf "  Version:       ${YELLOW}%s${NC} -> ${GREEN}%s${NC}\n" "${CURRENT_VER:-n/a}" "$NEW_VER"
printf "  Binary Size:   ${GREEN}%s${NC} (%s)\n" "$BIN_SIZE_MB" "$VARIANT_LABEL"
printf "  Free Flash:    ${GREEN}%s MB${NC}\n" "${FLASH_FREE_MB:-n/a}"
printf "  Free RAM:      ${GREEN}%s MB${NC}\n" "${RAM_FREE_MB:-n/a}"
printf "${CYAN}====================================================${NC}\n\n"
