# gum-wifi

A WiFi manager TUI for Linux, built with [Bubble Tea](https://github.com/charmbracelet/bubbletea) on top of NetworkManager's D-Bus API.

![License: GPLv3](https://img.shields.io/badge/License-GPLv3-blue.svg)

## Features

- **Live network list** — scans refresh in place every few seconds; one row per SSID (strongest AP kept), with in-use marker, color-coded signal bars, band, security, and saved-profile indicators.
- **First-class hidden network support** — connect by SSID even when nothing is beaconing (`h`). Profiles are created with `802-11-wireless.hidden`, so NetworkManager probes for the SSID and autoconnect works across reboots.
- **WPA3** — SAE key management is detected from the AP's RSN flags and selected automatically; override with `tab` in the password prompt.
- **Clean failure handling** — a wrong password deletes the half-created profile, so retries start fresh and no junk profiles accumulate.
- **Saved profile management** (`s`) — every stored profile with last-used time, autoconnect flag, and in-range status. Connect, change the password in place (preserving the profile's other settings), toggle autoconnect, reveal the stored password, or forget it.
- **Status at a glance** — active SSID (whitespace-only names shown quoted), connectivity state (captive portal / limited / offline), and interface details: name, MAC, IP, gateway, link rate.

## Prerequisites

- Linux with **NetworkManager** running (talks D-Bus directly — `nmcli` is not needed)
- **Go 1.22+** to build

## Installation

```bash
git clone git@github.com:emancipat3r/gum-wifi.git
cd gum-wifi
go build -o gum-wifi ./cmd/gum-wifi
# optional:
install -Dm755 gum-wifi ~/.local/bin/gum-wifi
```

## Usage

Run `gum-wifi`. Everything is keyboard-driven:

**Network list**

| Key | Action |
|-----|--------|
| `↑`/`↓` | move selection |
| `enter` | connect (uses saved profile / prompts for password as needed) |
| `d` | disconnect |
| `h` | connect to a hidden network by SSID |
| `s` | saved profiles screen |
| `f` | forget the selected network's saved profile |
| `r` | rescan |
| `q` | quit |

**Saved profiles**

| Key | Action |
|-----|--------|
| `enter` | connect with stored secrets |
| `p` | change password (updated in place, then verified by connecting) |
| `a` | toggle autoconnect |
| `w` | reveal stored password (may require polkit auth) |
| `f` | forget profile |
| `esc` | back |

**Password prompt**: `enter` connect · `tab` toggle WPA2-PSK/WPA3-SAE · `esc` cancel.

## Roadmap

- Captive portal detection helper (open portal URL in browser)
- QR code sharing for the current network
- 802.1X enterprise networks

## License

This project is licensed under the GNU General Public License v3.0 — see the [LICENSE](LICENSE) file for details.
