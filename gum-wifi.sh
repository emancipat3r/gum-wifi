#!/bin/bash
set -euo pipefail

# --- 1. Dependency check & auto-install ---

check_dependencies() {
	detect_os

	if [ "$OS" == "macos" ]; then
		echo "macOS is not supported because it does not use nmcli."
		exit 1
	fi

	nmcli_installed=1
	gum_installed=1

	# Check for NetworkManager first
	if ! command -v nmcli &> /dev/null; then
		nmcli_installed=0
	fi	

	if ! command -v gum &> /dev/null; then
		gum_installed=0
	fi

	case ${nmcli_installed}${gum_installed} in
		"00")
			echo "nmcli and gum are not installed."
			read -p "Would you like to install nmcli and gum now? (y/n) > " -n 1 -r
			echo
			if [[ ! $REPLY =~ ^[Yy]$ ]]; then
				echo "nmcli and gum are required for script execution. Exiting..."
				exit 1
			fi

			install_package "nmcli"
			install_package "gum"
			;;
		"01")
			echo "nmcli is not installed."
			read -p "Would you like to install nmcli now? (y/n) > " -n 1 -r
			echo
			if [[ ! $REPLY =~ ^[Yy]$ ]]; then
				echo "nmcli is required for script execution. Exiting..."
				exit 1
			fi

			install_package "nmcli"
			;;
		"10")
			echo "Gum is not installed."
			read -p "Would you like to install gum now? (y/n) > " -n 1 -r
			echo
			if [[ ! $REPLY =~ ^[Yy]$ ]]; then
				echo "Gum is required for script execution. Exiting..."
				exit 1
			fi

			install_package "gum"
			;;
		*)
			;;
	esac
}

detect_os() {
	if [ -f /etc/os-release ];
	then
		. /etc/os-release
		OS=$ID
	elif [[ "$OSTYPE" == "darwin"* ]];
	then
		OS="macos"
	else
		OS="unknown"
	fi
}

install_package() {
	PACKAGE=${1:-}

	PM=""
	if command -v apt-get &> /dev/null; then
		PM="apt"
	elif command -v dnf &> /dev/null; then
		PM="dnf"
	elif command -v pacman &> /dev/null; then
		PM="pacman"
	elif command -v zypper &> /dev/null; then
		PM="zypper"
	elif command -v yum &> /dev/null; then
		PM="yum"
	elif command -v apk &> /dev/null; then
		PM="apk"
	fi

	if [ -z "$PM" ]; then
		echo "Could not detect package manager or OS/Distribution is not supported..."
		exit 1
	fi

	if [ "$PACKAGE" == "nmcli" ]; then
		case $PM in
			apt) PACKAGE="network-manager" ;;
			pacman|apk) PACKAGE="networkmanager" ;;
			dnf|yum|zypper) PACKAGE="NetworkManager" ;;
		esac
	fi

	if [ "$PACKAGE" == "gum" ]; then
		case $PM in
			apt)
				echo "Installing dependencies for Charm repo..."
				sudo mkdir -p /etc/apt/keyrings
				curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
				echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
				sudo apt update && sudo apt install gum -y
				return
				;;
			dnf|yum)
				echo '[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo >/dev/null
				sudo rpm --import https://repo.charm.sh/yum/gpg.key
				sudo $PM install gum -y
				return
				;;
			pacman)
				sudo pacman -S gum --noconfirm
				return
				;;
			zypper)
				echo '[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/zypp/repos.d/charm.repo
				sudo zypper install -y gum
				return
				;;
			apk)
				# gum is in Alpine community repos
				sudo apk add gum
				return
				;;
		esac
	fi

	case $PM in
		apt) sudo apt install "$PACKAGE" -y ;;
		dnf|yum) sudo $PM install "$PACKAGE" -y ;;
		pacman) sudo pacman -S "$PACKAGE" --noconfirm ;;
		zypper) sudo zypper install -y "$PACKAGE" ;;
		apk) sudo apk add "$PACKAGE" ;;
	esac
}

# Run the check
check_dependencies

# --- 2. Configuration & styling ---
# Define colors for consistency
COLOR_SUCCESS="46"	# Green
COLOR_ERROR="196"	# Red
COLOR_INFO="212"	# Pink/Purple
COLOR_WARN="208"	# Orange

