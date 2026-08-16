// Package tui implements the Bubble Tea interface for gum-wifi: a live
// network list with connect/disconnect, password entry, and hidden-network
// support.
package tui

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/emancipat3r/gum-wifi/internal/nm"
)

const refreshEvery = 8 * time.Second

// Styles mirror the gum script's palette (pink info, green success, red error).
var (
	styleTitle   = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("212"))
	styleStatus  = lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
	styleOK      = lipgloss.NewStyle().Foreground(lipgloss.Color("46"))
	styleErr     = lipgloss.NewStyle().Foreground(lipgloss.Color("196"))
	styleWarn    = lipgloss.NewStyle().Foreground(lipgloss.Color("208"))
	styleHelp    = lipgloss.NewStyle().Foreground(lipgloss.Color("241"))
	styleKey     = lipgloss.NewStyle().Foreground(lipgloss.Color("212")).Bold(true)
	styleOverlay = lipgloss.NewStyle().Border(lipgloss.NormalBorder()).BorderForeground(lipgloss.Color("212")).Padding(1, 2)
)

type view int

const (
	viewList view = iota
	viewPassword
	viewHiddenSSID
	viewConnecting
	viewSaved
)

type (
	networksMsg struct {
		networks []nm.Network
		status   nm.Status
		err      error
	}
	connectDoneMsg struct {
		ssid string
		err  error
	}
	savedMsg struct {
		profiles []nm.Profile
		err      error
	}
	tickMsg time.Time
)

// Model is the top-level Bubble Tea model.
type Model struct {
	client *nm.Client

	view     view
	tbl      table.Model
	networks []nm.Network
	status   nm.Status

	savedTbl table.Model
	profiles []nm.Profile
	editUUID string // saved profile whose password is being changed
	editName string

	passInput    textinput.Model
	ssidInput    textinput.Model
	useWPA3      bool
	target       nm.Network // network being connected to
	hiddenSSID   string     // non-empty while in the hidden flow
	spin         spinner.Model
	connectingTo string

	flash    string // one-shot status line message
	flashErr bool
	width    int
	height   int
}

func New(client *nm.Client) Model {
	cols := []table.Column{
		{Title: " ", Width: 2},
		{Title: "SSID", Width: 32},
		{Title: "SIGNAL", Width: 10},
		{Title: "BAND", Width: 7},
		{Title: "SECURITY", Width: 12},
		{Title: "SAVED", Width: 6},
	}
	t := table.New(table.WithColumns(cols), table.WithFocused(true), table.WithHeight(14))
	ts := table.DefaultStyles()
	ts.Header = ts.Header.Bold(true).Foreground(lipgloss.Color("212")).BorderStyle(lipgloss.NormalBorder()).BorderBottom(true).BorderForeground(lipgloss.Color("240"))
	ts.Selected = ts.Selected.Foreground(lipgloss.Color("229")).Background(lipgloss.Color("57")).Bold(true)
	t.SetStyles(ts)

	savedCols := []table.Column{
		{Title: "NAME", Width: 26},
		{Title: "SSID", Width: 26},
		{Title: "LAST USED", Width: 17},
		{Title: "AUTO", Width: 5},
		{Title: "RANGE", Width: 6},
	}
	st := table.New(table.WithColumns(savedCols), table.WithFocused(true), table.WithHeight(14))
	st.SetStyles(ts)

	pass := textinput.New()
	pass.EchoMode = textinput.EchoPassword
	pass.Placeholder = "password"
	pass.CharLimit = 64

	ssid := textinput.New()
	ssid.Placeholder = "hidden network SSID"
	ssid.CharLimit = 32

	sp := spinner.New(spinner.WithSpinner(spinner.Dot))
	sp.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("212"))

	return Model{client: client, tbl: t, savedTbl: st, passInput: pass, ssidInput: ssid, spin: sp}
}

func (m Model) Init() tea.Cmd {
	m.client.RequestScan()
	return tea.Batch(m.refreshCmd(), tickCmd())
}

