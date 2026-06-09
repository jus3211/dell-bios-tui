#!/usr/bin/env bash
# cctk-tui.sh — Dell Command Configure TUI
# Requires: dialog (apt install dialog)
# Run as root or with sudo: sudo bash cctk-tui.sh

set -uo pipefail

CCTK="/opt/dell/dcc/cctk"
TITLE="Dell Command Configure — BIOS TUI"
LOGFILE="/tmp/cctk-tui.log"
SETUP_PWD=""
BIOS_CACHE_FILE="/tmp/cctk-tui-cache.ini"

# Associative array holding cached BIOS values (key=lowercase option name)
declare -A BIOS_CACHE

# ── helpers ──────────────────────────────────────────────────────────────────

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root (sudo bash $0)" >&2
        exit 1
    fi
}

require_dialog() {
    if ! command -v dialog &>/dev/null; then
        echo "Installing dialog..."
        apt-get install -y dialog
    fi
}

require_cctk() {
    if [[ ! -x "$CCTK" ]]; then
        dialog --title "Error" --msgbox \
            "cctk not found at $CCTK\n\nInstall Dell Command Configure first:\nhttps://www.dell.com/support/kbdoc/en-us/000178000" \
            10 60
        exit 1
    fi
}

log() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$LOGFILE"
}

run_cctk() {
    local args=("$@")
    log "RUN: $CCTK ${args[*]}"
    local output
    output=$("$CCTK" "${args[@]}" 2>&1) || true
    local rc=$?
    log "OUT: $output (rc=$rc)"
    echo "$output"
    return $rc
}

get_val() {
    local opt="$1"
    local out
    if [[ -n "$SETUP_PWD" ]]; then
        out=$(run_cctk "--${opt}" "--ValSetupPwd=${SETUP_PWD}" 2>&1 || true)
    else
        out=$(run_cctk "--${opt}" 2>&1 || true)
    fi
    echo "$out"
}

set_val() {
    local opt="$1"
    local val="$2"
    local out
    if [[ -n "$SETUP_PWD" ]]; then
        out=$(run_cctk "--${opt}=${val}" "--ValSetupPwd=${SETUP_PWD}" 2>&1 || true)
    else
        out=$(run_cctk "--${opt}=${val}" 2>&1 || true)
    fi
    echo "$out"
}

show_result() {
    local title="$1"
    local msg="$2"
    dialog --title "$title" --msgbox "$msg" 12 65
}

# ── BIOS cache ────────────────────────────────────────────────────────────────

load_bios_cache() {
    dialog --title "Loading..." --infobox "Reading current BIOS settings..." 5 45
    log "Loading BIOS cache"

    local dump_args=("--outfile=${BIOS_CACHE_FILE}")
    [[ -n "$SETUP_PWD" ]] && dump_args+=("--ValSetupPwd=${SETUP_PWD}")
    "$CCTK" "${dump_args[@]}" > /dev/null 2>&1 || true

    BIOS_CACHE=()
    if [[ ! -f "$BIOS_CACHE_FILE" ]]; then
        log "Cache file not created — falling back to empty cache"
        return
    fi

    while IFS='=' read -r key val; do
        # Skip comments, blank lines, section headers
        [[ "$key" =~ ^[[:space:]]*";"  ]] && continue
        [[ "$key" =~ ^[[:space:]]*"#"  ]] && continue
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^\[.*\]$ ]] && continue
        # Strip leading/trailing whitespace
        key="${key// /}"
        val="${val%% *}"  # take only first word (handles e.g. BootOrder lines)
        # Store lowercase key for case-insensitive lookup
        BIOS_CACHE["${key,,}"]="$val"
    done < "$BIOS_CACHE_FILE"

    log "Cache loaded: ${#BIOS_CACHE[@]} entries"
}

# Return cached value for an option (case-insensitive key lookup)
bios_get() {
    local key="${1,,}"
    echo "${BIOS_CACHE[$key]:-}"
}

# Update cache after a successful set
bios_cache_set() {
    local key="${1,,}"
    local val="$2"
    BIOS_CACHE["$key"]="$val"
}

# ── BIOS password detection & prompt ─────────────────────────────────────────

PASSWORD_REQUIRED_CODES=(169 173)

cctk_needs_password() {
    local read_out write_out write_rc current_val
    read_out=$("$CCTK" --Asset 2>&1) || true
    current_val=$(echo "$read_out" | grep -oP "(?i)(?<=Asset=).*" | head -1 || true)
    write_out=$("$CCTK" "--Asset=${current_val}" 2>&1) || true
    write_rc=$?
    log "PWCHECK write: rc=$write_rc out=$write_out"
    for code in "${PASSWORD_REQUIRED_CODES[@]}"; do
        [[ $write_rc -eq $code ]] && return 0
    done
    if echo "$write_out" | grep -qiE "password|passwrd|pwd required|authentication|setup password"; then
        return 0
    fi
    return 1
}