# Helper function for styled output
log_info() { gum style --foreground "$COLOR_INFO" "$1"; }
log_success() { gum style --foreground "$COLOR_SUCCESS" "$1"; }
log_error() { gum style --foreground "$COLOR_ERROR" "$1"; }
log_warn() { gum style --foreground "$COLOR_WARN" "$1"; }

print_header() {
	local color="${2:-$COLOR_INFO}"
	gum style --border normal --margin "1" --padding "1 2" --border-foreground "$color" "$1"
}

print_wifi_qr() {
    local ssid="$1"
    local password="$2"
    if command -v qrencode &>/dev/null && [ -n "$password" ]; then
        gum style --foreground 252 "QR Code for '$ssid':"
        qrencode -t ANSIUTF8 "WIFI:S:${ssid};T:WPA;P:${password};;"
        echo
        gum style --border normal --padding "0 1" --border-foreground "$COLOR_SUCCESS" "Password: $password"
        return 0
    fi
    return 1
}

# --- 3. Main Logic ---


# --- Functions ---

show_help() {
	gum style \
		--border double \
		--margin "1 1 0 1" \
		--padding "1 2" \
		--border-foreground "$COLOR_INFO" \
		"WiFi Manager CLI"

	echo
	echo "Usage: $(basename "$0") [command]"
	echo
	echo "Commands:"
	echo "  connect     Scan and connect to a WiFi network"
	echo "  disconnect  Disconnect from the current WiFi network"
	echo "  saved       Manage saved WiFi profiles (Forget)"
	echo "  share       Show QR code for current connection"
	echo "  speed       Run an internet speed test"
	echo "  radio       Toggle WiFi radio on/off"
	echo
	echo "Flags:"
	echo "  -h, --help  Show this help message"
	echo
}

