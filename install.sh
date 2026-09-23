#!/bin/sh
set -e

# ==============================================================================
# sing-box-extended-lite Installer for OpenWrt
# Repository: https://github.com/MANCrimSon/sing-box-extended-lite
# Based on the installer concept by EikeiDev (https://github.com/EikeiDev/OpenWRT-sing-box-extended)
# ==============================================================================

REPO="MANCrimSon/sing-box-extended-lite"
DEST_BIN="${DEST_BIN:-/usr/bin/sing-box}"
REAL_BIN="${REAL_BIN:-/usr/libexec/sing-box-core}"
VERSION_CACHE="${VERSION_CACHE:-/etc/sing-box-version.cache}"
BACKUP_BIN="${BACKUP_BIN:-/tmp/sing-box.bak}"
BACKUP_REAL="${BACKUP_REAL:-/tmp/sing-box-core.bak}"
BACKUP_CACHE="${BACKUP_CACHE:-/tmp/sing-box-cache.bak}"
WORK_DIR="${WORK_DIR:-/tmp/sing-box-install}"
PROXY_PREFIX="https://ghproxy.net/"
RELEASE_FILE="${RELEASE_FILE:-/etc/openwrt_release}"
INIT_DIR="${INIT_DIR:-/etc/init.d}"
PROC_MEMINFO="${PROC_MEMINFO:-/proc/meminfo}"
STAGE_BIN="$(dirname "$DEST_BIN")/.sing-box.tmp.$$"
STAGE_REAL="$(dirname "$REAL_BIN")/.sing-box-core.tmp.$$"

# Terminal colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

INSTALL_SUCCESS=0
INSTALL_STARTED=0
SERVICE_STOPPED=0
WAS_SERVICE_RUNNING=0
WAS_ZB_RUNNING=0
HAD_BACKUP_BIN=0
HAD_BACKUP_REAL=0
HAD_BACKUP_CACHE=0
DEST_BIN_TOUCHED=0
REAL_BIN_TOUCHED=0
CACHE_TOUCHED=0
BACKUP_RESTORED=0

cleanup() {
    rm -rf "$WORK_DIR"
    rm -f "$STAGE_BIN" "$STAGE_REAL"
}

restore_backup() {
    [ "$BACKUP_RESTORED" = "1" ] && return 0
    BACKUP_RESTORED=1

    # Never touch production files if installation hasn't started modifying them
    [ "$INSTALL_STARTED" != "1" ] && return 0

    if [ "$HAD_BACKUP_BIN" = "1" ]; then
        if [ -f "$BACKUP_BIN" ]; then
            printf "${YELLOW}[*] Restoring previous binary from backup...${NC}\n"
            cp -f "$BACKUP_BIN" "$DEST_BIN" 2>/dev/null || true
            chmod +x "$DEST_BIN" 2>/dev/null || true
        fi
    elif [ "$DEST_BIN_TOUCHED" = "1" ]; then
        rm -f "$DEST_BIN"
    fi

    if [ "$HAD_BACKUP_REAL" = "1" ]; then
        if [ -f "$BACKUP_REAL" ]; then
            cp -f "$BACKUP_REAL" "$REAL_BIN" 2>/dev/null || true
            chmod +x "$REAL_BIN" 2>/dev/null || true
        fi
    elif [ "$REAL_BIN_TOUCHED" = "1" ]; then
        rm -f "$REAL_BIN"
    fi

    if [ "$HAD_BACKUP_CACHE" = "1" ]; then
        if [ -f "$BACKUP_CACHE" ]; then
            cp -f "$BACKUP_CACHE" "$VERSION_CACHE" 2>/dev/null || true
        fi
    elif [ "$CACHE_TOUCHED" = "1" ]; then
        rm -f "$VERSION_CACHE"
    fi

    rm -f "$BACKUP_BIN" "$BACKUP_REAL" "$BACKUP_CACHE"
}

fail() {
    printf "${RED}[!] Error: %s${NC}\n" "$1"
    restore_backup
    cleanup
    [ "$SERVICE_STOPPED" = "1" ] && restart_services
    exit 1
}

on_signal() {
    trap - INT TERM EXIT
    if [ "$INSTALL_STARTED" = "1" ]; then
        fail "Installation aborted by signal."
    else
        printf "\n${YELLOW}[*] Installation cancelled by user.${NC}\n"
        cleanup
        exit 130
    fi
}

on_exit() {
    exit_code=$?
    cleanup
    if [ "$exit_code" -ne 0 ] && [ "$INSTALL_SUCCESS" != "1" ]; then
        restore_backup
        [ "$SERVICE_STOPPED" = "1" ] && restart_services
    fi
}