validate_password() {
    local pwd="$1"
    local val_out val_rc
    val_out=$("$CCTK" --SvcTag "--ValSetupPwd=${pwd}" 2>&1) || true
    val_rc=$?
    log "PWVALIDATE: rc=$val_rc out=$val_out"
    for code in "${PASSWORD_REQUIRED_CODES[@]}"; do
        [[ $val_rc -eq $code ]] && return 1
    done
    if echo "$val_out" | grep -qiE "invalid|incorrect|wrong|failed|error"; then
        return 1
    fi
    return 0
}

detect_and_prompt_password() {
    dialog --title "Checking BIOS..." --infobox "Probing cctk for password requirement..." 5 50
    sleep 0.3

    if cctk_needs_password; then
        log "Password required detected"
        local pwd dlg_rc
        while true; do
            pwd=$(dialog --title "BIOS Setup Password Required" \
                --insecure --passwordbox \
"A BIOS setup password is set on this machine.\n\nEnter the setup password to continue.\n(Commands will use --ValSetupPwd automatically)" \
                10 58 "" 3>&1 1>&2 2>&3) || true
            dlg_rc=$?
            if [[ $dlg_rc -ne 0 ]]; then
                dialog --title "Warning" --msgbox \
"No password entered.\n\nRead-only commands will work, but SET\ncommands will fail until a password is set.\n\nYou can set it later from the main menu." \
                    9 52
                SETUP_PWD=""
                return
            fi
            if [[ -z "$pwd" ]]; then
                dialog --title "Error" --msgbox "Password cannot be empty. Try again." 6 40
                continue
            fi
            dialog --title "Validating..." --infobox "Verifying password..." 5 35
            if validate_password "$pwd"; then
                SETUP_PWD="$pwd"
                log "Password validated successfully"
                dialog --title "Password Accepted ✓" --infobox \
"Password verified. Loading BIOS settings..." 5 45
                sleep 0.5
                return
            else
                dialog --title "Incorrect Password" --msgbox \
"The password was not accepted.\n\nPlease try again." 7 45
            fi
        done
    else
        log "No password required"
        SETUP_PWD=""
    fi
}

prompt_password() {
    local pwd dlg_rc
    pwd=$(dialog --title "BIOS Setup Password" \
        --insecure --passwordbox "Enter BIOS setup password (leave blank to clear):" \
        8 52 "" 3>&1 1>&2 2>&3) || return
    if [[ -z "$pwd" ]]; then
        SETUP_PWD=""
        show_result "Password Cleared" "Password cleared. Commands will run without --ValSetupPwd."
        return
    fi
    dialog --title "Validating..." --infobox "Verifying password..." 5 35
    if validate_password "$pwd"; then
        SETUP_PWD="$pwd"
        log "Password set manually and validated"
        show_result "Password Set ✓" "Password verified and stored for this session."
    else
        show_result "Incorrect Password" "The password was not accepted by cctk.\nPassword not changed."
    fi
}

# ── generic get/set dialogs ───────────────────────────────────────────────────

dialog_get() {
    local opt="$1" desc="$2"
    local out
    out=$(get_val "$opt")
    show_result "Get: --${opt}" "Option : --${opt}\nDesc   : ${desc}\n\nResult :\n${out}"
}

# dialog_set_select OPT DESC choice1 choice2 ...
# Marks the current cached value with [current] in the description column
dialog_set_select() {
    local opt="$1" desc="$2"
    shift 2
    local choices=("$@")
    local current
    current=$(bios_get "$opt")
    local menu_args=()
    for c in "${choices[@]}"; do
        if [[ "${c,,}" == "${current,,}" ]]; then
            menu_args+=("$c" "[current]")
        else
            menu_args+=("$c" "")
        fi
    done
    local val
    val=$(dialog --title "Set: --${opt}" \
        --default-item "${current}" \
        --menu "${desc}\n\nCurrent: ${current:-unknown}" \
        20 58 10 "${menu_args[@]}" \
        3>&1 1>&2 2>&3) || return
    local out
    out=$(set_val "$opt" "$val")
    # Update cache on success
    if ! echo "$out" | grep -qiE "error|failed|invalid|password"; then
        bios_cache_set "$opt" "$val"
    fi
    show_result "Set: --${opt}=${val}" "$out"
}