connect_wifi() {
	# Title
	print_header "WiFi Manager: Connect"

	# Define Header
	# Must match awk printf below:
	# %-17.17s | %-32.32s | %-8.8s | %-3.3s | %-3.3s | %-5.5s | %s
	# We add 2 spaces padding at the start to account for the 'gum choose' cursor
	HEADER="  BSSID             | SSID                             | MODE     | CH  | SIG | BARS  | SECURITY"

	# Scan
	# nmcli -t -e yes escapes ':' as '\:' and '\' as '\\'.
	# Format assumption: Awk splits on all colons. We reconstruct fields that were split at an escaped colon
	# by checking for a trailing backslash, removing it, and appending the next field. Then we unescape any backslashes.
	SCAN_OUTPUT=$(gum spin --title "Scanning for networks..." --show-output -- nmcli -t -e yes --fields BSSID,SSID,MODE,CHAN,SIGNAL,BARS,SECURITY device wifi list --rescan yes | \
		awk -F':' '{
			n=0
			for(i=1; i<=NF; i++) {
				val = $i
				while(val ~ /\\$/ && i<NF) {
					sub(/\\$/, "", val)
					i++
					val = val ":" $i
				}
				gsub(/\\\\/, "\\", val)
				f[++n] = val
			}
			printf "%-17.17s | %-32.32s | %-8.8s | %-3.3s | %-3.3s | %-5.5s | %s\n", f[1], f[2], f[3], f[4], f[5], f[6], f[7]
		}' || true)

	if [ -z "$SCAN_OUTPUT" ];
	then
		log_error "No networks found or scanning failed..."
		return 1
	fi

	# Select
	SELECTED=$(echo "$SCAN_OUTPUT" | gum choose --header "$HEADER" --height 15 --cursor.foreground "$COLOR_INFO" || true)

	if [ -z "$SELECTED" ];
	then
		log_info "Selection cancelled."
		return 0
	fi

	# Extract SSID and security
	# BSSID is $1, SSID is $2
	RAW_BSSID=$(echo "$SELECTED" | awk -F ' \\| ' '{ print $1 }' || true)
	BSSID=$(echo "$RAW_BSSID" | xargs || true)
	
	RAW_SSID=$(echo "$SELECTED" | awk -F ' \\| ' '{ print $2 }' || true)
	SSID=$(echo "$RAW_SSID" | xargs || true) # Trim whitespace
	
	# Determine Target and Display Name
	# If SSID is empty, we connect via BSSID initially
	if [ -z "$SSID" ]; then
		IS_HIDDEN=true
		TARGET="$BSSID"
		DISPLAY_NAME="$BSSID (Hidden)"
	else
		IS_HIDDEN=false
		TARGET="$SSID"
		DISPLAY_NAME="$SSID"
	fi
	
	# Security is now $7 since we removed RATE
	RAW_SECURITY=$(echo "$SELECTED" | awk -F ' \\| ' '{ print $7 }' || true)
	SECURITY=$(echo "$RAW_SECURITY" | xargs || true)

	# Try connecting using existing profile (or open network)
	# This avoids unreliable "check profile exists" logic.
	# If profile exists (under any name), nmcli finds it by SSID.
	# If no profile or wrong password, this fails, and we catch it below.
	if gum spin --title "Connecting to $DISPLAY_NAME..." -- nmcli device wifi connect "$TARGET"; then
		log_success "Connected to $DISPLAY_NAME"
		check_captive_portal
		return 0
	fi

	# If failed and it was hidden, prompt user for SSID to retry
	if [ "$IS_HIDDEN" = true ]; then
		log_info "Hidden network connection failed."
		HIDDEN_SSID=$(gum input --placeholder "Enter Hidden Network Name (SSID) to retry" --cursor.foreground "$COLOR_INFO")
		
		if [ -n "$HIDDEN_SSID" ]; then
			SSID="$HIDDEN_SSID"
			TARGET="$SSID"
			DISPLAY_NAME="$SSID (Hidden)"
			
			# Retry with new Target
			if gum spin --title "Connecting to $DISPLAY_NAME..." -- nmcli device wifi connect "$TARGET"; then
				log_success "Connected to $DISPLAY_NAME"
				check_captive_portal
				return 0
			fi
		fi
	fi

	# If failed, and network is secured, ask for password
	if [[ "$SECURITY" != "OPEN" ]] && [[ -n "$SECURITY" ]]; then
		log_info "Password required."
		PASSWORD=$(gum input --password --placeholder "Enter password for $DISPLAY_NAME" --cursor.foreground "$COLOR_INFO")
		
		if [ -z "$PASSWORD" ]; then
			log_info "No password provided."
			return 1
		fi
		
		# Retry with provided password via secure temporary profile
		TMP_PROFILE="gumwifi-$(date +%s)"
		if ! nmcli connection add type wifi con-name "$TMP_PROFILE" ifname '*' ssid "$SSID" \
			-- wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASSWORD" >/dev/null; then
			log_error "Failed to create connection profile."
			return 1
		fi
		
		if gum spin --title "Connecting to $DISPLAY_NAME..." -- nmcli connection up "$TMP_PROFILE"; then
			log_success "Connected to $DISPLAY_NAME"
			check_captive_portal
			return 0
		else
			nmcli connection delete "$TMP_PROFILE" >/dev/null 2>&1 || true
			log_error "Failed to connect."
			return 1
		fi
	else
		# Open network failed or other error
		log_error "Failed to connect."
		return 1
	fi
}

check_captive_portal() {
	gum spin --title "Verifying internet connectivity..." -- sleep 2

	STATE=$(nmcli networking connectivity)

	if [[ "$STATE" == "portal" ]] || [[ "$STATE" == "limited" ]];
	then
		gum style --foreground "$COLOR_WARN" --border double --padding "1 2" "Captive portal detected..."

		if gum confirm "Open browser to login?";
		then
			gum style --italic "Opening http://neverssl.com to trigger redirect to captive portal..."
			xdg-open "http://neverssl.com" 2>/dev/null &
		else
			log_info "Skipping browser launch."
		fi
	elif [[ "$STATE" == "full" ]];
	then
		log_success "Internet is fully accessible."
	else
		gum style --foreground 240 "Connection status: $STATE"
	fi
}

