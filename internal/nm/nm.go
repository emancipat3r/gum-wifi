// Package nm wraps NetworkManager's D-Bus API for the parts gum-wifi needs:
// scanning, connecting (including hidden and WPA3 networks), and status.
package nm

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	gonm "github.com/Wifx/gonetworkmanager/v2"
	"github.com/godbus/dbus/v5"
)

// Security classifies what a network requires to connect.
type Security int

const (
	SecOpen       Security = iota
	SecPSK                 // WPA1/WPA2 pre-shared key
	SecSAE                 // WPA3-only
	SecEnterprise          // 802.1X
	SecWEP
	SecOWE // opportunistic wireless encryption (open, but encrypted)
)

// Network is one selectable row in the UI: APs with the same SSID are
// collapsed into a single entry keeping the strongest signal.
type Network struct {
	SSID      string
	BSSID     string // strongest AP
	Strength  uint8
	Freq      uint32 // MHz
	Security  Security
	SecLabel  string
	Hidden    bool // beacon with no SSID broadcast
	InUse     bool
	KnownUUID string // UUID of a saved profile for this SSID, if any
	apPath    dbus.ObjectPath
}

// Band returns "2.4" or "5"/"6" GHz for display.
func (n Network) Band() string {
	switch {
	case n.Freq >= 5925:
		return "6GHz"
	case n.Freq >= 4900:
		return "5GHz"
	case n.Freq > 0:
		return "2.4GHz"
	default:
		return ""
	}
}

// Status is a snapshot of the wifi device state for the status bar.
type Status struct {
	ActiveSSID   string
	Connectivity gonm.NmConnectivity
	WifiEnabled  bool

	Iface   string // e.g. wlp3s0
	MAC     string
	IP      string // CIDR, empty when not connected
	Gateway string
	Bitrate uint32 // Kb/s, 0 when unknown
}

// Client owns the D-Bus handles for the first wifi device found.
type Client struct {
	nm       gonm.NetworkManager
	settings gonm.Settings
	dev      gonm.Device
	wdev     gonm.DeviceWireless
}

func New() (*Client, error) {
	n, err := gonm.NewNetworkManager()
	if err != nil {
		return nil, fmt.Errorf("connecting to NetworkManager (is it running?): %w", err)
	}
	st, err := gonm.NewSettings()
	if err != nil {
		return nil, err
	}
	devs, err := n.GetPropertyAllDevices()
	if err != nil {
		return nil, err
	}
	for _, d := range devs {
		t, err := d.GetPropertyDeviceType()
		if err != nil {
			continue
		}
		if t == gonm.NmDeviceTypeWifi {
			w, err := gonm.NewDeviceWireless(d.GetPath())
			if err != nil {
				return nil, err
			}
			return &Client{nm: n, settings: st, dev: d, wdev: w}, nil
		}
	}
	return nil, errors.New("no wifi device found")
}

// RequestScan asks the device to rescan; results land in the AP list shortly
// after. Errors are ignored because NM rejects scans requested too frequently.
func (c *Client) RequestScan() {
	_ = c.wdev.RequestScan()
}

// Networks returns the current (cached) AP list, deduped by SSID, sorted by
// in-use first then signal strength. Hidden APs are listed by BSSID.
func (c *Client) Networks() ([]Network, error) {
	aps, err := c.wdev.GetPropertyAccessPoints()
	if err != nil {
		return nil, err
	}

	var activePath dbus.ObjectPath
	if active, err := c.wdev.GetPropertyActiveAccessPoint(); err == nil && active != nil {
		activePath = active.GetPath()
	}

	saved, _ := c.savedWifiSSIDs()

	best := map[string]*Network{} // keyed by SSID, or "\x00"+BSSID for hidden
	for _, ap := range aps {
		ssid, err := ap.GetPropertySSID()
		if err != nil {
			continue
		}
		strength, _ := ap.GetPropertyStrength()
		freq, _ := ap.GetPropertyFrequency()
		bssid, _ := ap.GetPropertyHWAddress()
		flags, _ := ap.GetPropertyFlags()
		wpa, _ := ap.GetPropertyWPAFlags()
		rsn, _ := ap.GetPropertyRSNFlags()

		sec, label := classifySecurity(flags, wpa, rsn)
		n := Network{
			SSID:     ssid,
			BSSID:    bssid,
			Strength: strength,
			Freq:     freq,
			Security: sec,
			SecLabel: label,
			Hidden:   ssid == "",
			InUse:    ap.GetPath() == activePath,
			apPath:   ap.GetPath(),
		}
		if uuid, ok := saved[ssid]; ok && ssid != "" {
			n.KnownUUID = uuid
		}

		key := ssid
		if n.Hidden {
			key = "\x00" + bssid
		}
		if cur, ok := best[key]; !ok || n.InUse || (!cur.InUse && strength > cur.Strength) {
			best[key] = &n
		}
	}

	list := make([]Network, 0, len(best))
	for _, n := range best {
		list = append(list, *n)
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].InUse != list[j].InUse {
			return list[i].InUse
		}
		return list[i].Strength > list[j].Strength
	})
	return list, nil
}