trap on_exit EXIT
trap on_signal INT TERM

# Early help handler
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            printf "Usage: %s [OPTIONS] [VERSION_TAG]\n\n" "$0"
            printf "Options:\n"
            printf "  -n, --normal       Install uncompressed Pure ELF (~46 MB)\n"
            printf "  -c, --compressed   Install UPX Lite compressed (~10 MB)\n"
            printf "  -h, --help         Show this help message\n\n"
            printf "Examples:\n"
            printf "  %s                 Interactive / auto-detection\n" "$0"
            printf "  %s --normal        Force normal build\n" "$0"
            printf "  %s --compressed    Force compressed build\n" "$0"
            printf "  %s v1.12.1         Install specific version\n" "$0"
            exit 0
            ;;
    esac
done

# Check OpenWrt environment
if [ -f "$RELEASE_FILE" ]; then
    . "$RELEASE_FILE"
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
if [ -f "$INIT_DIR/podkop" ]; then
    SERVICE_NAME="podkop"
elif [ -f "$INIT_DIR/sing-box" ]; then
    SERVICE_NAME="sing-box"
fi

ZB_SERVICE=""
if [ -f "$INIT_DIR/zeroblock" ]; then
    ZB_SERVICE="zeroblock"
fi

# Detect installed variant and binary size
INSTALLED_VARIANT=""
CURRENT_FILE_BYTES=0

if [ -f "$REAL_BIN" ]; then
    INSTALLED_VARIANT="compressed"
    CURRENT_FILE_BYTES=$(wc -c < "$REAL_BIN" 2>/dev/null | tr -cd '0-9')
elif [ -f "$VERSION_CACHE" ]; then
    INSTALLED_VARIANT="compressed"
elif [ -f "$DEST_BIN" ]; then
    if grep -q "sing-box-core" "$DEST_BIN" 2>/dev/null; then
        INSTALLED_VARIANT="compressed"
    else
        INSTALLED_VARIANT="normal"
        CURRENT_FILE_BYTES=$(wc -c < "$DEST_BIN" 2>/dev/null | tr -cd '0-9')
    fi
fi

[ -z "$CURRENT_FILE_BYTES" ] && CURRENT_FILE_BYTES=0
CURRENT_FILE_SIZE_MB=$(( CURRENT_FILE_BYTES / 1048576 ))

CURRENT_VER=""
if [ -s "$VERSION_CACHE" ]; then
    CURRENT_VER=$(head -n 1 "$VERSION_CACHE" 2>/dev/null | awk '{print $NF}' || echo "")
fi
if [ -z "$CURRENT_VER" ] && [ -x "$DEST_BIN" ]; then
    CURRENT_VER=$("$DEST_BIN" version 2>/dev/null | head -n 1 | awk '{print $NF}' || echo "")
fi

# Detect Flash capacity and calculate effective space (using POSIX portable df -Pk)
FLASH_AVAIL_KB=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}' | tr -cd '0-9')
[ -z "$FLASH_AVAIL_KB" ] && FLASH_AVAIL_KB=0
FLASH_AVAIL_MB=$(( FLASH_AVAIL_KB / 1024 ))
FLASH_EFFECTIVE_MB=$(( FLASH_AVAIL_MB + CURRENT_FILE_SIZE_MB ))

# Helper to query free/available RAM in MB
get_ram_free_mb() {
    _ram_mb=""
    if [ -r "$PROC_MEMINFO" ]; then
        _ram_mb=$(awk '
            /^MemAvailable:/ { avail = $2; has_avail = 1 }
            /^MemFree:/      { free = $2 }
            /^Buffers:/      { buffers = $2 }
            /^Cached:/       { cached = $2 }
            END {
                if (has_avail) {
                    print int(avail / 1024)
                } else if (free != "") {
                    print int((free + buffers + cached) / 1024)
                }
            }
        ' "$PROC_MEMINFO" 2>/dev/null)
    fi
    if [ -z "$_ram_mb" ] && command -v free >/dev/null 2>&1; then
        _ram_kb=$(free 2>/dev/null | awk '
            /Mem:/ {
                if (NF >= 8) avail = $8;
                else if (NF == 7) avail = $7;
                else if (NF >= 4) mem_free = $4;
            }
            /buffers\/cache:/ {
                buf_free = $NF;
            }
            END {
                if (avail != "") print avail;
                else if (buf_free != "") print buf_free;
                else if (mem_free != "") print mem_free;
            }
        ' | tr -cd '0-9')
        if [ -n "$_ram_kb" ] && [ "$_ram_kb" -gt 0 ]; then
            _ram_mb=$(( _ram_kb / 1024 ))
        fi
    fi
    printf "%s" "$_ram_mb"
}

RAM_AVAIL_MB=$(get_ram_free_mb)
[ -n "$RAM_AVAIL_MB" ] && RAM_AVAIL_DISP="${RAM_AVAIL_MB} MB" || RAM_AVAIL_DISP="n/a"

# Parse CLI arguments (--compressed, --normal, [version_tag])
WANT_COMPRESSED=""
REQ_TAG=""
CLI_EXPLICIT=0

for arg in "$@"; do
    case "$arg" in
        --compressed|-c)
            WANT_COMPRESSED="1"
            CLI_EXPLICIT=1
            ;;
        --normal|-n)
            WANT_COMPRESSED="0"
            CLI_EXPLICIT=1
            ;;
        v*|[0-9]*.*)
            REQ_TAG="$arg"
            ;;
        *)
            fail "Unknown option: $arg. Use -h or --help for usage."
            ;;
    esac