manage_saved() {
	print_header "Manage Saved Networks"

	# List saved connections (Active or not)
	# Fields: NAME, UUID, TYPE, TIMESTAMP
	# Filter for 802-11-wireless
	SAVED_LIST=$(nmcli -t -f NAME,UUID,TYPE,TIMESTAMP connection show | grep ':802-11-wireless:' | sort -t: -k4 -r || true)

	if [ -z "$SAVED_LIST" ]; then
		log_info "No saved WiFi profiles found."
		return 0
	fi

	DISPLAY_LIST=""
	while IFS=: read -r name uuid type ts; do
		if [ -n "$ts" ] && [ "$ts" -gt 0 ] 2>/dev/null; then
			dt=$(date -d @"$ts" "+%Y-%m-%d %H:%M" 2>/dev/null)
			DISPLAY_LIST+="$name (Last used: $dt)__UUID__$uuid"$'\n'
		else
			DISPLAY_LIST+="$name (Never used)__UUID__$uuid"$'\n'
		fi
	done <<< "$SAVED_LIST"

	# Trim trailing newline
	DISPLAY_LIST="${DISPLAY_LIST%$'\n'}"

	SELECTED_DISPLAY=$(echo "$DISPLAY_LIST" | awk -F '__UUID__' '{print $1}' | gum choose --header "Select a profile to manage" --height 15 --cursor.foreground "$COLOR_INFO")

	if [ -z "$SELECTED_DISPLAY" ]; then
		return 0
	fi

	UUID=$(echo "$DISPLAY_LIST" | grep -F "$SELECTED_DISPLAY__UUID__" | awk -F '__UUID__' '{print $2}' | head -n1 || true)
	SELECTED_NAME=$(echo "$SELECTED_DISPLAY" | sed 's/ (.*//')

	# Actions
	ACTION=$(gum choose "Show Password" "Forget/Delete" "Cancel" --header "Action for '$SELECTED_NAME'")

	if [ "$ACTION" == "Forget/Delete" ]; then
		if gum confirm "Permanently delete '$SELECTED_NAME'?"; then
			if gum spin --title "Deleting..." -- nmcli connection delete "$UUID"; then
				log_success "Deleted profile '$SELECTED_NAME'"
			else
				log_error "Failed to delete profile."
			fi
		fi
	elif [ "$ACTION" == "Show Password" ]; then
		# Retrieve details
		PASS=$(nmcli -s -g 802-11-wireless-security.psk connection show "$UUID" 2>/dev/null)
		SSID=$(nmcli -g 802-11-wireless.ssid connection show "$UUID" 2>/dev/null)
		
		if [ -z "$PASS" ]; then
			log_warn "Warning: Could not retrieve WiFi password. You may need to run this command with 'sudo'."
		fi
		
		if gum confirm --default=false "Reveal password? (will be printed to terminal)"; then
			if ! print_wifi_qr "$SSID" "$PASS"; then
				log_error "Could not generate QR code. (qrencode missing or password empty)"
			fi
		else
			log_info "Password not revealed."
		fi
	fi
}

share_wifi() {
	print_header "Share WiFi"

	# Check for active connection
	ACTIVE=$(nmcli -t -f NAME,TYPE connection show --active | grep -E ':(802-11-wireless|wifi)$' | cut -d: -f1 | head -n1 || true)
	if [ -z "$ACTIVE" ]; then
		log_error "Not connected to any wireless network."
		return 1
	fi

	# Attempt to retrieve credentials
	log_info "Retrieving credentials for '$ACTIVE'..."
	SECRETS=$(nmcli -s -g 802-11-wireless-security.psk connection show "$ACTIVE" 2>/dev/null)
	SSID=$(nmcli -g 802-11-wireless.ssid connection show "$ACTIVE" 2>/dev/null)

	if [ -z "$SECRETS" ]; then
		log_warn "Warning: Could not retrieve WiFi password. You may need to run this command with 'sudo'."
	fi

	if gum confirm --default=false "Reveal password? (will be printed to terminal)"; then
		if ! print_wifi_qr "$SSID" "$SECRETS"; then
			log_error "Could not generate QR code."
		fi
	else
		log_info "Password not revealed."
	fi
}

