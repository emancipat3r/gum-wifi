package tui

import (
	"strings"
	"testing"

	"github.com/emancipat3r/gum-wifi/internal/nm"
)

func TestSignalBarsColorized(t *testing.T) {
	m := New(nil)
	m.networks = []nm.Network{
		{SSID: "strong", Strength: 80},
		{SSID: "medium", Strength: 40},
		{SSID: "weak", Strength: 10},
	}
	m.tbl.SetRows(m.rows())

	out := colorizeBars(m.tbl.View())
	for _, want := range []string{
		"\x1b[38;5;46m▰▰▰▰\x1b[39m",                // strong: green, all bars
		"\x1b[38;5;214m▰▰\x1b[38;5;240m▱▱\x1b[39m", // medium: amber fill, gray outline
		"\x1b[38;5;196m▰\x1b[38;5;240m▱▱▱\x1b[39m", // weak: red fill, gray outline
	} {
		if !strings.Contains(out, want) {
			t.Errorf("rendered view missing %q", want)
		}
	}
}

func TestSignalBars(t *testing.T) {
	for _, tc := range []struct {
		strength uint8
		bars     string
	}{
		{100, "▰▰▰▰"},
		{80, "▰▰▰▰"},
		{60, "▰▰▰▱"},
		{40, "▰▰▱▱"},
		{10, "▰▱▱▱"},
		{0, "▰▱▱▱"},
	} {
		got := signalBars(tc.strength)
		if !strings.HasPrefix(got, tc.bars) {
			t.Errorf("signalBars(%d) = %q, want prefix %q", tc.strength, got, tc.bars)
		}
	}
}

func TestPrettySSID(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"HomeNet", "HomeNet"},
		{" ", `" "`},
		{"  ", `"  "`},
		{" padded ", `" padded "`},
		{"", "(hidden)"},
	} {
		if got := prettySSID(tc.in); got != tc.want {
			t.Errorf("prettySSID(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