dialog_set_text() {
    local opt="$1" desc="$2"
    local current
    current=$(bios_get "$opt")
    local val
    val=$(dialog --title "Set: --${opt}" \
        --inputbox "${desc}\n\nCurrent: ${current:-empty}" \
        10 55 "$current" \
        3>&1 1>&2 2>&3) || return
    [[ -z "$val" ]] && return
    local out
    out=$(set_val "$opt" "$val")
    if ! echo "$out" | grep -qiE "error|failed|invalid|password"; then
        bios_cache_set "$opt" "$val"
    fi
    show_result "Set: --${opt}=${val}" "$out"
}

dialog_readonly() {
    local opt="$1" desc="$2"
    local cached
    cached=$(bios_get "$opt")
    local out
    out=$(get_val "$opt")
    show_result "Get: --${opt}" "Option : --${opt}\nDesc   : ${desc}\n\nCached : ${cached:-unknown}\nLive   :\n${out}"
}

# ── category menus ───────────────────────────────────────────────────────────

menu_power() {
    while true; do
        local choice
        choice=$(dialog --title "$TITLE" --menu "Power Management" 22 65 12 \
            "AcPwrRcvry"      "AC power recovery  [$(bios_get AcPwrRcvry)]" \
            "AutoOn"          "Auto power-on schedule  [$(bios_get AutoOn)]" \
            "AutoOnHr"        "Auto power-on hour  [$(bios_get AutoOnHr)]" \
            "AutoOnMn"        "Auto power-on minute  [$(bios_get AutoOnMn)]" \
            "AutoRtcRecovery" "Auto RTC wake  [$(bios_get AutoRtcRecovery)]" \
            "BlockSleep"      "Block S3 sleep  [$(bios_get BlockSleep)]" \
            "DeepSleepCtrl"   "Deep sleep control  [$(bios_get DeepSleepCtrl)]" \
            "PowerWarn"       "Power warning  [$(bios_get PowerWarn)]" \
            "WakeOnLan"       "Wake on LAN  [$(bios_get WakeOnLan)]" \
            "UsbWake"         "Wake from USB  [$(bios_get UsbWake)]" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            AcPwrRcvry)      dialog_set_select AcPwrRcvry      "AC power recovery" Off On Last ;;
            AutoOn)          dialog_set_select AutoOn           "Auto power-on schedule" Disabled AnyDay Weekdays Monday Tuesday Wednesday Thursday Friday Saturday Sunday ;;
            AutoOnHr)        dialog_set_text   AutoOnHr         "Auto power-on hour (0-23)" ;;
            AutoOnMn)        dialog_set_text   AutoOnMn         "Auto power-on minute (0-59)" ;;
            AutoRtcRecovery) dialog_set_select AutoRtcRecovery  "Auto RTC wake" Enabled Disabled ;;
            BlockSleep)      dialog_set_select BlockSleep       "Block S3 sleep" Enabled Disabled ;;
            DeepSleepCtrl)   dialog_set_select DeepSleepCtrl   "Deep sleep control" Disabled S4S5 S5Only ;;
            PowerWarn)       dialog_set_select PowerWarn        "Power warning" Enabled Disabled ;;
            WakeOnLan)       dialog_set_select WakeOnLan        "Wake on LAN" Disabled LanOnly LanWithPxeBoot ;;
            UsbWake)         dialog_set_select UsbWake          "Wake from USB" Enabled Disabled ;;
        esac
    done
}