// Status snapshots the active SSID and connectivity state.
func (c *Client) Status() Status {
	s := Status{}
	s.WifiEnabled, _ = c.nm.GetPropertyWirelessEnabled()
	s.Connectivity, _ = c.nm.GetPropertyConnectivity()
	s.Iface, _ = c.dev.GetPropertyInterface()
	s.MAC, _ = c.wdev.GetPropertyHwAddress()
	if ap, err := c.wdev.GetPropertyActiveAccessPoint(); err == nil && ap != nil {
		if ssid, err := ap.GetPropertySSID(); err == nil {
			s.ActiveSSID = ssid
		}
	}
	s.Bitrate, _ = c.wdev.GetPropertyBitrate()
	if ipc, err := c.dev.GetPropertyIP4Config(); err == nil && ipc != nil {
		if addrs, err := ipc.GetPropertyAddressData(); err == nil && len(addrs) > 0 {
			s.IP = fmt.Sprintf("%s/%d", addrs[0].Address, addrs[0].Prefix)
		}
		s.Gateway, _ = ipc.GetPropertyGateway()
	}
	return s
}

// Connect joins a scanned network. Empty password is fine for open networks
// and for SSIDs with a saved profile (stored secrets are used).
func (c *Client) Connect(n Network, password string) error {
	// Prefer an existing saved profile — it has the credentials.
	if n.KnownUUID != "" && password == "" {
		conn, err := c.connectionByUUID(n.KnownUUID)
		if err == nil {
			return c.waitActivation(func() (gonm.ActiveConnection, error) {
				return c.nm.ActivateConnection(conn, c.dev, nil)
			}, false)
		}
	}

	if n.Security == SecEnterprise {
		return errors.New("802.1X enterprise networks are not supported yet")
	}

	settings := newWifiSettings(n.SSID, password, n.Security == SecSAE, false)
	ap, err := gonm.NewAccessPoint(n.apPath)
	if err != nil {
		return err
	}
	return c.waitActivation(func() (gonm.ActiveConnection, error) {
		return c.nm.AddAndActivateWirelessConnection(settings, c.dev, ap)
	}, true)
}

// ConnectHidden joins a network that does not broadcast its SSID. The profile
// is created with 802-11-wireless.hidden=yes so NetworkManager probes for the
// SSID now and on autoconnect after reboot/wake.
func (c *Client) ConnectHidden(ssid, password string, wpa3 bool) error {
	if ssid == "" {
		return errors.New("SSID is required")
	}
	// A saved profile for this SSID already knows how to connect.
	if saved, _ := c.savedWifiSSIDs(); saved[ssid] != "" && password == "" {
		if conn, err := c.connectionByUUID(saved[ssid]); err == nil {
			return c.waitActivation(func() (gonm.ActiveConnection, error) {
				return c.nm.ActivateConnection(conn, c.dev, nil)
			}, false)
		}
	}
	settings := newWifiSettings(ssid, password, wpa3, true)
	return c.waitActivation(func() (gonm.ActiveConnection, error) {
		return c.nm.AddAndActivateConnection(settings, c.dev)
	}, true)
}

// Profile is a saved wifi connection profile.
type Profile struct {
	Name        string
	UUID        string
	SSID        string
	Hidden      bool
	Autoconnect bool
	LastUsed    time.Time // zero when never used
}