run_speedtest() {
	print_header "Speed Test"

	if command -v speedtest &> /dev/null; then
		log_info "Initialize Ookla speedtest..."
		if command -v jq &> /dev/null; then
			TMP_SPEED=$(mktemp)
			if ! speedtest --accept-license --accept-gdpr -f json > "$TMP_SPEED" 2>/dev/null; then
				rm "$TMP_SPEED"
				log_error "Speed test failed."
				return 1
			fi
			CLIENT=$(jq -r '.isp' "$TMP_SPEED" || true)
			SERVER=$(jq -r '.server.name' "$TMP_SPEED" || true)
			PING=$(jq -r '.ping.latency' "$TMP_SPEED" | sed 's/$/ ms/' || true)
			DOWNLOAD_VAL=$(jq -r '.download.bandwidth' "$TMP_SPEED" || true)
			DOWNLOAD=$(awk "BEGIN {printf \"%.2f Mbit/s\", $DOWNLOAD_VAL * 8 / 1000000}" || true)
			UPLOAD_VAL=$(jq -r '.upload.bandwidth' "$TMP_SPEED" || true)
			UPLOAD=$(awk "BEGIN {printf \"%.2f Mbit/s\", $UPLOAD_VAL * 8 / 1000000}" || true)
			rm "$TMP_SPEED"
		else
			TMP_SPEED=$(mktemp)
			if ! speedtest --accept-license --accept-gdpr -f human-readable > "$TMP_SPEED" 2>/dev/null; then
				rm "$TMP_SPEED"
				log_error "Speed test failed."
				return 1
			fi
			CLIENT=$(grep "ISP:" "$TMP_SPEED" | sed 's/^.*ISP: //' || true)
			SERVER=$(grep "Server:" "$TMP_SPEED" | sed 's/^.*Server: //' || true)
			PING=$(grep "Idle Latency:" "$TMP_SPEED" | grep -o '[0-9.]* ms' | head -n1 || true)
			DOWNLOAD=$(grep "Download:" "$TMP_SPEED" | sed 's/.*Download: //' || true)
			UPLOAD=$(grep "Upload:" "$TMP_SPEED" | sed 's/.*Upload: //' || true)
			rm "$TMP_SPEED"
		fi

		if [ -n "$DOWNLOAD" ]; then
			gum style \
				--border double \
				--margin "1" \
				--padding "1 2" \
				--border-foreground "$COLOR_SUCCESS" \
				"Client:   $(gum style --foreground "$COLOR_INFO" "$CLIENT")" \
				"Server:   $(gum style --foreground "$COLOR_INFO" "$SERVER")" \
				"Ping:     $(gum style --foreground "$COLOR_SUCCESS" "$PING")" \
				"Download: $(gum style --bold --foreground "$COLOR_SUCCESS" "$DOWNLOAD")" \
				"Upload:   $(gum style --bold --foreground "$COLOR_SUCCESS" "$UPLOAD")"
			return 0
		else
			log_error "Could not parse results."
			return 1
		fi
	fi

	# Fallback to speedtest-cli
	if ! command -v speedtest-cli &> /dev/null; then
		if gum confirm "Ookla 'speedtest' is not installed. View official install instructions?"; then
			echo "For optimal results, please install Ookla 'speedtest' via official instructions:"
			echo "  https://www.speedtest.net/apps/cli"
			return 1
		else
			log_error "'speedtest' is required. Exiting."
			return 1
		fi
	fi

	log_info "Initialize speedtest-cli..."
	
	TMP_SPEED=$(mktemp)
	
	if ! speedtest-cli | tee "$TMP_SPEED"; then
		rm "$TMP_SPEED"
		log_error "Speed test failed."
		return 1
	fi
	
	echo # Newline after progress dots

	# Parse Output
	CLIENT=$(grep "Testing from" "$TMP_SPEED" | sed 's/^Testing from //; s/\.\.\.$//' || true)
	SERVER_LINE=$(grep "Hosted by" "$TMP_SPEED" || true)
	SERVER=$(echo "$SERVER_LINE" | sed 's/^Hosted by //; s/: .*//')
	PING=$(echo "$SERVER_LINE" | sed 's/.*: //')
	
	DOWNLOAD=$(grep "Download:" "$TMP_SPEED" | sed 's/^Download: //' || true)
	UPLOAD=$(grep "Upload:" "$TMP_SPEED" | sed 's/^Upload: //' || true)
	
	rm "$TMP_SPEED"

	if [ -n "$DOWNLOAD" ]; then
		gum style \
			--border double \
			--margin "1" \
			--padding "1 2" \
			--border-foreground "$COLOR_SUCCESS" \
			"Client:   $(gum style --foreground "$COLOR_INFO" "$CLIENT")" \
			"Server:   $(gum style --foreground "$COLOR_INFO" "$SERVER")" \
			"Ping:     $(gum style --foreground "$COLOR_SUCCESS" "$PING")" \
			"Download: $(gum style --bold --foreground "$COLOR_SUCCESS" "$DOWNLOAD")" \
			"Upload:   $(gum style --bold --foreground "$COLOR_SUCCESS" "$UPLOAD")"
		return 0
	else
		log_error "Could not parse results."
		return 1
	fi
}