menu_security() {
    while true; do
        local choice
        choice=$(dialog --title "$TITLE" --menu "Security" 24 65 14 \
            "SecureBoot"            "UEFI Secure Boot  [$(bios_get SecureBoot)]" \
            "SecureBootMode"        "Secure Boot mode  [$(bios_get SecureBootMode)]" \
            "TpmSecurity"           "TPM chip  [$(bios_get TpmSecurity)]" \
            "TpmPpiClearOverride"   "TPM PPI clear override  [$(bios_get TpmPpiClearOverride)]" \
            "StrongPassword"        "Require strong passwords  [$(bios_get StrongPassword)]" \
            "PasswordBypass"        "Password bypass  [$(bios_get PasswordBypass)]" \
            "PasswordLock"          "Lock password changes  [$(bios_get PasswordLock)]" \
            "AdminSetupLockout"     "Admin setup lockout  [$(bios_get AdminSetupLockout)]" \
            "MasterPasswordLockout" "Master password lockout  [$(bios_get MasterPasswordLockout)]" \
            "SmmSecurityMitigation" "SMM mitigation  [$(bios_get SmmSecurityMitigation)]" \
            "KernelDma"             "Kernel DMA protection  [$(bios_get KernelDma)]" \
            "PreBootDma"            "Pre-boot DMA  [$(bios_get PreBootDma)]" \
            "NonAdminPsidRevert"    "Non-admin PSID revert  [$(bios_get NonAdminPsidRevert)]" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            SecureBoot)            dialog_set_select SecureBoot            "UEFI Secure Boot" Enabled Disabled ;;
            SecureBootMode)        dialog_set_select SecureBootMode        "Secure Boot mode" AuditMode DeployedMode ;;
            TpmSecurity)           dialog_set_select TpmSecurity           "TPM security" Disabled Enabled EnabledActivated EnabledDeactivated ;;
            TpmPpiClearOverride)   dialog_set_select TpmPpiClearOverride   "TPM PPI clear override" Disabled Enabled ;;
            StrongPassword)        dialog_set_select StrongPassword        "Require strong passwords" Enabled Disabled ;;
            PasswordBypass)        dialog_set_select PasswordBypass        "Password bypass" Disabled Reboot ;;
            PasswordLock)          dialog_set_select PasswordLock          "Lock password changes" Enabled Disabled ;;
            AdminSetupLockout)     dialog_set_select AdminSetupLockout     "Admin setup lockout" Enabled Disabled ;;
            MasterPasswordLockout) dialog_set_select MasterPasswordLockout "Master password lockout" Enabled Disabled ;;
            SmmSecurityMitigation) dialog_set_select SmmSecurityMitigation "SMM security mitigation" Enabled Disabled ;;
            KernelDma)             dialog_set_select KernelDma             "Kernel DMA protection" Enabled Disabled ;;
            PreBootDma)            dialog_set_select PreBootDma            "Pre-boot DMA protection" Enabled Disabled ;;
            NonAdminPsidRevert)    dialog_set_select NonAdminPsidRevert    "Non-admin PSID revert" Enabled Disabled ;;
        esac
    done
}

menu_passwords() {
    while true; do
        local choice
        choice=$(dialog --title "$TITLE" --menu "Passwords" 14 65 5 \
            "SetupPwd"   "Set BIOS setup password" \
            "SysPwd"     "Set system password" \
            "HddPwd"     "Set HDD password" \
            "ValSetupPwd" "Validate setup password" \
            "ValSysPwd"  "Validate system password" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            SetupPwd)    dialog_set_text SetupPwd    "New BIOS setup password" ;;
            SysPwd)      dialog_set_text SysPwd      "New system password" ;;
            HddPwd)      dialog_set_text HddPwd      "New HDD password" ;;
            ValSetupPwd) dialog_set_text ValSetupPwd "Validate setup password" ;;
            ValSysPwd)   dialog_set_text ValSysPwd   "Validate system password" ;;
        esac
    done
}

menu_boot() {
    while true; do
        local choice
        choice=$(dialog --title "$TITLE" --menu "Boot" 22 65 12 \
            "Fastboot"             "Fast boot mode  [$(bios_get Fastboot)]" \
            "BootOrder"            "Get current boot order" \
            "UefiBootPathSecurity" "Boot path security  [$(bios_get UefiBootPathSecurity)]" \
            "FullScreenLogo"       "Full-screen logo  [$(bios_get FullScreenLogo)]" \
            "ExtPostTime"          "Extended POST time  [$(bios_get ExtPostTime)]" \
            "BootTimeVideo"        "Boot time video  [$(bios_get BootTimeVideo)]" \
            "UefiNwStack"          "UEFI network stack  [$(bios_get UefiNwStack)]" \
            "HttpsBootMode"        "HTTPS boot mode  [$(bios_get HttpsBootMode)]" \
            "NumLockLed"           "NumLock at boot  [$(bios_get NumLockLed)]" \
            "RptKeyErr"            "Report keyboard errors  [$(bios_get RptKeyErr)]" \
            "BiosRcvrFrmHdd"       "BIOS recovery from HDD  [$(bios_get BiosRcvrFrmHdd)]" \
            "AllowBiosDowngrade"   "Allow BIOS downgrade  [$(bios_get AllowBiosDowngrade)]" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            Fastboot)             dialog_set_select Fastboot             "Fast boot mode" Minimal Thorough Auto ;;
            BootOrder)            dialog_get        BootOrder            "Current boot order" ;;
            UefiBootPathSecurity) dialog_set_select UefiBootPathSecurity "UEFI boot path security" Never AlwaysExceptInternalHDD Always ;;
            FullScreenLogo)       dialog_set_select FullScreenLogo       "Full-screen logo" Enabled Disabled ;;
            ExtPostTime)          dialog_set_select ExtPostTime          "Extended POST time" 0s 5s 10s ;;
            BootTimeVideo)        dialog_set_select BootTimeVideo        "Boot time video" Enabled Disabled Auto ;;
            UefiNwStack)          dialog_set_select UefiNwStack          "UEFI network stack" Enabled Disabled ;;
            HttpsBootMode)        dialog_set_select HttpsBootMode        "HTTPS boot mode" Enabled Disabled AutoMode ;;
            NumLockLed)           dialog_set_select NumLockLed           "NumLock at boot" Enabled Disabled ;;
            RptKeyErr)            dialog_set_select RptKeyErr            "Report keyboard errors" Enabled Disabled ;;
            BiosRcvrFrmHdd)       dialog_set_select BiosRcvrFrmHdd       "BIOS recovery from HDD" Enabled Disabled ;;
            AllowBiosDowngrade)   dialog_set_select AllowBiosDowngrade   "Allow BIOS downgrade" Enabled Disabled ;;
        esac
    done
}