// SavedProfiles lists all saved wifi profiles, most recently used first.
func (c *Client) SavedProfiles() ([]Profile, error) {
	conns, err := c.settings.ListConnections()
	if err != nil {
		return nil, err
	}
	var out []Profile
	for _, conn := range conns {
		s, err := conn.GetSettings()
		if err != nil {
			continue
		}
		wifi, ok := s["802-11-wireless"]
		if !ok {
			continue
		}
		meta := s["connection"]
		p := Profile{Autoconnect: true} // NM default when the key is absent
		p.Name, _ = meta["id"].(string)
		p.UUID, _ = meta["uuid"].(string)
		if v, ok := meta["autoconnect"].(bool); ok {
			p.Autoconnect = v
		}
		if ts, ok := meta["timestamp"].(uint64); ok && ts > 0 {
			p.LastUsed = time.Unix(int64(ts), 0)
		}
		if b, ok := wifi["ssid"].([]byte); ok {
			p.SSID = string(b)
		}
		p.Hidden, _ = wifi["hidden"].(bool)
		if p.UUID != "" {
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].LastUsed.After(out[j].LastUsed) })
	return out, nil
}

// ActivateSaved brings up a saved profile using its stored secrets.
func (c *Client) ActivateSaved(uuid string) error {
	conn, err := c.connectionByUUID(uuid)
	if err != nil {
		return err
	}
	return c.waitActivation(func() (gonm.ActiveConnection, error) {
		return c.nm.ActivateConnection(conn, c.dev, nil)
	}, false)
}

// SetAutoconnect toggles a saved profile's autoconnect flag.
func (c *Client) SetAutoconnect(uuid string, on bool) error {
	conn, err := c.connectionByUUID(uuid)
	if err != nil {
		return err
	}
	s, err := conn.GetSettings()
	if err != nil {
		return err
	}
	s["connection"]["autoconnect"] = on
	return conn.Update(s)
}

// UpdatePassword replaces the PSK of a saved profile in place, preserving the
// rest of its settings (autoconnect, hidden flag, priority, ...).
func (c *Client) UpdatePassword(uuid, psk string) error {
	conn, err := c.connectionByUUID(uuid)
	if err != nil {
		return err
	}
	s, err := conn.GetSettings()
	if err != nil {
		return err
	}
	sec, ok := s["802-11-wireless-security"]
	if !ok {
		sec = map[string]interface{}{"key-mgmt": "wpa-psk"}
		s["802-11-wireless-security"] = sec
	}
	sec["psk"] = psk
	return conn.Update(s)
}

// Password returns the stored PSK of a saved profile. NetworkManager may
// require polkit authorization for this.
func (c *Client) Password(uuid string) (string, error) {
	conn, err := c.connectionByUUID(uuid)
	if err != nil {
		return "", err
	}
	secrets, err := conn.GetSecrets("802-11-wireless-security")
	if err != nil {
		return "", fmt.Errorf("could not read secrets (polkit denied?): %w", err)
	}
	if sec, ok := secrets["802-11-wireless-security"]; ok {
		if psk, ok := sec["psk"].(string); ok {
			return psk, nil
		}
	}
	return "", errors.New("no password stored (open network?)")
}

// Disconnect tears down the device's active connection.
func (c *Client) Disconnect() error {
	return c.dev.Disconnect()
}

// Forget deletes the saved profile for a network.
func (c *Client) Forget(uuid string) error {
	conn, err := c.connectionByUUID(uuid)
	if err != nil {
		return err
	}
	return conn.Delete()
}

// waitActivation runs the activation and polls until it settles. If the
// attempt created a new profile (cleanupOnFail) and activation fails — e.g.
// wrong password — the junk profile is deleted so retries start clean.
func (c *Client) waitActivation(activate func() (gonm.ActiveConnection, error), cleanupOnFail bool) error {
	ac, err := activate()
	if err != nil {
		return err
	}
	var newConn gonm.Connection
	if cleanupOnFail {
		newConn, _ = ac.GetPropertyConnection()
	}

	deadline := time.Now().Add(45 * time.Second)
	for time.Now().Before(deadline) {
		state, err := ac.GetPropertyState()
		if err != nil {
			// The ActiveConnection object disappears when activation fails.
			if newConn != nil {
				_ = newConn.Delete()
			}
			return errors.New("connection failed (wrong password?)")
		}
		switch state {
		case gonm.NmActiveConnectionStateActivated:
			return nil
		case gonm.NmActiveConnectionStateDeactivated:
			if newConn != nil {
				_ = newConn.Delete()
			}
			return errors.New("connection failed (wrong password?)")
		}
		time.Sleep(300 * time.Millisecond)
	}
	if newConn != nil {
		_ = newConn.Delete()
	}
	return errors.New("connection timed out")
}

