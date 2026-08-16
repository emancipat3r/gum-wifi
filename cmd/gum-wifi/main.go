package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/emancipat3r/gum-wifi/internal/nm"
	"github.com/emancipat3r/gum-wifi/internal/tui"
)

func main() {
	client, err := nm.New()
	if err != nil {
		fmt.Fprintln(os.Stderr, "gum-wifi:", err)
		os.Exit(1)
	}
	p := tea.NewProgram(tui.New(client), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "gum-wifi:", err)
		os.Exit(1)
	}
}