menu_cpu() {
    while true; do
        local choice
        choice=$(dialog --title "$TITLE" --menu "CPU / Performance" 18 65 9 \
            "Virtualization" "Intel VT-x  [$(bios_get Virtualization)]" \
            "VtForDirectIo"  "VT-d for direct I/O  [$(bios_get VtForDirectIo)]" \
            "Speedstep"      "Intel SpeedStep  [$(bios_get Speedstep)]" \
            "SpeedShift"     "Intel Speed Shift  [$(bios_get SpeedShift)]" \
            "TurboMode"      "Turbo Boost  [$(bios_get TurboMode)]" \
            "CStatesCtrl"    "CPU C-states  [$(bios_get CStatesCtrl)]" \
            "CpuCore"        "Active CPU cores  [$(bios_get CpuCore)]" \
            "CpuCount"       "Physical CPU count  [read-only]" \
            "CpuSpeed"       "Current CPU speed  [read-only]" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            Virtualization) dialog_set_select Virtualization "Intel VT-x" Enabled Disabled ;;
            VtForDirectIo)  dialog_set_select VtForDirectIo  "VT-d for direct I/O" Enabled Disabled ;;
            Speedstep)      dialog_set_select Speedstep      "Intel SpeedStep" Enabled Disabled ;;
            SpeedShift)     dialog_set_select SpeedShift     "Intel Speed Shift" Enabled Disabled ;;
            TurboMode)      dialog_set_select TurboMode      "Turbo Boost" Enabled Disabled ;;
            CStatesCtrl)    dialog_set_select CStatesCtrl    "CPU C-states" Enabled Disabled ;;
            CpuCore)        dialog_set_text   CpuCore        "Number of active cores" ;;
            CpuCount)       dialog_readonly   CpuCount       "Physical CPU count (read-only)" ;;
            CpuSpeed)       dialog_readonly   CpuSpeed       "Current CPU speed (read-only)" ;;
        esac
    done
}

menu_network() {
    while true; do
        local choice
        choice=$(dialog --title "$TITLE" --menu "Network" 12 65 4 \
            "EmbNic1"         "Embedded NIC 1  [$(bios_get EmbNic1)]" \
            "WirelessLan"     "Wireless LAN  [$(bios_get WirelessLan)]" \
            "BluetoothDevice" "Bluetooth  [$(bios_get BluetoothDevice)]" \
            "UefiNwStack"     "UEFI network stack  [$(bios_get UefiNwStack)]" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            EmbNic1)         dialog_set_select EmbNic1         "Embedded NIC 1" Disabled EnabledPxe EnabledNoPxe ;;
            WirelessLan)     dialog_set_select WirelessLan     "Wireless LAN" Enabled Disabled ;;
            BluetoothDevice) dialog_set_select BluetoothDevice "Bluetooth" Enabled Disabled ;;
            UefiNwStack)     dialog_set_select UefiNwStack     "UEFI network stack" Enabled Disabled ;;
        esac
    done
}