func tickCmd() tea.Cmd {
	return tea.Tick(refreshEvery, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m Model) refreshCmd() tea.Cmd {
	client := m.client
	return func() tea.Msg {
		nets, err := client.Networks()
		return networksMsg{networks: nets, status: client.Status(), err: err}
	}
}

func (m Model) loadSavedCmd() tea.Cmd {
	client := m.client
	return func() tea.Msg {
		profiles, err := client.SavedProfiles()
		return savedMsg{profiles: profiles, err: err}
	}
}

func (m Model) activateSavedCmd(uuid, name string) tea.Cmd {
	client := m.client
	return func() tea.Msg {
		return connectDoneMsg{ssid: name, err: client.ActivateSaved(uuid)}
	}
}

// updatePasswordCmd rewrites a saved profile's PSK in place, then brings the
// profile up so the new password is verified immediately.
func (m Model) updatePasswordCmd(uuid, name, password string) tea.Cmd {
	client := m.client
	return func() tea.Msg {
		if err := client.UpdatePassword(uuid, password); err != nil {
			return connectDoneMsg{ssid: name, err: err}
		}
		return connectDoneMsg{ssid: name, err: client.ActivateSaved(uuid)}
	}
}

func (m Model) connectCmd() tea.Cmd {
	client := m.client
	target := m.target
	hidden := m.hiddenSSID
	password := m.passInput.Value()
	wpa3 := m.useWPA3
	return func() tea.Msg {
		var err error
		ssid := target.SSID
		if hidden != "" {
			ssid = hidden
			err = client.ConnectHidden(hidden, password, wpa3)
		} else {
			err = client.Connect(target, password)
		}
		return connectDoneMsg{ssid: ssid, err: err}
	}
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		h := msg.Height - 8 // title + status + iface line + help + padding
		if h < 4 {
			h = 4
		}
		m.tbl.SetHeight(h)
		m.savedTbl.SetHeight(h)
		return m, nil

	case tickMsg:
		return m, tea.Batch(m.refreshCmd(), tickCmd())

	case networksMsg:
		if msg.err != nil {
			m.flash, m.flashErr = "scan failed: "+msg.err.Error(), true
			return m, nil
		}
		m.networks = msg.networks
		m.status = msg.status
		m.tbl.SetRows(m.rows())
		m.savedTbl.SetRows(m.savedRows()) // RANGE column tracks the scan
		return m, nil

	case savedMsg:
		if msg.err != nil {
			m.flash, m.flashErr = "loading profiles failed: "+msg.err.Error(), true
			return m, nil
		}
		m.profiles = msg.profiles
		m.savedTbl.SetRows(m.savedRows())
		return m, nil

	case connectDoneMsg:
		m.view = viewList
		m.connectingTo = ""
		m.hiddenSSID = ""
		m.editUUID, m.editName = "", ""
		m.passInput.Reset()
		if msg.err != nil {
			m.flash, m.flashErr = fmt.Sprintf("%s: %v", prettySSID(msg.ssid), msg.err), true
		} else {
			m.flash, m.flashErr = "connected to "+prettySSID(msg.ssid), false
		}
		return m, m.refreshCmd()

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd

	case tea.KeyMsg:
		return m.handleKey(msg)
	}
	return m, nil
}

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch m.view {
	case viewPassword:
		switch msg.String() {
		case "esc":
			if m.editUUID != "" {
				m.view = viewSaved
			} else {
				m.view = viewList
			}
			m.hiddenSSID = ""
			m.editUUID, m.editName = "", ""
			m.passInput.Reset()
			return m, nil
		case "tab":
			m.useWPA3 = !m.useWPA3
			return m, nil
		case "enter":
			if m.editUUID != "" {
				password := m.passInput.Value()
				if password == "" {
					return m, nil
				}
				m.view = viewConnecting
				m.connectingTo = prettySSID(m.editName)
				m.passInput.Reset()
				return m, tea.Batch(m.spin.Tick, m.updatePasswordCmd(m.editUUID, m.editName, password))
			}
			return m.startConnect()
		}
		var cmd tea.Cmd
		m.passInput, cmd = m.passInput.Update(msg)
		return m, cmd

	case viewHiddenSSID:
		switch msg.String() {
		case "esc":
			m.view = viewList
			m.ssidInput.Reset()
			return m, nil
		case "enter":
			ssid := strings.TrimSpace(m.ssidInput.Value())
			if ssid == "" {
				return m, nil
			}
			m.hiddenSSID = ssid
			m.ssidInput.Reset()
			// Hidden networks: always offer the password prompt; leaving it
			// empty joins as an open network.
			m.view = viewPassword
			m.passInput.Placeholder = "password (empty for open network)"
			m.passInput.Focus()
			return m, textinput.Blink
		}
		var cmd tea.Cmd
		m.ssidInput, cmd = m.ssidInput.Update(msg)
		return m, cmd

	case viewConnecting:
		return m, nil // ignore input while connecting

	case viewSaved:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "esc", "s":
			m.view = viewList
			return m, nil
		case "enter":
			if p, ok := m.selectedProfile(); ok {
				m.view = viewConnecting
				m.connectingTo = prettySSID(p.Name)
				return m, tea.Batch(m.spin.Tick, m.activateSavedCmd(p.UUID, p.Name))
			}
			return m, nil
		case "p":
			if p, ok := m.selectedProfile(); ok {
				m.editUUID, m.editName = p.UUID, p.Name
				m.view = viewPassword
				m.passInput.Placeholder = "new password for " + prettySSID(p.Name)
				m.passInput.Focus()
				return m, textinput.Blink
			}
			return m, nil
		case "a":
			if p, ok := m.selectedProfile(); ok {
				if err := m.client.SetAutoconnect(p.UUID, !p.Autoconnect); err != nil {
					m.flash, m.flashErr = "autoconnect toggle failed: "+err.Error(), true
				} else {
					m.flash, m.flashErr = fmt.Sprintf("autoconnect %s for %s", onOff(!p.Autoconnect), prettySSID(p.Name)), false
				}
				return m, m.loadSavedCmd()
			}
			return m, nil
		case "w":
			if p, ok := m.selectedProfile(); ok {
				if psk, err := m.client.Password(p.UUID); err != nil {
					m.flash, m.flashErr = err.Error(), true
				} else {
					m.flash, m.flashErr = fmt.Sprintf("password for %s: %s", prettySSID(p.Name), psk), false
				}
			}
			return m, nil
		case "f":
			if p, ok := m.selectedProfile(); ok {
				if err := m.client.Forget(p.UUID); err != nil {
					m.flash, m.flashErr = "forget failed: "+err.Error(), true
				} else {
					m.flash, m.flashErr = "forgot profile "+prettySSID(p.Name), false
				}
				return m, tea.Batch(m.loadSavedCmd(), m.refreshCmd())
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.savedTbl, cmd = m.savedTbl.Update(msg)
		return m, cmd

	default: // viewList
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "r":
			m.client.RequestScan()
			m.flash, m.flashErr = "rescanning…", false
			return m, m.refreshCmd()
		case "d":
			if err := m.client.Disconnect(); err != nil {
				m.flash, m.flashErr = "disconnect failed: "+err.Error(), true
			} else {
				m.flash, m.flashErr = "disconnected", false
			}
			return m, m.refreshCmd()
		case "h":
			m.view = viewHiddenSSID
			m.ssidInput.Focus()
			return m, textinput.Blink
		case "s":
			m.view = viewSaved
			return m, m.loadSavedCmd()
		case "f":
			if n, ok := m.selected(); ok && n.KnownUUID != "" {
				if err := m.client.Forget(n.KnownUUID); err != nil {
					m.flash, m.flashErr = "forget failed: "+err.Error(), true
				} else {
					m.flash, m.flashErr = "forgot profile for "+n.SSID, false
				}
				return m, m.refreshCmd()
			}
			return m, nil
		case "enter":
			n, ok := m.selected()
			if !ok {
				return m, nil
			}
			m.target = n
			m.hiddenSSID = ""
			m.useWPA3 = n.Security == nm.SecSAE
			if n.Hidden {
				// Beacon with no SSID: we need the name before anything else.
				m.view = viewHiddenSSID
				m.ssidInput.Focus()
				return m, textinput.Blink
			}
			// Saved profile or no password needed: connect directly.
			if n.KnownUUID != "" || n.Security == nm.SecOpen || n.Security == nm.SecOWE {
				return m.startConnect()
			}
			if n.Security == nm.SecEnterprise {
				m.flash, m.flashErr = "802.1X enterprise networks are not supported yet", true
				return m, nil
			}
			m.view = viewPassword
			m.passInput.Placeholder = "password for " + n.SSID
			m.passInput.Focus()
			return m, textinput.Blink
		}
		var cmd tea.Cmd
		m.tbl, cmd = m.tbl.Update(msg)
		return m, cmd
	}
}

