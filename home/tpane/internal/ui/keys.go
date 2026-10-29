package ui

import "charm.land/bubbles/v2/key"

func bind(help, desc string, keys ...string) key.Binding {
	return key.NewBinding(key.WithKeys(keys...), key.WithHelp(help, desc))
}

var keys = struct {
	Up, Down, PgUp, PgDown, Top, Bottom        key.Binding
	Collapse, Expand, Toggle                   key.Binding
	Filter, Help, Refresh, Quit                key.Binding
	Enter, SwapDown, SwapUp, MoveTo            key.Binding
	Break, BreakNamed, Join, Mark, Kill        key.Binding
	Zoom, Title, Rename, Layout, Renumber      key.Binding
	PickToggle, Confirm, Cancel, Accept, Clear key.Binding
}{
	Up:         bind("↑/k", "up", "up", "k"),
	Down:       bind("↓/j", "down", "down", "j"),
	PgUp:       bind("pgup", "page up", "pgup", "ctrl+u"),
	PgDown:     bind("pgdn", "page down", "pgdown", "ctrl+d"),
	Top:        bind("g", "top", "g", "home"),
	Bottom:     bind("G", "bottom", "G", "end"),
	Collapse:   bind("←/h", "collapse", "left", "h"),
	Expand:     bind("→/l", "expand", "right", "l"),
	Toggle:     bind("space", "fold", "space", "tab"),
	Filter:     bind("/", "filter", "/"),
	Help:       bind("?", "help", "?"),
	Refresh:    bind("ctrl+r", "refresh", "ctrl+r"),
	Quit:       bind("q", "quit", "q"),
	Enter:      bind("enter", "focus", "enter"),
	SwapDown:   bind("J", "swap down", "J"),
	SwapUp:     bind("K", "swap up", "K"),
	MoveTo:     bind("0-9", "move to index", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"),
	Break:      bind("b", "break out", "b"),
	BreakNamed: bind("B", "break + name", "B"),
	Join:       bind("m", "move to window", "m"),
	Mark:       bind("s", "mark/swap", "s"),
	Kill:       bind("x", "kill", "x"),
	Zoom:       bind("z", "zoom", "z"),
	Title:      bind("t", "title", "t"),
	Rename:     bind("r", "rename", "r"),
	Layout:     bind("L", "next layout", "L"),
	Renumber:   bind("R", "renumber", "R"),
	PickToggle: bind("tab", "split direction", "tab"),
	Confirm:    bind("y", "yes", "y", "Y"),
	Cancel:     bind("esc", "cancel", "esc"),
	Accept:     bind("enter", "confirm", "enter"),
	Clear:      bind("esc", "clear", "esc"),
}

func withHelp(b key.Binding, desc string) key.Binding {
	b.SetHelp(b.Help().Key, desc)
	return b
}

// contextHelp is the one-line help for the current mode and selected row.
func (m *Model) contextHelp() []key.Binding {
	switch m.mode {
	case modePrompt:
		return []key.Binding{keys.Accept, keys.Cancel}
	case modeConfirm:
		return []key.Binding{keys.Confirm, bind("any", "cancel", "n")}
	case modePicker:
		return []key.Binding{keys.Up, keys.Down, keys.PickToggle, withHelp(keys.Accept, "move here"), keys.Cancel}
	case modeHelp:
		return []key.Binding{bind("any key", "close", "esc")}
	}
	if m.filtering {
		return []key.Binding{bind("↑/↓", "move", "up"), withHelp(keys.Accept, "keep filter"), keys.Clear}
	}
	nav := []key.Binding{keys.Filter, keys.Help, keys.Quit}
	r := m.sel()
	if r == nil {
		return append([]key.Binding{keys.Refresh}, nav...)
	}
	var b []key.Binding
	switch r.kind {
	case rowPane:
		b = []key.Binding{
			keys.Enter, bind("J/K", "swap", "J"), keys.MoveTo, keys.Mark, keys.Join,
			keys.Break, keys.BreakNamed, keys.Zoom, keys.Title, keys.Kill,
		}
	case rowWindow:
		b = []key.Binding{
			keys.Enter, bind("J/K", "swap", "J"), keys.MoveTo, keys.Rename, keys.Layout,
			keys.Renumber, keys.Kill, keys.Toggle,
		}
	case rowSession:
		b = []key.Binding{withHelp(keys.Enter, "switch"), keys.Rename, keys.Renumber, keys.Kill, keys.Toggle}
	}
	return append(b, nav...)
}

type helpSection struct {
	title string
	keys  []key.Binding
}

func fullHelp() []helpSection {
	return []helpSection{
		{"Everywhere", []key.Binding{
			keys.Up, keys.Down, keys.Top, keys.Bottom, keys.PgDown,
			keys.Collapse, keys.Expand, keys.Toggle,
			keys.Filter, keys.Refresh, keys.Help, bind("q/esc", "quit", "q"),
		}},
		{"Pane", []key.Binding{
			withHelp(keys.Enter, "focus + quit"), withHelp(keys.SwapDown, "swap with next"),
			withHelp(keys.SwapUp, "swap with prev"), keys.MoveTo, keys.Break, keys.BreakNamed,
			keys.Join, withHelp(keys.Mark, "mark, then swap"), keys.Zoom, keys.Title, keys.Kill,
		}},
		{"Window", []key.Binding{
			withHelp(keys.Enter, "focus + quit"), withHelp(keys.SwapDown, "swap with next"),
			withHelp(keys.SwapUp, "swap with prev"), keys.MoveTo, keys.Rename, keys.Layout,
			withHelp(keys.Renumber, "renumber session"), keys.Kill,
		}},
		{"Session", []key.Binding{
			withHelp(keys.Enter, "switch + quit"), keys.Rename, withHelp(keys.Renumber, "renumber windows"), keys.Kill,
		}},
	}
}