menu_usb() {
    while true; do
        local choice
        choice=$(dialog --title "$TITLE" --menu "USB Ports" 20 65 11 \
            "UsbPortsFront"  "All front USB  [$(bios_get UsbPortsFront)]" \
            "UsbPortsFront1" "Front USB port 1  [$(bios_get UsbPortsFront1)]" \
            "UsbPortsFront2" "Front USB port 2  [$(bios_get UsbPortsFront2)]" \
            "UsbPortsRear"   "All rear USB  [$(bios_get UsbPortsRear)]" \
            "UsbPortsRear30" "Rear USB 3.0  [$(bios_get UsbPortsRear30)]" \
            "RearUsbPort1"   "Rear USB port 1  [$(bios_get RearUsbPort1)]" \
            "RearUsbPort2"   "Rear USB port 2  [$(bios_get RearUsbPort2)]" \
            "RearUsbPort3"   "Rear USB port 3  [$(bios_get RearUsbPort3)]" \
            "RearUsbPort4"   "Rear USB port 4  [$(bios_get RearUsbPort4)]" \
            "UsbEmu"         "USB emulation  [$(bios_get UsbEmu)]" \
            "UsbWake"        "USB wake  [$(bios_get UsbWake)]" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            UsbPortsFront)  dialog_set_select UsbPortsFront  "All front USB" Enabled Disabled ;;
            UsbPortsFront1) dialog_set_select UsbPortsFront1 "Front USB port 1" Enabled Disabled ;;
            UsbPortsFront2) dialog_set_select UsbPortsFront2 "Front USB port 2" Enabled Disabled ;;
            UsbPortsRear)   dialog_set_select UsbPortsRear   "All rear USB" Enabled Disabled ;;
            UsbPortsRear30) dialog_set_select UsbPortsRear30 "Rear USB 3.0" Enabled Disabled ;;
            RearUsbPort1)   dialog_set_select RearUsbPort1   "Rear USB port 1" Enabled Disabled ;;
            RearUsbPort2)   dialog_set_select RearUsbPort2   "Rear USB port 2" Enabled Disabled ;;
            RearUsbPort3)   dialog_set_select RearUsbPort3   "Rear USB port 3" Enabled Disabled ;;
            RearUsbPort4)   dialog_set_select RearUsbPort4   "Rear USB port 4" Enabled Disabled ;;
            UsbEmu)         dialog_set_select UsbEmu         "USB emulation" Enabled Disabled ;;
            UsbWake)        dialog_set_select UsbWake        "USB wake" Enabled Disabled ;;
        esac
    done
}

menu_devices() {
    while true; do
        local choice
        choice=$(dialog --title "$TITLE" --menu "Onboard Devices" 18 65 8 \
            "IntegratedAudio"    "Integrated audio  [$(bios_get IntegratedAudio)]" \
            "Microphone"         "Internal microphone  [$(bios_get Microphone)]" \
            "InternalSpeaker"    "Internal speaker  [$(bios_get InternalSpeaker)]" \
            "EMMCDevice"         "eMMC storage  [$(bios_get EMMCDevice)]" \
            "EmbSataRaid"        "SATA mode  [$(bios_get EmbSataRaid)]" \
            "Sata0"              "SATA port 0  [$(bios_get Sata0)]" \
            "ChasIntrusion"      "Chassis intrusion  [$(bios_get ChasIntrusion)]" \
            "ChassisIntruStatus" "Chassis intrusion status  [read-only]" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            IntegratedAudio)    dialog_set_select IntegratedAudio    "Integrated audio" Enabled Disabled ;;
            Microphone)         dialog_set_select Microphone         "Internal microphone" Enabled Disabled ;;
            InternalSpeaker)    dialog_set_select InternalSpeaker    "Internal speaker" Enabled Disabled ;;
            EMMCDevice)         dialog_set_select EMMCDevice         "eMMC device" Enabled Disabled ;;
            EmbSataRaid)        dialog_set_select EmbSataRaid        "SATA mode" Ahci Raid ;;
            Sata0)              dialog_set_select Sata0              "SATA port 0" Enabled Disabled ;;
            ChasIntrusion)      dialog_set_select ChasIntrusion      "Chassis intrusion" Enabled Disabled SilentEnable ;;
            ChassisIntruStatus) dialog_readonly   ChassisIntruStatus "Chassis intrusion status (read-only)" ;;
        esac
    done
}