func (m Model) startConnect() (tea.Model, tea.Cmd) {
	m.view = viewConnecting
	if m.hiddenSSID != "" {
		m.connectingTo = prettySSID(m.hiddenSSID) + " (hidden)"
	} else {
		m.connectingTo = prettySSID(m.target.SSID)
	}
	return m, tea.Batch(m.spin.Tick, m.connectCmd())
}

func (m Model) selectedProfile() (nm.Profile, bool) {
	i := m.savedTbl.Cursor()
	if i < 0 || i >= len(m.profiles) {
		return nm.Profile{}, false
	}
	return m.profiles[i], true
}

func (m Model) savedRows() []table.Row {
	inRange := make(map[string]bool, len(m.networks))
	for _, n := range m.networks {
		inRange[n.SSID] = true
	}
	rows := make([]table.Row, 0, len(m.profiles))
	for _, p := range m.profiles {
		ssid := prettySSID(p.SSID)
		if p.Hidden {
			ssid += " (hidden)"
		}
		last := "never"
		if !p.LastUsed.IsZero() {
			last = p.LastUsed.Format("2006-01-02 15:04")
		}
		auto, rng := "", ""
		if p.Autoconnect {
			auto = "✓"
		}
		if inRange[p.SSID] {
			rng = "✓"
		}
		rows = append(rows, table.Row{prettySSID(p.Name), ssid, last, auto, rng})
	}
	return rows
}

