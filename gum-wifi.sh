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
		detect_os
		
		echo "Detected OS: $OS"
		read -p "Would you like to install 'gum' now? (y/n) > " -n 1 -r
		echo
		if [[ ! $REPLY =~ ^[Yy]$ ]];
		then
			echo "Gum is required for this script. Exiting..."
			exit 1
		fi

		install_package "gum"
	fi
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
	PACKAGE=$1
	case $OS in
		arch|manjaro|endeavouros)
			sudo pacman -S "$PACKAGE" --noconfirm
			;;
		macos)
			if command -v brew &> /dev/null;
			then
				brew install "$PACKAGE"
			else
				echo "Homebrew not found. Please install $PACKAGE manually."
				exit 1
			fi
			;;
		ubuntu|debian|pop)
			# Specific handling for gum repo only if package is gum
			if [ "$PACKAGE" == "gum" ]; then
				echo "Installing dependencies for Charm repo..."
				sudo mkdir -p /etc/apt/keyrings
				curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/sources.list.d/charm.list
				sudo apt update && sudo apt install gum -y
			else
				sudo apt install "$PACKAGE" -y
			fi
			;;
		fedora)
			if [ "$PACKAGE" == "gum" ]; then
				echo '[charm]
				name=Charm
				baseurl=https://repo.charm.sh/yum/
				enabled=1
				gpgcheck=1
				gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo
			fi
			sudo dnf install "$PACKAGE" -y
			;;
		*)
			echo "Could not detect package manager. Please install '$PACKAGE' manually."
			if [ "$PACKAGE" == "gum" ]; then
				exit 1
			fi
			;;
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

manage_saved() {
	gum style --border normal --margin "1" --padding "1 2" --border-foreground "$COLOR_INFO" "Manage Saved Networks"

	# List saved connections (Active or not)
	# Fields: NAME, UUID, TYPE, TIMESTAMP
	# Filter for 802-11-wireless
	SAVED_LIST=$(nmcli -t -f NAME,UUID,TYPE,TIMESTAMP connection show | grep ':802-11-wireless:' | sort -t: -k4 -r)

	if [ -z "$SAVED_LIST" ]; then
		log_info "No saved WiFi profiles found."
		exit 0
	fi

	# Format for display: "NAME (Last used: TIMESTAMP)"
	# We use awk to pretty print. note: nmcli timestamp is unix epoch or 0
	# actually nmcli timestamp might be a long int. 
	# Let's just show the Name for simplicity first, maybe UUID as value.
	
	# Create a list for gum choose
	# We replace colons in names to avoid gum parsing issues if we were doing key:value, but simple list is fine.
	# We'll display just the Names.
	
	SELECTED_NAME=$(echo "$SAVED_LIST" | cut -d: -f1 | gum choose --header "Select a profile to manage" --height 15 --cursor.foreground "$COLOR_INFO")

	if [ -z "$SELECTED_NAME" ]; then
		exit 0
	fi

	# Get UUID for the selected name (handle duplicates by picking most recent? nmcli sort should help)
	# We'll just pick the first one matching the name
	UUID=$(echo "$SAVED_LIST" | grep "^$SELECTED_NAME:" | head -n1 | cut -d: -f2)

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
		SSID=$(nmcli -g 802-11-wireless.ssid connection show "$UUID")
		
		if [ -n "$PASS" ]; then
			# Generate QR if possible
			if command -v qrencode &> /dev/null && [ -n "$SSID" ]; then
				gum style --foreground 252 "QR Code for '$SSID':"
				qrencode -t ANSIUTF8 "WIFI:S:$SSID;T:WPA;P:$PASS;;"
				echo
			fi
			
			gum style --border normal --padding "0 1" --border-foreground "$COLOR_SUCCESS" "Password: $PASS"
		else
			log_error "Could not retrieve password (permissions?)"
		fi
	fi
}

share_wifi() {
	gum style --border normal --margin "1" --padding "1 2" --border-foreground "$COLOR_INFO" "Share WiFi"

	# Check for active connection
	ACTIVE=$(nmcli -t -f NAME connection show --active | head -n1)
	if [ -z "$ACTIVE" ]; then
		log_error "Not connected to any network."
		exit 1
	fi

	# Attempt to retrieve credentials
	log_info "Retrieving credentials for '$ACTIVE'..."
	SECRETS=$(nmcli -s -g 802-11-wireless-security.psk connection show "$ACTIVE" 2>/dev/null)
	SSID=$(nmcli -g 802-11-wireless.ssid connection show "$ACTIVE")

	# Mode 1: Custom Layout using qrencode (Preferred for "Password Below")
	if command -v qrencode &> /dev/null && [ -n "$SECRETS" ]; then
		# Generate QR
        # WPA format: WIFI:S:MySSID;T:WPA;P:MyPass;;
        qrencode -t ANSIUTF8 "WIFI:S:$SSID;T:WPA;P:$SECRETS;;"
		
		# Show Password Below
		echo
		gum style --border normal --padding "0 1" --border-foreground "$COLOR_SUCCESS" "Password: $SECRETS"
		
	# Mode 2: Native nmcli QR (Fallback)
	# This usually puts password above, but it's a solid fallback if qrencode is missing or secrets hidden.
	elif nmcli device wifi show-password &> /dev/null; then
		nmcli device wifi show-password
		
	else
		log_error "Could not generate QR code."
		log_info "Ensure 'qrencode' is installed or you have permission to view connection secrets."
		if [ -z "$SECRETS" ]; then
			log_info "Hint: 'nmcli' could not retrieve the password."
		fi
		exit 1
	fi
}

run_speedtest() {
	gum style --border normal --margin "1" --padding "1 2" --border-foreground "$COLOR_INFO" "Speed Test"

	# Check if speedtest-cli is installed
	if ! command -v speedtest-cli &> /dev/null; then
		if gum confirm "speedtest-cli is not installed. Install it?"; then
			detect_os
			if [ -z "$OS" ]; then detect_os; fi # Ensure OS is set
			install_package "speedtest-cli"
		fi
	fi

	# Final check
	if ! command -v speedtest-cli &> /dev/null; then
		log_error "'speedtest-cli' is required. Exiting."
		exit 1
	fi

	log_info "Initialize speedtest-cli..."
	
	TMP_SPEED=$(mktemp)
	
	# Run speedtest-cli and live stream to stdout (tee) while capturing to file
	# We rely on standard output format of speedtest-cli
	if ! speedtest-cli | tee "$TMP_SPEED"; then
		rm "$TMP_SPEED"
		log_error "Speed test failed."
		exit 1
	fi
	
	echo # Newline after progress dots

	# Parse Output
	CLIENT=$(grep "Testing from" "$TMP_SPEED" | sed 's/Testing from //')
	SERVER_LINE=$(grep "Hosted by" "$TMP_SPEED")
	SERVER=$(echo "$SERVER_LINE" | cut -d: -f1 | sed 's/Hosted by //')
	PING=$(echo "$SERVER_LINE" | cut -d: -f2 | xargs)
	
	DOWNLOAD=$(grep "Download:" "$TMP_SPEED" | cut -d: -f2 | xargs)
	UPLOAD=$(grep "Upload:" "$TMP_SPEED" | cut -d: -f2 | xargs)
	
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
	else
		log_error "Could not parse results."
	fi
}

toggle_radio() {
	gum style --border normal --margin "1" --padding "1 2" --border-foreground "$COLOR_INFO" "WiFi Radio"

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
		exit 1
		;;
esac
