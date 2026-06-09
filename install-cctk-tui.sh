#!/usr/bin/env bash
# install-cctk-tui.sh — Installs Dell Command Configure (cctk) + BIOS TUI
# Supports: Debian 11 / 12 / 13, Ubuntu 20.04 / 22.04 / 24.04
# Run as root: sudo bash install-cctk-tui.sh

set -uo pipefail

# ── config ────────────────────────────────────────────────────────────────────

TUI_INSTALL_PATH="/usr/local/bin/cctk-tui"
CCTK_DIR="/opt/dell/dcc"
CCTK_BIN="$CCTK_DIR/cctk"
WORK_DIR="/tmp/cctk-install-$$"
LOG="/tmp/cctk-install.log"

# Dell's download page for Command Configure
DELL_DCC_URL="https://www.dell.com/support/kbdoc/en-us/000178000/dell-command-configure"

# Known direct download URLs (update if Dell changes them)
# Format: "label|url"
KNOWN_PACKAGES=(
    "v5.2 Ubuntu 22/24 amd64|https://dl.dell.com/FOLDER11971237M/1/command-configure_5.2.0-5.ubuntu22_amd64.tar.gz"
    "v5.1 Ubuntu 20/22 amd64|https://dl.dell.com/FOLDER11560885M/1/command-configure_5.1.0-6.ubuntu20_amd64.tar.gz"
    "v4.11 Ubuntu 22 amd64|https://dl.dell.com/FOLDER10469726M/1/command-configure_4.11.0-6.ubuntu22_amd64.tar.gz"
)