done

# Determine default recommended variant:
# 1 = Normal (Pure ELF)
# 2 = Compressed (UPX Lite)
if [ "$INSTALLED_VARIANT" = "normal" ]; then
    if [ "$FLASH_EFFECTIVE_MB" -lt 50 ]; then
        DEFAULT_CHOICE="2"
    else
        DEFAULT_CHOICE="1"
    fi
elif [ "$INSTALLED_VARIANT" = "compressed" ]; then
    DEFAULT_CHOICE="2"
else
    # Fresh install: select based on available flash
    if [ "$FLASH_EFFECTIVE_MB" -ge 55 ]; then
        DEFAULT_CHOICE="1"
    else
        DEFAULT_CHOICE="2"
    fi
fi

# Print installation banner header
printf "\n${CYAN}====================================================${NC}\n"
printf "${CYAN}  sing-box-extended-lite OpenWrt Installer${NC}\n"
printf "${CYAN}====================================================${NC}\n"
printf "  OS Release:      ${YELLOW}%s${NC}\n" "${DISTRIB_RELEASE:-unknown}"
printf "  Architecture:    ${YELLOW}%s${NC} -> ${YELLOW}%s${NC}\n" "$DISTRIB_ARCH" "$ARCH"
printf "  Installed Ver:   ${YELLOW}%s${NC}%s\n" "${CURRENT_VER:-not found}" "$([ -n "$INSTALLED_VARIANT" ] && printf " (%s)" "$INSTALLED_VARIANT")"
printf "  Effective Flash: ${YELLOW}%s MB${NC} (free: %s MB, reusable: %s MB)\n" "$FLASH_EFFECTIVE_MB" "$FLASH_AVAIL_MB" "$CURRENT_FILE_SIZE_MB"
printf "  Available RAM:   ${YELLOW}%s${NC}\n" "$RAM_AVAIL_DISP"

# Interactive selection if no CLI flag was provided
if [ "$CLI_EXPLICIT" = "0" ]; then
    IS_TTY=0
    if [ -t 0 ]; then
        IS_TTY=1
    elif [ -t 1 ] && ( : < /dev/tty ) 2>/dev/null; then
        IS_TTY=1
    fi

    if [ "$IS_TTY" = "1" ]; then
        printf "\nSelect installation variant:\n"
        if [ "$DEFAULT_CHOICE" = "1" ]; then
            printf "  ${GREEN}1) Normal (Pure ELF ~46MB)     - Zero RAM overhead (recommended for Flash >= 55MB) [*]${NC}\n"
            printf "  2) Compressed (UPX Lite ~10MB) - Saves ~35MB Flash (for routers with 16-32MB flash)\n"
        else
            printf "  1) Normal (Pure ELF ~46MB)     - Zero RAM overhead (recommended for Flash >= 55MB)\n"
            printf "  ${GREEN}2) Compressed (UPX Lite ~10MB) - Saves ~35MB Flash (for routers with 16-32MB flash) [*]${NC}\n"
        fi
        printf "Choice [1-2, default: %s]: " "$DEFAULT_CHOICE"

        USER_CHOICE=""
        if [ -t 0 ]; then
            read -r USER_CHOICE || true
        else
            read -r USER_CHOICE < /dev/tty || true
        fi

        # Strip surrounding whitespace and carriage returns (PuTTY / Windows SSH)
        USER_CHOICE=$(printf "%s" "$USER_CHOICE" | tr -d ' \t\r\n')
        [ -z "$USER_CHOICE" ] && USER_CHOICE="$DEFAULT_CHOICE"

        case "$USER_CHOICE" in
            1|normal|Normal|n|N)
                WANT_COMPRESSED="0"
                ;;
            2|compressed|Compressed|c|C)
                WANT_COMPRESSED="1"
                ;;
            *)
                printf "${YELLOW}[*] Unknown choice '%s', using default option %s.${NC}\n" "$USER_CHOICE" "$DEFAULT_CHOICE"
                if [ "$DEFAULT_CHOICE" = "1" ]; then
                    WANT_COMPRESSED="0"
                else
                    WANT_COMPRESSED="1"
                fi
                ;;
        esac
    else
        # Non-interactive mode (cron, automated scripts): retain installed variant or use capacity heuristic
        if [ "$DEFAULT_CHOICE" = "1" ]; then
            WANT_COMPRESSED="0"
        else
            WANT_COMPRESSED="1"
        fi
    fi