toggle_radio() {
	print_header "WiFi Radio"

	STATUS=$(nmcli radio wifi)
	log_info "Current status: $STATUS"

	CHOICE=$(gum choose "Enable" "Disable" "Cancel" --header "Set WiFi Radio")

	case "$CHOICE" in
		"Enable")
			gum spin --title "Enabling WiFi..." -- nmcli radio wifi on
			log_success "WiFi Enabled"
			;;
		"Disable")
			gum spin --title "Disabling WiFi..." -- nmcli radio wifi off
			log_success "WiFi Disabled"
			;;
	esac
}


disconnect_wifi() {
	# Find active wifi connection with details
	# Fields: NAME, UUID, TYPE, DEVICE
	# We include UUID because NAME might be empty or duplicate.
	# We fallback to grep for both '802-11-wireless' and simple 'wifi' as type can vary.
	ACTIVE_CONN_INFO=$(nmcli -t -f NAME,UUID,TYPE,DEVICE connection show --active | grep -E ':(802-11-wireless|wifi):' | head -n1 || true)

	if [ -z "$ACTIVE_CONN_INFO" ]; then
		log_info "No active WiFi connection found."
		return 0
	fi

	# Parse Info
	# nmcli terse uses ':' as separator.
	CONN_NAME=$(echo "$ACTIVE_CONN_INFO" | cut -d: -f1)
	UUID=$(echo "$ACTIVE_CONN_INFO" | cut -d: -f2)
	DEVICE=$(echo "$ACTIVE_CONN_INFO" | cut -d: -f4)
	
	# If Name is empty or whitespace, it's likely a hidden network
	TRIMMED_NAME=$(echo "$CONN_NAME" | xargs)
	if [ -z "$TRIMMED_NAME" ]; then
		DISPLAY_NAME="Hidden Network"
	else
		DISPLAY_NAME="$CONN_NAME"
	fi
	
	# Get Device Specifics (Signal, Rate, IP)
	# Get IP Address
	# Output format: IP4.ADDRESS[1]:192.168.1.5/24
	IP_ADDR=$(nmcli -t -f IP4.ADDRESS device show "$DEVICE" 2>/dev/null | grep 'IP4.ADDRESS' | cut -d: -f2 | head -n1 || true)

	# Get Signal and Rate from wifi list (more reliable than device show for some versions)
	# Output format: *:SSID:SIGNAL:RATE
	WIFI_INFO=$(nmcli -t -f IN-USE,SSID,SIGNAL,RATE device wifi list | grep '^\*' | head -n1 || true)
	SIGNAL=$(echo "$WIFI_INFO" | cut -d: -f3)
	RATE=$(echo "$WIFI_INFO" | cut -d: -f4)

	print_header "Disconnect Network" "$COLOR_WARN"

	# Present Details using gum style
	gum style \
		--foreground 252 \
		"Current Connection Details:" 
		
	gum style \
		--padding "0 2" \
		"SSID:   $(gum style --foreground "$COLOR_INFO" "$DISPLAY_NAME")" \
		"Device: $(gum style --foreground "$COLOR_INFO" "$DEVICE")" \
		"IP:     $(gum style --foreground "$COLOR_INFO" "$IP_ADDR")" \
		"Signal: $(gum style --foreground "$COLOR_INFO" "$SIGNAL%")" \
		"Rate:   $(gum style --foreground "$COLOR_INFO" "$RATE")"

	echo

	if gum confirm "Disconnect from '$DISPLAY_NAME'?"; then
		# Use UUID to disconnect, it is safer than Name (especially if empty)
		if gum spin --title "Disconnecting..." -- nmcli connection down "$UUID"; then
			log_success "Disconnected from $DISPLAY_NAME"
		else
			log_error "Failed to disconnect."
			return 1
		fi
	else
		log_info "Disconnection cancelled."
	fi
}

# --- Main CLI Logic ---

case "${1:-}" in
	"connect")
		connect_wifi
		;;
	"disconnect")
		disconnect_wifi
		;;
	"saved")
		manage_saved
		;;
	"share")
		share_wifi
		;;
	"speed")
		run_speedtest
		;;
	"radio")
		toggle_radio
		;;
	"-h"|"--help")
		show_help
		;;
	*)
		show_help
		return 1
		;;
esac
exit $?
