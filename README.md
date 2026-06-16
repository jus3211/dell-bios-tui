# dell-bios-tui

Bash TUI for configuring Dell BIOS settings on headless Linux via Dell Command Configure (cctk). Covers power, security, boot, USB, CPU and more — with auto password detection, live settings readout, and a one-line installer.

Built for managing Dell OptiPlex and Thin Client deployments without a GUI, over SSH or direct console.

---

## Features

- **Full ncurses menu** via `dialog` — works over SSH, no desktop required
- **Auto password detection** — probes cctk on startup and prompts if a BIOS setup password is set, validates immediately
- **Live settings readout** — reads all current BIOS values on startup, displays them inline in every menu item
- **Current value pre-selected** — opens select dialogs with the active value already highlighted
- **Cache updates on change** — menus reflect changes immediately without a full reload
- **Export / Import / Restore** — dump settings to INI, apply from INI, or restore factory defaults
- **Session log** — every cctk command and result logged to `/tmp/cctk-tui.log`
- **One-line installer** — installs cctk and the TUI in a single command

---

## Requirements

| Requirement | Notes |
|---|---|
| Dell hardware | OptiPlex, Thin Client, Latitude, or any supported Dell business platform |
| Debian 11 / 12 / 13 or Ubuntu 20.04 / 22.04 / 24.04 | amd64 only |
| Root / sudo access | cctk requires root |
| `dialog` | Installed automatically by the installer |
| Dell Command Configure v5.x | Installed by the installer |

---

## Installation

### One-liner (after hosting on GitHub)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/jus3211/dell-bios-tui/main/install-cctk-tui.sh)"
```
powershell -ExecutionPolicy Bypass -c "irm https://github.com/jus3211/dell-bios-tui/releases/download/tui/cctk-tui.ps1 -OutFile $env:TEMP\cctk-tui3.ps1; & $env:TEMP\cctk-tui3.ps1"
### Manual

```bash
git clone https://github.com/jus3211/dell-bios-tui.git
cd dell-bios-tui
sudo bash install-cctk-tui.sh
```

The installer will:

1. Verify Dell hardware and amd64 architecture
2. Install `dialog`, `wget`, `curl` via apt
3. Install `libssl1.1` from the Debian 11 archive if not present (required by cctk on Debian 12+)
4. Present a menu of known cctk download URLs — pick a version or paste a custom URL
5. Install the HAPI driver and Dell Command Configure in the correct order
6. Install `cctk-tui` to `/usr/local/bin/cctk-tui`

Install log is saved to `/tmp/cctk-install.log`.

---

## Usage

```bash
sudo cctk-tui
```

### Navigation

| Key | Action |
|---|---|
| `↑` / `↓` | Move between options |
| `Enter` | Select |
| `Tab` | Switch between buttons |
| `Esc` / back button | Return to previous menu |

### First launch

On first launch the TUI will:

1. Probe cctk with a write operation to detect whether a BIOS setup password is required
2. If a password is found — prompt for it and validate before continuing
3. Read all current BIOS settings into memory (shown in every menu)
4. Open the main menu

### Menus

| Menu | Contents |
|---|---|
| **Power** | AC recovery, auto power-on, Wake-on-LAN, USB wake, deep sleep |
| **Security** | Secure Boot, TPM, DMA protection, lockouts, SMM mitigation |
| **Passwords** | Set / validate BIOS setup, system, and HDD passwords |
| **Boot** | Boot order, fast boot, POST time, UEFI network stack |
| **CPU** | VT-x, VT-d, SpeedStep, Speed Shift, Turbo Boost, C-states |
| **Network** | Embedded NIC / PXE, wireless LAN, Bluetooth |
| **USB** | Individual front and rear port enable/disable, USB emulation |
| **Devices** | Audio, microphone, eMMC, SATA mode, chassis intrusion |
| **System Info** | Service tag, asset tag, BIOS version, model, memory |
| **Advanced** | Absolute, telemetry, FOTA, watchdog, SHA-256, UEFI CA |
| **Export / Import** | Export to INI, import from INI, restore defaults, reload cache |

---

## Files

```
dell-bios-tui/
├── install-cctk-tui.sh   # Installer — handles cctk + TUI setup
├── cctk-tui.sh           # The TUI itself
└── README.md
```

After install, `cctk-tui.sh` is copied to `/usr/local/bin/cctk-tui`.  
Dell Command Configure is installed to `/opt/dell/dcc/cctk`.

---

## Tested on

| Hardware | OS | cctk |
|---|---|---|
| Dell OptiPlex 3000 Thin Client | Debian 12 | v5.1.0 |

---

## Notes

- cctk is proprietary software by Dell Inc. This repo contains no Dell binaries — the installer downloads them directly from Dell's servers.
- Some BIOS settings require a reboot to take effect.
- Read-only options (marked `[read-only]`) can be queried but not changed via cctk.
- If `SmmSecurityMitigation` is enabled in BIOS, cctk may not function correctly on Linux. Dell recommends disabling it when using cctk.

---