menu_sysinfo() {
    while true; do
        local choice
        choice=$(dialog --title "$TITLE" --menu "System Info" 20 65 11 \
            "SvcTag"          "Service tag  [$(bios_get SvcTag)]" \
            "Asset"           "Asset tag  [$(bios_get Asset)]" \
            "PropOwnTag"      "Ownership tag  [$(bios_get PropOwnTag)]" \
            "SysId"           "System ID  [$(bios_get SysId)]" \
            "SysName"         "Model name  [$(bios_get SysName)]" \
            "SysRev"          "System revision  [$(bios_get SysRev)]" \
            "BiosVer"         "BIOS version  [$(bios_get BiosVer)]" \
            "MfgDate"         "Mfg date  [$(bios_get MfgDate)]" \
            "FirstPowerOnDate" "First power-on  [$(bios_get FirstPowerOnDate)]" \
            "LastBiosUpdate"  "Last BIOS update  [$(bios_get LastBiosUpdate)]" \
            "Mem"             "Memory info  [read-only]" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            SvcTag)           dialog_readonly SvcTag           "Service tag (read-only)" ;;
            Asset)            dialog_set_text Asset            "Asset tag string" ;;
            PropOwnTag)       dialog_set_text PropOwnTag       "Property ownership tag" ;;
            SysId)            dialog_readonly SysId            "System ID (read-only)" ;;
            SysName)          dialog_readonly SysName          "System model (read-only)" ;;
            SysRev)           dialog_readonly SysRev           "System revision (read-only)" ;;
            BiosVer)          dialog_readonly BiosVer          "BIOS version (read-only)" ;;
            MfgDate)          dialog_readonly MfgDate          "Manufacturing date (read-only)" ;;
            FirstPowerOnDate) dialog_readonly FirstPowerOnDate "First power-on date (read-only)" ;;
            LastBiosUpdate)   dialog_readonly LastBiosUpdate   "Last BIOS update (read-only)" ;;
            Mem)              dialog_readonly Mem              "Memory info (read-only)" ;;
        esac
    done
}

menu_advanced() {
    while true; do
        local choice
        choice=$(dialog --title "$TITLE" --menu "Advanced" 24 65 14 \
            "Aspm"                    "PCIe ASPM  [$(bios_get Aspm)]" \
            "Absolute"                "Absolute/Computrace  [$(bios_get Absolute)]" \
            "WarningsAndErr"          "POST warnings  [$(bios_get WarningsAndErr)]" \
            "WdtOsBootProtection"     "Watchdog protection  [$(bios_get WdtOsBootProtection)]" \
            "AutoOSRecoveryThreshold" "Auto OS recovery  [$(bios_get AutoOSRecoveryThreshold)]" \
            "SupportAssistOSRecovery" "SupportAssist recovery  [$(bios_get SupportAssistOSRecovery)]" \
            "TelemetryAccessLvl"      "Telemetry level  [$(bios_get TelemetryAccessLvl)]" \
            "CapsuleFirmwareUpdate"   "Capsule update  [$(bios_get CapsuleFirmwareUpdate)]" \
            "FOTA"                    "Firmware OTA  [$(bios_get FOTA)]" \
            "SHA256"                  "SHA-256 hashing  [$(bios_get SHA256)]" \
            "MSUefiCA"                "MS UEFI CA cert  [$(bios_get MSUefiCA)]" \
            "SmartErrors"             "S.M.A.R.T. errors  [$(bios_get SmartErrors)]" \
            "VerticalIntegration"     "Vertical integration  [$(bios_get VerticalIntegration)]" \
            "InternalDmaCompatibility" "Internal DMA compat  [$(bios_get InternalDmaCompatibility)]" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            Aspm)                    dialog_set_select Aspm                    "PCIe ASPM" Disabled L1 Auto ;;
            Absolute)                dialog_set_select Absolute                "Absolute agent" Enabled Disabled PermanentlyDisabled DisableAbsolute ;;
            WarningsAndErr)          dialog_set_select WarningsAndErr          "POST warnings" PromptWrnErr EnableWarningsAndErrors DisableWarningsAndErrors EnableErrorsOnly ;;
            WdtOsBootProtection)     dialog_set_select WdtOsBootProtection     "Watchdog protection" Enabled Disabled ;;
            AutoOSRecoveryThreshold) dialog_set_select AutoOSRecoveryThreshold "Auto OS recovery" OFF 1 2 3 ;;
            SupportAssistOSRecovery) dialog_set_select SupportAssistOSRecovery "SupportAssist recovery" Enabled Disabled ;;
            TelemetryAccessLvl)      dialog_set_select TelemetryAccessLvl      "Telemetry level" Disabled Limited Full ;;
            CapsuleFirmwareUpdate)   dialog_set_select CapsuleFirmwareUpdate   "Capsule update" Enabled Disabled ;;
            FOTA)                    dialog_set_select FOTA                    "FOTA updates" Enabled Disabled ;;
            SHA256)                  dialog_set_select SHA256                  "SHA-256 hashing" Enabled Disabled ;;
            MSUefiCA)                dialog_set_select MSUefiCA                "MS UEFI CA cert" Enabled Disabled ;;
            SmartErrors)             dialog_set_select SmartErrors             "S.M.A.R.T. errors" Enabled Disabled ;;
            VerticalIntegration)     dialog_set_select VerticalIntegration     "Vertical integration" Enabled Disabled ;;
            InternalDmaCompatibility) dialog_set_select InternalDmaCompatibility "Internal DMA compat" Enabled Disabled ;;
        esac
    done
}

