package tmux

import (
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
)

// sep separates fields in format output. tmux rejects control characters in
// session/window names and titles but not in paths or commands, so free-text
// fields go through clean() as well.
const sep = "\x1f"

func clean(v string) string { return "#{s/[\x01-\x1f\x7f]/?/:" + v + "}" }

var treeFields = []string{
	"#{session_id}", clean("session_name"), "#{session_attached}",
	"#{window_id}", "#{window_index}", clean("window_name"), "#{window_active}",
	"#{window_zoomed_flag}", "#{window_layout}", "#{window_width}", "#{window_height}",
	"#{pane_id}", "#{pane_index}", "#{pane_active}", "#{pane_dead}",
	clean("pane_current_command"), clean("pane_current_path"), clean("pane_title"),
	"#{pane_pid}", "#{pane_width}", "#{pane_height}", "#{pane_left}", "#{pane_top}",
}

var treeFormat = strings.Join(treeFields, sep)

func (c *Client) Tree() ([]Session, error) {
	out, err := c.run("list-panes", "-a", "-F", treeFormat)
	if err != nil {
		return nil, err
	}
	return parseTree(out)
}

func parseTree(out string) ([]Session, error) {
	var sessions []*Session
	sessByID := map[string]*Session{}
	type winKey struct{ s, w string }
	winByKey := map[winKey]*Window{}
	var winOrder []winKey

	for line := range strings.Lines(out) {
		line = strings.TrimRight(line, "\n")
		if line == "" {
			continue
		}
		f := strings.Split(line, sep)
		if len(f) != len(treeFields) {
			return nil, fmt.Errorf("list-panes: unexpected line %q", line)
		}
		var bad error
		num := func(i int) int {
			if f[i] == "" { // e.g. pane_pid of a dead pane
				return 0
			}
			n, err := strconv.Atoi(f[i])
			if err != nil && bad == nil {
				bad = fmt.Errorf("list-panes: field %d of %q: %w", i, line, err)
			}
			return n
		}

		s := sessByID[f[0]]
		if s == nil {
			s = &Session{ID: f[0], Name: unvis(f[1]), Attached: num(2) > 0}
			sessByID[f[0]] = s
			sessions = append(sessions, s)
		}
		k := winKey{f[0], f[3]}
		w := winByKey[k]
		if w == nil {
			w = &Window{
				ID: f[3], SessionID: f[0], Index: num(4), Name: unvis(f[5]),
				Active: f[6] == "1", Zoomed: f[7] == "1", Layout: f[8],
				Width: num(9), Height: num(10),
			}
			winByKey[k] = w
			winOrder = append(winOrder, k)
		}
		w.Panes = append(w.Panes, Pane{
			ID: f[11], WindowID: f[3], SessionID: f[0], Index: num(12),
			Active: f[13] == "1", Dead: f[14] == "1",
			Command: f[15], Path: f[16], Title: unvis(f[17]), PID: num(18),
			Width: num(19), Height: num(20), Left: num(21), Top: num(22),
		})
		if bad != nil {
			return nil, bad
		}
	}

	for _, k := range winOrder {
		w := winByKey[k]
		slices.SortStableFunc(w.Panes, func(a, b Pane) int { return cmp.Compare(a.Index, b.Index) })
		if w.Zoomed {
			// pane_* geometry describes the zoomed screen; the layout is the
			// saved unzoomed one.
			if geo, err := layoutGeometry(w.Layout); err == nil {
				for i := range w.Panes {
					if r, ok := geo[w.Panes[i].ID]; ok {
						p := &w.Panes[i]
						p.Width, p.Height, p.Left, p.Top = r.w, r.h, r.x, r.y
					}
				}
			}
		}
		s := sessByID[k.s]
		s.Windows = append(s.Windows, *w)
	}

	result := make([]Session, 0, len(sessions))
	for _, s := range sessions {
		slices.SortStableFunc(s.Windows, func(a, b Window) int { return cmp.Compare(a.Index, b.Index) })
		result = append(result, *s)
	}
	slices.SortStableFunc(result, func(a, b Session) int { return strings.Compare(a.Name, b.Name) })
	return result, nil
}

type rect struct{ w, h, x, y int }

// layoutGeometry returns each pane's cell from a window_layout string, keyed
// by pane id ("%3"). tmux 3.8 emits JSON; older versions emit
// "csum,WxH,X,Y{...}" with leaves "WxH,X,Y,N".
func layoutGeometry(layout string) (map[string]rect, error) {
	if strings.HasPrefix(layout, "{") {
		return jsonLayout(layout)
	}
	return legacyLayout(layout)
}

