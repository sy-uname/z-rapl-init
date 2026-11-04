#!/usr/bin/env bash

set -euo pipefail

MY_NAME=$(basename "$0")
readonly MY_NAME
readonly RC_OK=0
readonly RC_ERROR=1
readonly RC_BAD_OPT=2
readonly TOERROR="/dev/stderr"

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

BIN_DIR="/usr/local/sbin"
CONFIG_DIR="/etc/default"
readonly DEFAULT_CONFIG_FILE="z-rapl-init.conf"
SYSTEMD_DIR="/etc/systemd/system"
DROPIN_DIR="$SYSTEMD_DIR/thermald.service.d"

FORCE_CONFIG=false

log() {
    printf '%s: %s\n' "$MY_NAME" "$*"
}

log_error() {
    printf '%s: ERROR: %s\n' "$MY_NAME" "$*" >"$TOERROR"
}

error() {
    local RC=${2:-$RC_ERROR}
    log_error "$1"
    exit "$RC"
}

do_check_bash(){
    if ! bash -n "$1"; then
        error "Invalid Bash syntax in: $1"
    fi
}

usage() {
    local RC=${1:-$RC_OK}
    echo "Usage: sudo ./install.sh [-f|--force-config] [-c|--config DIR] [-h|--help]"
    exit "$RC"
}

if ! PARSED=$(getopt -o "c:fh" --long force-config,config:,help -- "$@"); then
    exit $RC_BAD_OPT
fi

eval set -- "$PARSED"

while true; do
    case "$1" in
        --help|-h)
            shift
            usage
            ;;
        --force-config|-f)
            FORCE_CONFIG=true
            shift
            ;;
        --config|-c)
            CONFIG_DIR="$2"
            if [[ ! -d "$CONFIG_DIR" ]]; then
                log_error "--config must specify an existing directory for the configuration file"
                usage $RC_BAD_OPT
            fi
            shift 2
            log "Configuration destination: $CONFIG_DIR"
            ;;
        --)
            shift
            break
            ;;
        *)
            usage $RC_BAD_OPT
            ;;
    esac
done

(( $# <= 0 )) || {
    error "Unexpected positional arguments: $*" $RC_BAD_OPT
}

# Validate source files
for file in \
    z-rapl-init \
    "$DEFAULT_CONFIG_FILE" \
    z-rapl-init.service \
    thermald.conf ## aka 10-z-rapl-init.conf
do
    [[ -f "$SOURCE_DIR/$file" ]] || {
        error "Missing source file: $file"
    }
done

do_check_bash "$SOURCE_DIR/z-rapl-init"
do_check_bash "$SOURCE_DIR/$DEFAULT_CONFIG_FILE"
do_check_bash "$SOURCE_DIR/install.sh"

if [[ ${EUID} -ne 0 ]]; then
    error "Run with sudo"
fi

# Install executable
install -m 755 \
    "$SOURCE_DIR/z-rapl-init" \
    "$BIN_DIR/z-rapl-init"

# Install configuration
if [[ ! -e "$CONFIG_DIR/$DEFAULT_CONFIG_FILE" ]] || "$FORCE_CONFIG"; then
    install -m 644 \
        "$SOURCE_DIR/$DEFAULT_CONFIG_FILE" \
        "$CONFIG_DIR/$DEFAULT_CONFIG_FILE"
else
    log "Keeping existing configuration"
fi

# Install systemd files
install -m 644 \
    "$SOURCE_DIR/z-rapl-init.service" \
    "$SYSTEMD_DIR/z-rapl-init.service"

install -d -m 755 "$DROPIN_DIR"

install -m 644 \
    "$SOURCE_DIR/thermald.conf" \
    "$DROPIN_DIR/10-z-rapl-init.conf"

# Activate for future boots
systemctl daemon-reload
systemctl enable z-rapl-init.service

log "z-rapl-init installed successfully"
log "Changes will take effect on next boot"