func onOff(b bool) string {
	if b {
		return "on"
	}
	return "off"
}

func (m Model) selected() (nm.Network, bool) {
	i := m.tbl.Cursor()
	if i < 0 || i >= len(m.networks) {
		return nm.Network{}, false
	}
	return m.networks[i], true
}

func (m Model) rows() []table.Row {
	rows := make([]table.Row, 0, len(m.networks))
	for _, n := range m.networks {
		marker := " "
		if n.InUse {
			marker = "✓"
		}
		name := prettySSID(n.SSID)
		if n.Hidden {
			name = n.BSSID + " (hidden)"
		}
		saved := ""
		if n.KnownUUID != "" {
			saved = "✓"
		}
		rows = append(rows, table.Row{marker, name, signalBars(n.Strength), n.Band(), n.SecLabel, saved})
	}
	return rows
}

// helpLine renders alternating key/description pairs with the keys
// highlighted so actions stand apart from their descriptions.
func helpLine(pairs ...string) string {
	items := make([]string, 0, len(pairs)/2)
	for i := 0; i+1 < len(pairs); i += 2 {
		items = append(items, styleKey.Render(pairs[i])+" "+styleHelp.Render(pairs[i+1]))
	}
	return strings.Join(items, styleHelp.Render(" · "))
}

// ifaceLine renders the wifi interface details under the connection status:
// interface name and MAC always, IP/gateway/link rate when connected.
func (m Model) ifaceLine() string {
	st := m.status
	if st.Iface == "" {
		return ""
	}
	parts := []string{st.Iface}
	if st.MAC != "" {
		parts = append(parts, st.MAC)
	}
	if st.IP != "" {
		parts = append(parts, st.IP)
	}
	if st.Gateway != "" {
		parts = append(parts, "gw "+st.Gateway)
	}
	if st.Bitrate > 0 {
		parts = append(parts, fmt.Sprintf("%d Mb/s", st.Bitrate/1000))
	}
	return strings.Join(parts, " · ")
}

