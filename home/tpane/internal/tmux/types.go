package tmux

// Session, Window and Pane are a snapshot of the server from one Tree() call.
// IDs are tmux's stable ids ("$1", "@3", "%12"); indexes are positional and
// change whenever things are swapped or moved.
type Session struct {
	ID       string
	Name     string
	Attached bool
	Windows  []Window // sorted by Index
}

type Window struct {
	ID            string
	SessionID     string
	Index         int
	Name          string
	Active        bool // the session's current window
	Zoomed        bool
	Layout        string // window_layout
	Width, Height int
	Panes         []Pane // sorted by Index
}

type Pane struct {
	ID            string
	WindowID      string
	SessionID     string
	Index         int
	Active        bool // the window's active pane
	Dead          bool
	Command       string // pane_current_command
	Path          string // pane_current_path
	Title         string
	PID           int
	Width, Height int
	// Geometry in window cells. When the window is zoomed these come from the
	// unzoomed layout, so a layout map still shows every pane.
	Left, Top int
}

// Location is where a client currently is.
type Location struct {
	SessionID string
	WindowID  string
	PaneID    string
}