type jsonNode struct {
	T     string          `json:"t"`
	W     int             `json:"w"`
	H     int             `json:"h"`
	X     int             `json:"x"`
	Y     int             `json:"y"`
	C     []jsonNode      `json:"c"`
	ID    string          `json:"I"`
	Index json.RawMessage `json:"i"` // declared so "i" isn't matched case-insensitively to "I"
	Z     json.RawMessage `json:"z"` // present on floating panes
}

func jsonLayout(layout string) (map[string]rect, error) {
	var doc struct {
		L *jsonNode `json:"L"`
	}
	if err := json.Unmarshal([]byte(layout), &doc); err != nil {
		return nil, err
	}
	if doc.L == nil {
		return nil, errors.New("layout: missing root")
	}
	geo := map[string]rect{}
	var walk func(n *jsonNode)
	walk = func(n *jsonNode) {
		if len(n.C) == 0 {
			if n.ID != "" {
				geo[n.ID] = rect{n.W, n.H, n.X, n.Y}
			}
			return
		}
		for i := range n.C {
			walk(&n.C[i])
		}
	}
	walk(doc.L)
	return geo, nil
}

func legacyLayout(layout string) (map[string]rect, error) {
	_, body, ok := strings.Cut(layout, ",")
	if !ok {
		return nil, fmt.Errorf("layout: no checksum in %q", layout)
	}
	p := &layoutParser{s: body, geo: map[string]rect{}}
	if err := p.cell(); err != nil {
		return nil, err
	}
	if p.pos != len(p.s) {
		return nil, fmt.Errorf("layout: trailing data at %d in %q", p.pos, layout)
	}
	return p.geo, nil
}

type layoutParser struct {
	s   string
	pos int
	geo map[string]rect
}

func (p *layoutParser) num() (int, error) {
	start := p.pos
	for p.pos < len(p.s) && p.s[p.pos] >= '0' && p.s[p.pos] <= '9' {
		p.pos++
	}
	if start == p.pos {
		return 0, fmt.Errorf("layout: expected number at %d in %q", start, p.s)
	}
	return strconv.Atoi(p.s[start:p.pos])
}

func (p *layoutParser) expect(b byte) error {
	if p.pos >= len(p.s) || p.s[p.pos] != b {
		return fmt.Errorf("layout: expected %q at %d in %q", b, p.pos, p.s)
	}
	p.pos++
	return nil
}

func (p *layoutParser) cell() error {
	var r rect
	var err error
	if r.w, err = p.num(); err != nil {
		return err
	}
	if err = p.expect('x'); err != nil {
		return err
	}
	if r.h, err = p.num(); err != nil {
		return err
	}
	if err = p.expect(','); err != nil {
		return err
	}
	if r.x, err = p.num(); err != nil {
		return err
	}
	if err = p.expect(','); err != nil {
		return err
	}
	if r.y, err = p.num(); err != nil {
		return err
	}
	if p.pos < len(p.s) && (p.s[p.pos] == '{' || p.s[p.pos] == '[') {
		closer := byte('}')
		if p.s[p.pos] == '[' {
			closer = ']'
		}
		p.pos++
		for {
			if err := p.cell(); err != nil {
				return err
			}
			if p.pos < len(p.s) && p.s[p.pos] == ',' {
				p.pos++
				continue
			}
			return p.expect(closer)
		}
	}
	if err = p.expect(','); err != nil {
		return err
	}
	id, err := p.num()
	if err != nil {
		return err
	}
	p.geo["%"+strconv.Itoa(id)] = r
	return nil
}

// unvis undoes tmux's vis-encoding of names and titles. Control characters
// are rejected there, so the only escape left is "\\" for a backslash.
func unvis(s string) string { return strings.ReplaceAll(s, `\\`, `\`) }

// floatingIn returns the floating panes of a JSON window_layout. Unlike
// pane_floating_flag, which reads 0 for every pane while the window is
// zoomed, the layout keeps marking them.
func floatingIn(layout string) map[string]bool {
	var doc struct {
		L *jsonNode `json:"L"`
	}
	if !strings.HasPrefix(layout, "{") || json.Unmarshal([]byte(layout), &doc) != nil || doc.L == nil {
		return nil
	}
	fl := map[string]bool{}
	var walk func(n *jsonNode)
	walk = func(n *jsonNode) {
		if len(n.C) == 0 && n.Z != nil && n.ID != "" {
			fl[n.ID] = true
		}
		for i := range n.C {
			walk(&n.C[i])
		}
	}
	walk(doc.L)
	return fl
}