# ── colours ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG"; }
ok()      { echo -e "${GREEN}[ OK ]${RESET}  $*" | tee -a "$LOG"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG"; }
err()     { echo -e "${RED}[ERR ]${RESET}  $*" | tee -a "$LOG"; }
die()     { err "$*"; exit 1; }
hdr()     { echo -e "\n${BOLD}━━━ $* ━━━${RESET}" | tee -a "$LOG"; }

# ── preflight ─────────────────────────────────────────────────────────────────

preflight() {
    hdr "Preflight checks"

    [[ $EUID -ne 0 ]] && die "Must be run as root. Use: sudo bash $0"
    ok "Running as root"

    # Check architecture
    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    if [[ "$arch" != "amd64" && "$arch" != "x86_64" ]]; then
        die "Unsupported architecture: $arch (cctk requires amd64/x86_64)"
    fi
    ok "Architecture: $arch"

    # Detect distro
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        info "Detected: $PRETTY_NAME"
        OS_ID="${ID:-unknown}"
        OS_VER="${VERSION_ID:-0}"
    else
        warn "Cannot detect OS — proceeding anyway"
        OS_ID="unknown"
        OS_VER="0"
    fi

    # Check this is a Dell machine (warn only — don't block)
    local sys_vendor=""
    [[ -f /sys/class/dmi/id/sys_vendor ]] && sys_vendor=$(cat /sys/class/dmi/id/sys_vendor)
    if echo "$sys_vendor" | grep -qi "dell"; then
        ok "Dell hardware detected: $sys_vendor"
    else
        warn "Not a Dell machine ($sys_vendor) — cctk may not work"
        read -rp "Continue anyway? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || die "Aborted."
    fi

    mkdir -p "$WORK_DIR"
    ok "Work directory: $WORK_DIR"
}

# ── dependencies ──────────────────────────────────────────────────────────────

install_deps() {
    hdr "Installing dependencies"

    apt-get update -qq | tee -a "$LOG"

    local deps=(dialog wget curl libssl1.1 apt-transport-https)

    # libssl1.1 is not in Debian 12+ repos — handle separately
    local need_libssl=false
    if ! dpkg -l libssl1.1 2>/dev/null | grep -q "^ii"; then
        need_libssl=true
    fi

    # Install what's available in repos first (skip libssl1.1 if missing)
    local repo_deps=(dialog wget curl apt-transport-https)
    info "Installing: ${repo_deps[*]}"
    apt-get install -y "${repo_deps[@]}" >> "$LOG" 2>&1 || die "apt-get install failed"
    ok "Base dependencies installed"

    # Handle libssl1.1 for newer distros
    if $need_libssl; then
        install_libssl1
    else
        ok "libssl1.1 already present"
    fi
}

install_libssl1() {
    info "libssl1.1 not found in repos — fetching from Debian 11 security archive"

    local libssl_url="http://security.debian.org/debian-security/pool/updates/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb"
    local libssl_deb="$WORK_DIR/libssl1.1.deb"

    wget -q --show-progress -O "$libssl_deb" "$libssl_url" 2>&1 | tee -a "$LOG" \
        || die "Failed to download libssl1.1"

    dpkg -i "$libssl_deb" >> "$LOG" 2>&1 \
        || die "Failed to install libssl1.1"

    ok "libssl1.1 installed"
}

# ── cctk install ──────────────────────────────────────────────────────────────

install_cctk() {
    hdr "Installing Dell Command Configure (cctk)"

    # Already installed?
    if [[ -x "$CCTK_BIN" ]]; then
        local ver
        ver=$("$CCTK_BIN" --Version 2>/dev/null | head -1 || echo "unknown")
        info "cctk already installed: $ver"
        read -rp "Reinstall/upgrade? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || { ok "Skipping cctk install"; return; }
    fi

    # Let user pick package version
    echo ""
    echo -e "${BOLD}Available packages:${RESET}"
    local i=1
    for entry in "${KNOWN_PACKAGES[@]}"; do
        local label="${entry%%|*}"
        echo "  $i) $label"
        ((i++))
    done
    echo "  $i) Enter custom URL"
    echo "  $((i+1)) Open Dell support page (then enter URL manually)"
    echo ""

    local choice url=""
    read -rp "Select package [1]: " choice
    choice="${choice:-1}"

    if [[ "$choice" -ge 1 && "$choice" -le ${#KNOWN_PACKAGES[@]} ]] 2>/dev/null; then
        url="${KNOWN_PACKAGES[$((choice-1))]##*|}"
    elif [[ "$choice" -eq $i ]]; then
        read -rp "Enter direct download URL (.tar.gz): " url
        [[ -z "$url" ]] && die "No URL provided"
    elif [[ "$choice" -eq $((i+1)) ]]; then
        echo ""
        info "Open this URL in a browser, find the Linux .tar.gz download link,"
        info "and paste it here: $DELL_DCC_URL"
        echo ""
        read -rp "Paste direct .tar.gz URL: " url
        [[ -z "$url" ]] && die "No URL provided"
    else
        die "Invalid selection"
    fi

    info "Downloading: $url"
    local tarball="$WORK_DIR/command-configure.tar.gz"
    wget -q --show-progress -O "$tarball" "$url" 2>&1 | tee -a "$LOG" \
        || die "Download failed. Check URL or network connectivity."

    info "Extracting..."
    tar -zxf "$tarball" -C "$WORK_DIR" >> "$LOG" 2>&1 \
        || die "Failed to extract tarball"

    # Install debs in the correct order
    info "Installing HAPI driver..."
    local hapi_deb
    hapi_deb=$(find "$WORK_DIR" -name "srvadmin-hapi*.deb" | head -1)
    [[ -z "$hapi_deb" ]] && die "srvadmin-hapi .deb not found in package"
    dpkg -i "$hapi_deb" >> "$LOG" 2>&1 || apt-get install -f -y >> "$LOG" 2>&1

    info "Installing Dell Command Configure..."
    local cctk_deb
    cctk_deb=$(find "$WORK_DIR" -name "command-configure*.deb" | head -1)
    [[ -z "$cctk_deb" ]] && die "command-configure .deb not found in package"
    dpkg -i "$cctk_deb" >> "$LOG" 2>&1 || true
    apt-get install -f -y >> "$LOG" 2>&1

    # Verify
    if [[ -x "$CCTK_BIN" ]]; then
        local ver
        ver=$("$CCTK_BIN" --Version 2>/dev/null | head -1 || echo "unknown")
        ok "cctk installed: $ver"
    else
        die "cctk binary not found at $CCTK_BIN after install"
    fi
}

# ── TUI install ───────────────────────────────────────────────────────────────

install_tui() {
    hdr "Installing BIOS TUI script"

    local tui_source=""

    # Is this script running from the same directory as cctk-tui.sh?
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$script_dir/cctk-tui.sh" ]]; then
        tui_source="$script_dir/cctk-tui.sh"
        info "Found cctk-tui.sh next to installer: $tui_source"
    else
        # Ask user where it is
        echo ""
        warn "cctk-tui.sh not found next to this installer."
        read -rp "Path to cctk-tui.sh [or press Enter to skip]: " tui_source
        if [[ -z "$tui_source" ]]; then
            warn "Skipping TUI install — copy cctk-tui.sh to $TUI_INSTALL_PATH manually"
            return
        fi
        [[ ! -f "$tui_source" ]] && die "File not found: $tui_source"
    fi

    cp "$tui_source" "$TUI_INSTALL_PATH"
    chmod +x "$TUI_INSTALL_PATH"
    ok "TUI installed to $TUI_INSTALL_PATH"
    info "Run with: sudo cctk-tui"
}

# ── optional: desktop shortcut ───────────────────────────────────────────────

install_shortcut() {
    # Only offer if a display manager is present
    if ! command -v xterm &>/dev/null && ! command -v x-terminal-emulator &>/dev/null; then
        return
    fi

    hdr "Desktop shortcut (optional)"
    read -rp "Create a desktop shortcut for cctk-tui? [y/N] " confirm
    [[ "${confirm,,}" != "y" ]] && return

    local desktop_file="/usr/share/applications/cctk-tui.desktop"
    cat > "$desktop_file" << EOF
[Desktop Entry]
Name=BIOS Configure (cctk-tui)
Comment=Dell Command Configure TUI
Exec=pkexec $TUI_INSTALL_PATH
Icon=preferences-system
Terminal=true
Type=Application
Categories=System;Settings;
EOF
    ok "Desktop shortcut created: $desktop_file"
}

# ── cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
    rm -rf "$WORK_DIR"
}

# ── summary ───────────────────────────────────────────────────────────────────

summary() {
    hdr "Installation complete"
    echo ""
    [[ -x "$CCTK_BIN"        ]] && ok "cctk:    $CCTK_BIN" || warn "cctk:    NOT installed"
    [[ -x "$TUI_INSTALL_PATH" ]] && ok "TUI:     $TUI_INSTALL_PATH" || warn "TUI:     NOT installed"
    echo ""
    echo -e "${BOLD}Usage:${RESET}"
    echo "  sudo cctk-tui              # launch the TUI"
    echo "  sudo $CCTK_BIN --help     # raw cctk CLI"
    echo ""
    echo -e "Log saved to: $LOG"
    echo ""
}

# ── main ──────────────────────────────────────────────────────────────────────

trap cleanup EXIT

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║   Dell Command Configure + BIOS TUI Installer   ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

preflight
install_deps
install_cctk
install_tui
install_shortcut
summary