fi

# Flash protection check for normal build
if [ "$WANT_COMPRESSED" = "0" ] && [ "$FLASH_EFFECTIVE_MB" -lt 50 ]; then
    fail "Flash protection: Root partition has only ${FLASH_EFFECTIVE_MB} MB effective free space (< 50 MB required for normal build). Installing uncompressed binary (~46 MB) may brick your router. Please use --compressed instead."
fi

VARIANT_LABEL="Normal (Uncompressed ~46MB)"
[ "$WANT_COMPRESSED" = "1" ] && VARIANT_LABEL="Compressed (UPX Lite ~9.5-12.5MB)"

printf "  Variant:         ${YELLOW}%s${NC}\n" "$VARIANT_LABEL"
printf "  Active Target:   ${YELLOW}%s${NC}\n\n" "${SERVICE_NAME:-manual/none}"

# Resolve download filename and URL (normalizing release tag)
SUFFIX=""
[ "$WANT_COMPRESSED" = "1" ] && SUFFIX="-compressed"

if [ -n "$REQ_TAG" ]; then
    case "$REQ_TAG" in
        v*) REQ_TAG_FULL="$REQ_TAG" ;;
        *)  REQ_TAG_FULL="v$REQ_TAG" ;;
    esac
    REQ_VER="${REQ_TAG_FULL#v}"
    FILE_NAME="sing-box-extended-lite-${REQ_VER}-linux-${ARCH}${SUFFIX}.tar.gz"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${REQ_TAG_FULL}/${FILE_NAME}"
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
rm -f "$FILE_NAME"

EXTRACTED_BIN=$(find "$WORK_DIR" -type f -name "sing-box" | head -n 1)
if [ -z "$EXTRACTED_BIN" ]; then
    fail "Executable 'sing-box' not found in downloaded archive."
fi

stop_services() {
    if [ -n "$ZB_SERVICE" ] && "$INIT_DIR/$ZB_SERVICE" status >/dev/null 2>&1; then
        printf "${CYAN}[*] Stopping %s...${NC}\n" "$ZB_SERVICE"
        "$INIT_DIR/$ZB_SERVICE" stop >/dev/null 2>&1 || true
        WAS_ZB_RUNNING=1
    fi
    if [ -n "$SERVICE_NAME" ] && "$INIT_DIR/$SERVICE_NAME" status >/dev/null 2>&1; then
        printf "${CYAN}[*] Stopping %s...${NC}\n" "$SERVICE_NAME"
        "$INIT_DIR/$SERVICE_NAME" stop >/dev/null 2>&1 || true
        WAS_SERVICE_RUNNING=1
    fi
    killall sing-box >/dev/null 2>&1 || true
    killall sing-box-core >/dev/null 2>&1 || true
    SERVICE_STOPPED=1
    sleep 1
}

restart_services() {
    [ "$SERVICE_STOPPED" != "1" ] && return 0
    if [ -n "$SERVICE_NAME" ] && [ "$WAS_SERVICE_RUNNING" = "1" ]; then
        printf "${CYAN}[*] Starting %s...${NC}\n" "$SERVICE_NAME"
        "$INIT_DIR/$SERVICE_NAME" start >/dev/null 2>&1 || printf "${YELLOW}[!] Warning: Failed to restart %s.${NC}\n" "$SERVICE_NAME"
    fi
    if [ -n "$ZB_SERVICE" ] && [ "$WAS_ZB_RUNNING" = "1" ]; then
        printf "${CYAN}[*] Starting %s...${NC}\n" "$ZB_SERVICE"
        "$INIT_DIR/$ZB_SERVICE" start >/dev/null 2>&1 || printf "${YELLOW}[!] Warning: Failed to restart %s.${NC}\n" "$ZB_SERVICE"
    fi
    SERVICE_STOPPED=0
    sleep 2
}

