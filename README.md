# Gum WiFi Manager

A beautiful, interactive WiFi manager for the command line, built with [Gum](https://github.com/charmbracelet/gum) and `nmcli`.

![License: GPLv3](https://img.shields.io/badge/License-GPLv3-blue.svg)

## Features

- **Interactive Selection**: Scans available networks and presents them in a sortable, filterable list.
- **Stylish UI**: Uses Charmbracelet's `gum` for modern, colorful borders, spinners, and inputs.
- **Hidden Network Support**: Easily connect to hidden networks, including auto-connect for saved profiles.
- **Captive Portal Check**: automatically detects if you're behind a captive portal.
- **Disconnect Manager**: View current connection details (Signal, Rate, IP) before disconnecting.
- **Cross-Platform**: Works on Linux (NetworkManager) and supports dependency detection for macOS (experimental).

## Prerequisites

- **Bash**
- **NetworkManager** (`nmcli`): Standard on most Linux distributions (Ubuntu, Fedora, Arch, etc.).
- **Gum**: The script checks and offers to install it, or you can install it manually:
  
  ```bash
  # Debian/Ubuntu
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/sources.list.d/charm.list
  sudo apt update && sudo apt install gum

  # Arch/Manjaro
  sudo pacman -S gum

  # macOS
  brew install gum
  ```

## Installation

1. Clone the repository:
   ```bash
   git clone git@github.com:emancipat3r/gum-wifi.git
   cd gum-wifi
   ```

2. Make the script executable:
   ```bash
   chmod +x gum-wifi.sh
   ```

3. (Optional) Symlink to your path:
   ```bash
   sudo ln -s $(pwd)/gum-wifi.sh /usr/local/bin/gum-wifi
   ```

## Usage

### Connect to a Network
```bash
./gum-wifi.sh connect
```
Scans for networks and opens the selection menu. If you select a secure network, it prompts for a password. If you select a hidden network (blank SSID), it attempts to auto-connect or prompts for the SSID.

### Disconnect
```bash
./gum-wifi.sh disconnect
```
Shows details about your current connection (SSID, Signal Strength, IP Address) and asks for confirmation before disconnecting.

### Help
```bash
./gum-wifi.sh --help
```

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.