// prettySSID makes otherwise-invisible SSIDs visible: whitespace-only names
// (like " ") and names with leading/trailing spaces render Go-quoted, and an
// empty name is labeled hidden.
func prettySSID(ssid string) string {
	if ssid == "" {
		return "(hidden)"
	}
	if trimmed := strings.TrimSpace(ssid); trimmed == "" || trimmed != ssid {
		return fmt.Sprintf("%q", ssid)
	}
	return ssid
}

func signalBars(s uint8) string {
	bars := int(s)/25 + 1
	if bars > 4 {
		bars = 4
	}
	return strings.Repeat("▰", bars) + strings.Repeat("▱", 4-bars) + fmt.Sprintf("  %3d", s)
}

// colorizeBars colors the signal-bar glyphs green/amber/red by strength. It
// runs on the table's rendered output because the table's cell truncation
// (runewidth.Truncate) is not ANSI-aware and would mangle codes embedded in
// row data. Foreground-only codes (39 restores the default) preserve the
// selected row's background highlight.
// Empty outline glyphs are dimmed to gray so they recede behind the colored
// fill instead of visually competing with it.
var barColors = strings.NewReplacer(
	"▰▰▰▰", "\x1b[38;5;46m▰▰▰▰\x1b[39m",
	"▰▰▰▱", "\x1b[38;5;46m▰▰▰\x1b[38;5;240m▱\x1b[39m",
	"▰▰▱▱", "\x1b[38;5;214m▰▰\x1b[38;5;240m▱▱\x1b[39m",
	"▰▱▱▱", "\x1b[38;5;196m▰\x1b[38;5;240m▱▱▱\x1b[39m",
)

func colorizeBars(s string) string {
	return barColors.Replace(s)
}

func (m Model) View() string {
	var b strings.Builder
	b.WriteString(styleTitle.Render("gum-wifi") + "\n")

	// Status bar
	st := m.status
	line := "wifi off"
	if st.WifiEnabled {
		if st.ActiveSSID != "" {
			line = "connected: " + styleOK.Render(prettySSID(st.ActiveSSID))
			if l := nm.ConnectivityLabel(st.Connectivity); l != "" && l != "online" {
				line += "  " + styleWarn.Render("("+l+")")
			}
		} else {
			line = "not connected"
		}
	}
	b.WriteString(styleStatus.Render(line) + "\n")
	b.WriteString(styleHelp.Render(m.ifaceLine()) + "\n\n")

	switch m.view {
	case viewPassword:
		title := "Password"
		if m.hiddenSSID != "" {
			title = "Hidden network: " + m.hiddenSSID
		} else if m.target.SSID != "" {
			title = prettySSID(m.target.SSID)
		}
		mode := "WPA2-PSK"
		if m.useWPA3 {
			mode = "WPA3-SAE"
		}
		b.WriteString(styleOverlay.Render(
			title + "\n\n" + m.passInput.View() + "\n\n" +
				helpLine("enter", "connect", "tab", "key-mgmt ["+mode+"]", "esc", "cancel")))
	case viewHiddenSSID:
		b.WriteString(styleOverlay.Render(
			"Connect to hidden network\n\n" + m.ssidInput.View() + "\n\n" +
				helpLine("enter", "continue", "esc", "cancel")))
	case viewConnecting:
		b.WriteString(m.spin.View() + " connecting to " + m.connectingTo + "…")
	case viewSaved:
		b.WriteString(m.savedTbl.View())
	default:
		b.WriteString(colorizeBars(m.tbl.View()))
	}
	b.WriteString("\n")

	if m.flash != "" {
		s := styleOK
		if m.flashErr {
			s = styleErr
		}
		b.WriteString(s.Render(m.flash) + "\n")
	}
	switch m.view {
	case viewList:
		b.WriteString(helpLine(
			"enter", "connect",
			"d", "disconnect",
			"h", "hidden",
			"s", "saved",
			"f", "forget",
			"r", "rescan",
			"q", "quit",
		))
	case viewSaved:
		b.WriteString(helpLine(
			"enter", "connect",
			"p", "password",
			"a", "autoconnect",
			"w", "reveal",
			"f", "forget",
			"esc", "back",
		))
	}
	return b.String()
}