INSTALL_STARTED=1
stop_services

# Backup existing binaries and cache
if [ -f "$DEST_BIN" ]; then
    cp -f "$DEST_BIN" "$BACKUP_BIN"
    HAD_BACKUP_BIN=1
fi
if [ -f "$REAL_BIN" ]; then
    cp -f "$REAL_BIN" "$BACKUP_REAL"
    HAD_BACKUP_REAL=1
fi
if [ -f "$VERSION_CACHE" ]; then
    cp -f "$VERSION_CACHE" "$BACKUP_CACHE"
    HAD_BACKUP_CACHE=1
fi

if [ "$WANT_COMPRESSED" = "1" ]; then
    # Compressed variant: install to REAL_BIN atomically and install smart version-cache wrapper
    mkdir -p "$(dirname "$REAL_BIN")"
    cp -f "$EXTRACTED_BIN" "$STAGE_REAL"
    chmod +x "$STAGE_REAL"

    # Strict execution validation BEFORE moving into production paths
    VALIDATION_BANNER=$("$STAGE_REAL" version 2>/dev/null) || fail "Installed sing-box failed execution test."
    if [ -z "$VALIDATION_BANNER" ] || ! echo "$VALIDATION_BANNER" | grep -qi "sing-box"; then
        fail "Installed sing-box failed binary validation."
    fi

    REAL_BIN_TOUCHED=1
    mv -f "$STAGE_REAL" "$REAL_BIN"

    # Populate version cache only after confirmed validation
    CACHE_TOUCHED=1
    printf "%s\n" "$VALIDATION_BANNER" > "$VERSION_CACHE"
    chmod 644 "$VERSION_CACHE" 2>/dev/null || true

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
    DEST_BIN_TOUCHED=1
    mv -f "$STAGE_BIN" "$DEST_BIN"
else
    # Normal uncompressed variant: direct ELF, no wrapper
    cp -f "$EXTRACTED_BIN" "$STAGE_BIN"
    chmod +x "$STAGE_BIN"

    # Strict execution validation BEFORE moving into production paths
    VALIDATION_BANNER=$("$STAGE_BIN" version 2>/dev/null) || fail "Installed sing-box failed execution test."
    if [ -z "$VALIDATION_BANNER" ] || ! echo "$VALIDATION_BANNER" | grep -qi "sing-box"; then
        fail "Installed sing-box failed binary validation."
    fi

    DEST_BIN_TOUCHED=1
    mv -f "$STAGE_BIN" "$DEST_BIN"
    rm -f "$REAL_BIN" "$VERSION_CACHE"
fi

NEW_BANNER=$(echo "$VALIDATION_BANNER" | head -n 1)
NEW_VER=$(echo "$NEW_BANNER" | awk '{print $NF}')
TARGET_FILE="$DEST_BIN"
[ "$WANT_COMPRESSED" = "1" ] && TARGET_FILE="$REAL_BIN"

BIN_SIZE_MB=$(ls -lhL "$TARGET_FILE" 2>/dev/null | awk '{print $5}')
FLASH_FREE_KB=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}' | tr -cd '0-9')
[ -n "$FLASH_FREE_KB" ] && FLASH_FREE_DISP="$(( FLASH_FREE_KB / 1024 )) MB" || FLASH_FREE_DISP="n/a"

RAM_FREE_MB=$(get_ram_free_mb)
[ -n "$RAM_FREE_MB" ] && RAM_FREE_DISP="${RAM_FREE_MB} MB" || RAM_FREE_DISP="n/a"

restart_services
INSTALL_SUCCESS=1
cleanup
rm -f "$BACKUP_BIN" "$BACKUP_REAL" "$BACKUP_CACHE"

printf "\n${GREEN}[+] Installation Successful!${NC}\n"
printf "  Version:       ${YELLOW}%s${NC} -> ${GREEN}%s${NC}\n" "${CURRENT_VER:-n/a}" "$NEW_VER"
printf "  Binary Size:   ${GREEN}%s${NC} (%s)\n" "${BIN_SIZE_MB:-n/a}" "$VARIANT_LABEL"
printf "  Free Flash:    ${GREEN}%s${NC}\n" "$FLASH_FREE_DISP"
printf "  Free RAM:      ${GREEN}%s${NC}\n" "$RAM_FREE_DISP"
printf "${CYAN}====================================================${NC}\n\n"