menu_export_import() {
    while true; do
        local choice
        choice=$(dialog --title "$TITLE" --menu "Export / Import / Reset" 13 65 5 \
            "export"  "Export all settings to INI file" \
            "import"  "Import settings from INI file" \
            "reset"   "Restore BIOS defaults" \
            "reload"  "Reload settings from BIOS now" \
            "log"     "View session log" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            export)
                local outfile
                outfile=$(dialog --title "Export Settings" \
                    --inputbox "Save INI to path:" 8 55 "/tmp/bios-$(hostname)-$(date +%Y%m%d).ini" \
                    3>&1 1>&2 2>&3) || continue
                local out
                out=$(run_cctk "--outfile=${outfile}" 2>&1 || true)
                show_result "Export" "$out\n\nFile: $outfile"
                ;;
            import)
                local infile
                infile=$(dialog --title "Import Settings" \
                    --inputbox "Path to INI file:" 8 55 "/tmp/bios.ini" \
                    3>&1 1>&2 2>&3) || continue
                if [[ ! -f "$infile" ]]; then
                    show_result "Error" "File not found: $infile"
                    continue
                fi
                dialog --title "Confirm Import" \
                    --yesno "Apply settings from:\n$infile\n\nThis will change BIOS settings immediately. Continue?" \
                    9 55 || continue
                local out
                out=$(run_cctk "--infile=${infile}" 2>&1 || true)
                show_result "Import" "$out"
                load_bios_cache
                ;;
            reset)
                dialog --title "Restore Defaults" \
                    --yesno "Restore all BIOS settings to factory defaults?\n\nThis cannot be undone." \
                    8 55 || continue
                local out
                out=$(run_cctk "--RestoreBIOSSettings=default" 2>&1 || true)
                show_result "Restore Defaults" "$out"
                load_bios_cache
                ;;
            reload)
                load_bios_cache
                show_result "Reloaded" "BIOS settings reloaded from hardware.\n${#BIOS_CACHE[@]} values cached."
                ;;
            log)
                if [[ -f "$LOGFILE" ]]; then
                    dialog --title "Session Log — $LOGFILE" \
                        --textbox "$LOGFILE" 22 75
                else
                    show_result "Log" "No log entries yet."
                fi
                ;;
        esac
    done
}

# ── main menu ─────────────────────────────────────────────────────────────────

main_menu() {
    while true; do
        local pwd_label
        [[ -n "$SETUP_PWD" ]] && pwd_label="BIOS password: set ✓" || pwd_label="Set BIOS password for session"
        local choice
        choice=$(dialog --title "$TITLE" \
            --menu "$(bios_get SysName)  |  BIOS $(bios_get BiosVer)  |  ${#BIOS_CACHE[@]} settings loaded" \
            23 68 12 \
            "Power"        "Power management & wake options" \
            "Security"     "Secure Boot, TPM, DMA, lockouts" \
            "Passwords"    "BIOS / system / HDD passwords" \
            "Boot"         "Boot order, fast boot, POST options" \
            "CPU"          "Virtualization, SpeedStep, cores" \
            "Network"      "NIC, PXE boot, WiFi, Bluetooth" \
            "USB"          "Front / rear USB port control" \
            "Devices"      "Audio, SATA, eMMC, chassis" \
            "SysInfo"      "Service tag, asset, BIOS version" \
            "Advanced"     "Absolute, telemetry, watchdog, FOTA" \
            "ExportImport" "Export / import / reload / restore" \
            "Password"     "$pwd_label" \
            3>&1 1>&2 2>&3) || break
        case "$choice" in
            Power)        menu_power ;;
            Security)     menu_security ;;
            Passwords)    menu_passwords ;;
            Boot)         menu_boot ;;
            CPU)          menu_cpu ;;
            Network)      menu_network ;;
            USB)          menu_usb ;;
            Devices)      menu_devices ;;
            SysInfo)      menu_sysinfo ;;
            Advanced)     menu_advanced ;;
            ExportImport) menu_export_import ;;
            Password)     prompt_password ;;
        esac
    done
}

# ── entry point ───────────────────────────────────────────────────────────────

require_root
require_dialog
require_cctk

log "=== cctk-tui session started ==="
detect_and_prompt_password
load_bios_cache
main_menu
clear
echo "Session log saved to: $LOGFILE"