func (c *Client) connectionByUUID(uuid string) (gonm.Connection, error) {
	conns, err := c.settings.ListConnections()
	if err != nil {
		return nil, err
	}
	for _, conn := range conns {
		s, err := conn.GetSettings()
		if err != nil {
			continue
		}
		if meta, ok := s["connection"]; ok {
			if u, _ := meta["uuid"].(string); u == uuid {
				return conn, nil
			}
		}
	}
	return nil, fmt.Errorf("no saved connection with uuid %s", uuid)
}

// savedWifiSSIDs maps SSID -> profile UUID for all saved wifi profiles.
func (c *Client) savedWifiSSIDs() (map[string]string, error) {
	out := map[string]string{}
	conns, err := c.settings.ListConnections()
	if err != nil {
		return out, err
	}
	for _, conn := range conns {
		s, err := conn.GetSettings()
		if err != nil {
			continue
		}
		wifi, ok := s["802-11-wireless"]
		if !ok {
			continue
		}
		ssidBytes, _ := wifi["ssid"].([]byte)
		meta := s["connection"]
		uuid, _ := meta["uuid"].(string)
		if len(ssidBytes) > 0 && uuid != "" {
			out[string(ssidBytes)] = uuid
		}
	}
	return out, nil
}

func newWifiSettings(ssid, password string, wpa3, hidden bool) map[string]map[string]interface{} {
	s := map[string]map[string]interface{}{
		"connection": {
			"id":   ssid,
			"type": "802-11-wireless",
		},
		"802-11-wireless": {
			"ssid": []byte(ssid),
			"mode": "infrastructure",
		},
	}
	if hidden {
		s["802-11-wireless"]["hidden"] = true
	}
	if password != "" {
		keyMgmt := "wpa-psk"
		if wpa3 {
			keyMgmt = "sae"
		}
		s["802-11-wireless-security"] = map[string]interface{}{
			"key-mgmt": keyMgmt,
			"psk":      password,
		}
	}
	return s
}

const apFlagPrivacy = 0x1

func classifySecurity(flags, wpa, rsn uint32) (Security, string) {
	if wpa == 0 && rsn == 0 {
		if flags&apFlagPrivacy != 0 {
			return SecWEP, "WEP"
		}
		return SecOpen, "Open"
	}

	var parts []string
	sec := SecPSK
	if wpa != 0 {
		parts = append(parts, "WPA1")
	}
	if rsn&uint32(gonm.Nm80211APSecKeyMgmtPSK) != 0 {
		parts = append(parts, "WPA2")
	}
	if rsn&uint32(gonm.Nm80211APSecKeyMgmtSAE) != 0 {
		parts = append(parts, "WPA3")
		// WPA3-only (no PSK fallback) requires SAE key management.
		if rsn&uint32(gonm.Nm80211APSecKeyMgmtPSK) == 0 && wpa == 0 {
			sec = SecSAE
		}
	}
	if rsn&uint32(gonm.Nm80211APSecKeyMgmt8021X) != 0 || wpa&uint32(gonm.Nm80211APSecKeyMgmt8021X) != 0 {
		return SecEnterprise, "802.1X"
	}
	if rsn&uint32(gonm.Nm80211APSecKeyMgmtOWE) != 0 || rsn&uint32(gonm.Nm80211APSecKeyMgmtOWETM) != 0 {
		return SecOWE, "OWE"
	}
	if len(parts) == 0 {
		return SecPSK, "Secured"
	}
	return sec, strings.Join(parts, " ")
}

// ConnectivityLabel renders the NM connectivity enum for the status bar.
func ConnectivityLabel(c gonm.NmConnectivity) string {
	switch c {
	case gonm.NmConnectivityFull:
		return "online"
	case gonm.NmConnectivityPortal:
		return "captive portal"
	case gonm.NmConnectivityLimited:
		return "limited"
	case gonm.NmConnectivityNone:
		return "offline"
	default:
		return ""
	}
}
