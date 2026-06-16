# dell-bios-tui

TUI for configuring Dell BIOS settings via Dell Command Configure (cctk). Available for both Linux (bash + dialog) and Windows (PowerShell). Covers power, security, boot, USB, CPU and more — with auto password detection, live settings readout, and a one-line installer.

Built for managing Dell OptiPlex, Thin Client, and Latitude deployments, over SSH or direct console.

---

## Features

- **Full interactive menu** — arrow key navigation, no GUI required
- **Auto password detection** — probes cctk on startup and prompts if a BIOS setup password is set, validates immediately
- **Live settings readout** — reads all current BIOS values on startup, displays them inline in every menu item
- **Current value pre-selected** — opens select dialogs with the active value already highlighted
- **Cache updates on change** — menus reflect changes immediately without a full reload
- **Export / Import / Restore** — dump settings to INI, apply from INI, or restore factory defaults
- **Session log** — every cctk command and result logged for review
- **One-line install and launch** — Linux installer and Windows PowerShell one-liner

---

## Linux

### Requirements

| Requirement | Notes |
|---|---|
| Dell hardware | OptiPlex, Thin Client, Latitude, or any supported Dell business platform |
| Debian 11 / 12 / 13 or Ubuntu 20.04 / 22.04 / 24.04 | amd64 only |
| Root / sudo access | cctk requires root |
| `dialog` | Installed automatically by the installer |
| Dell Command Configure v5.x | Installed by the installer |

### Installation

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/jus3211/dell-bios-tui/main/install-cctk-tui.sh)"
```

Or manually:

```bash
git clone https://github.com/jus3211/dell-bios-tui.git
cd dell-bios-tui
sudo bash install-cctk-tui.sh
```

The installer will:

1. Verify Dell hardware and amd64 architecture
2. Install `dialog`, `wget`, `curl` via apt
3. Install `libssl1.1` from the Debian 11 archive if not present (required by cctk on Debian 12+)
4. Download and install the HAPI driver and Dell Command Configure from the repo
5. Install `cctk-tui` to `/usr/local/bin/cctk-tui`
6. Create a `bios` wrapper so you can just type `bios` to launch

Install log is saved to `/tmp/cctk-install.log`.

### Usage

```bash
bios
# or
sudo cctk-tui
```

### Navigation

| Key | Action |
|---|---|
| `↑` / `↓` | Move between options |
| `Enter` | Select |
| `Tab` | Switch between buttons |
| `Esc` / back button | Return to previous menu |

---

## Windows

### Requirements

| Requirement | Notes |
|---|---|
| Dell hardware | Any supported Dell business platform |
| Windows 10 1909 or newer | ANSI console support required |
| PowerShell 5.1 or newer | Built into Windows |
| Administrator access | cctk requires admin |
| Dell Command Configure v5.x | Installed automatically if missing |

### Installation & launch

Run as Administrator in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://github.com/jus3211/dell-bios-tui/releases/download/tui/cctk-tui.ps1 -OutFile $env:TEMP\cctk-tui.ps1; & $env:TEMP\cctk-tui.ps1"
```

If Dell Command Configure is not installed, the script will:
1. Try to install it via `winget` automatically
2. Fall back to downloading the installer from the GitHub release

### Navigation

| Key | Action |
|---|---|
| `↑` / `↓` | Move between options |
| `Enter` | Select |
| `Esc` or `B` | Return to previous menu |
| `Q` | Quit |

---

## First launch (both platforms)

On first launch the TUI will:

1. Probe cctk with a write operation to detect whether a BIOS setup password is required
2. If a password is found — prompt for it and validate before continuing
3. Read all current BIOS settings into memory (shown in every menu)
4. Open the main menu

---

## Menus

| Menu | Contents |
|---|---|
| **Power** | Auto power-on, Wake-on-LAN, wake on AC/dock, battery charge config, thermal management |
| **Security** | Secure Boot, TPM, DMA protection, lockouts, SMM mitigation, firmware tamper detection |
| **Passwords** | Set / validate BIOS setup, system, and HDD passwords |
| **Boot** | Boot order, fast boot, POST time, UEFI network stack, HTTPS boot |
| **CPU** | VT-x, VT-d, SpeedStep, Speed Shift, Turbo Boost, C-states, E-cores, Hyper-Threading |
| **Network** | Embedded NIC / PXE, wireless LAN, Bluetooth, MAC pass-through, BIOS Connect |
| **USB** | Individual port enable/disable, USB emulation, USB power share |
| **Devices** | Audio, microphone, camera, M.2 SSD, SATA mode, lid switch, Fn Lock |
| **System Info** | Service tag, asset tag, BIOS version, model, memory |
| **Advanced** | Absolute, telemetry, FOTA, watchdog, SHA-256, UEFI CA, keyboard backlight |
| **Export / Import** | Export to INI, import from INI, restore defaults, reload cache |

---

## Files

```
dell-bios-tui/
├── install-cctk-tui.sh              # Linux installer
├── cctk-tui.sh                      # Linux TUI (bash + dialog)
├── cctk-tui.ps1                     # Windows TUI (PowerShell)
└── README.md
```

Release assets:
- `srvadmin-hapi_9.5.0_amd64.deb` — HAPI driver for Linux
- `command-configure_5.1.0-6.ubuntu22_amd64.deb` — cctk for Linux
- `Dell-Command-Configure-Application_MD8CJ_WIN64_5.2.0.9_A00_01.EXE` — cctk for Windows
- `cctk-tui.ps1` — Windows TUI (for one-liner launch)

---

## Tested on

| Hardware | OS | cctk |
|---|---|---|
| Dell OptiPlex 3000 Thin Client | Debian 12 | v5.1.0 |
| Dell Latitude (laptop) | Windows 11 | v5.2.0 |

---

## Notes

- cctk is proprietary software by Dell Inc. This repo contains no Dell source code.
- Some BIOS settings require a reboot to take effect.
- Read-only options (marked `[read-only]`) can be queried but not changed via cctk.
- If `SmmSecurityMitigation` is enabled in BIOS, cctk may not function correctly on Linux. Dell recommends disabling it when using cctk.
- On Windows, the script requires running as Administrator — right-click PowerShell and select "Run as Administrator" before running the one-liner.

---

## License

MIT — see [LICENSE](LICENSE).  
Dell Command Configure is subject to Dell's own licensing terms.
