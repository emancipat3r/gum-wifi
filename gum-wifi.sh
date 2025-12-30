#!/bin/bash

# --- 1. Dependency check & auto-install ---

check_dependencies() {
	# Check for NetworkManager first
	if ! command -v nmcli &> /dev/null;
	then
		echo "Error: NetworkManager (nmcli) is not installed."
		exit 1
	fi

	# Check for gum
	if ! command -v gum &> /dev/null;
	then
		echo "Gum is not installed. Detecting OS..."
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

		echo "Detected OS: $OS"
		read -p "Would you like to install 'gum' now? (y/n) > " -n 1 -r
		echo
		if [[ ! $REPLY =~ ^[Yy]$ ]];
		then
			echo "Gum is required for this script. Exiting..."
			exit 1
		fi

		case $OS in
			arch|manjaro|endeavouros)
				sudo pacman -S gum --noconfirm
				;;
			macos)
				if command -v brew &> /dev/null;
				then
					brew install gum
				else
					echo "Homebrew not found. Please install gum manually."
					exit 1
				fi
				;;
			ubuntu|debian|pop)
				# Charmbracelet requires adding a repo for Debian variants
				echo "Installing dependencies for Charm repo..."
				sudo mkdir -p /etc/apt/keyrings
				curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/sources.list.d/charm.list
				sudo apt update && sudo apt install gum -y
				;;
			fedora)
				echo '[charm]
				name=Charm
				baseurl=https://repo.charm.sh/yum/
				enabled=1
				gpgcheck=1
				gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo
				sudo dnf install gum -y
				;;
			*)
				echo "Could not detect package manager. Please install 'gum' manually (https://github.com/charmbracelet/gum)."
				exit 1
				;;
		esac
	fi
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
	echo
	echo "Flags:"
	echo "  -h, --help  Show this help message"
	echo
}

connect_wifi() {
	# Title
	gum style --border normal --margin "1" --padding "1 2" --border-foreground "$COLOR_INFO" "WiFi Manager: Connect"

	# Define Header
	# Must match awk printf below:
	# %-17.17s | %-25.25s | %-8.8s | %-3.3s | %-9.9s | %-3.3s | %-5.5s | %s
	# We add 2 spaces padding at the start to account for the 'gum choose' cursor
	HEADER="  BSSID             | SSID                      | MODE     | CH  | RATE      | SIG | BARS  | SECURITY"

	# Scan
	# Added BSSID to fields.
	SCAN_OUTPUT=$(gum spin --title "Scanning for networks..." --show-output -- nmcli --terse --fields BSSID,SSID,MODE,CHAN,RATE,SIGNAL,BARS,SECURITY device wifi list --rescan yes | \
		sed 's/\\:/__COLON__/g' | sed 's/:/ | /g' | sed 's/__COLON__/:/g' | \
		awk -F ' \\| ' '{ printf "%-17.17s | %-25.25s | %-8.8s | %-3.3s | %-9.9s | %-3.3s | %-5.5s | %s\n", $1, $2, $3, $4, $5, $6, $7, $8 }')

	if [ -z "$SCAN_OUTPUT" ];
	then
		log_error "No networks found or scanning failed..."
		exit 1
	fi

	# Select
	SELECTED=$(echo "$SCAN_OUTPUT" | gum choose --header "$HEADER" --height 15 --cursor.foreground "$COLOR_INFO")

	if [ -z "$SELECTED" ];
	then
		log_info "Selection cancelled."
		exit 0
	fi

	# Extract SSID and security
	# BSSID is $1, SSID is $2
	RAW_BSSID=$(echo "$SELECTED" | awk -F ' \\| ' '{ print $1 }')
	BSSID=$(echo "$RAW_BSSID" | xargs)
	
	RAW_SSID=$(echo "$SELECTED" | awk -F ' \\| ' '{ print $2 }')
	SSID=$(echo "$RAW_SSID" | xargs) # Trim whitespace
	
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
	
	# Security is now $8
	RAW_SECURITY=$(echo "$SELECTED" | awk -F ' \\| ' '{ print $8 }')
	SECURITY=$(echo "$RAW_SECURITY" | xargs)

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
			exit 1
		fi
		
		# Retry with provided password
		if gum spin --title "Connecting to $DISPLAY_NAME..." -- nmcli device wifi connect "$TARGET" password "$PASSWORD"; then
			log_success "Connected to $DISPLAY_NAME"
			check_captive_portal
			return 0
		else
			log_error "Failed to connect."
			exit 1
		fi
	else
		# Open network failed or other error
		log_error "Failed to connect."
		exit 1
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

disconnect_wifi() {
	# Find active wifi connection with details
	# Fields: NAME, UUID, TYPE, DEVICE
	# We include UUID because NAME might be empty or duplicate.
	# We fallback to grep for both '802-11-wireless' and simple 'wifi' as type can vary.
	ACTIVE_CONN_INFO=$(nmcli -t -f NAME,UUID,TYPE,DEVICE connection show --active | grep -E ':(802-11-wireless|wifi):' | head -n1)

	if [ -z "$ACTIVE_CONN_INFO" ]; then
		log_info "No active WiFi connection found."
		exit 0
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
	IP_ADDR=$(nmcli -t -f IP4.ADDRESS device show "$DEVICE" 2>/dev/null | grep 'IP4.ADDRESS' | cut -d: -f2 | head -n1)

	# Get Signal and Rate from wifi list (more reliable than device show for some versions)
	# Output format: *:SSID:SIGNAL:RATE
	WIFI_INFO=$(nmcli -t -f IN-USE,SSID,SIGNAL,RATE device wifi list | grep '^\*' | head -n1)
	SIGNAL=$(echo "$WIFI_INFO" | cut -d: -f3)
	RATE=$(echo "$WIFI_INFO" | cut -d: -f4)

	gum style --border normal --margin "1" --padding "1 2" --border-foreground "$COLOR_WARN" "Disconnect Network"

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
		gum spin --title "Disconnecting..." -- nmcli connection down "$UUID"
		if [ $? -eq 0 ]; then
			log_success "Disconnected from $DISPLAY_NAME"
		else
			log_error "Failed to disconnect."
			exit 1
		fi
	else
		log_info "Disconnection cancelled."
	fi
}

# --- Main CLI Logic ---

case "$1" in
	"connect")
		connect_wifi
		;;
	"disconnect")
		disconnect_wifi
		;;
	"-h"|"--help")
		show_help
		;;
	*)
		show_help
		exit 1
		;;
esac
