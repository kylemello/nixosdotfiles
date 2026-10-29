package tmux

import (
	"strings"
	"testing"
)

func line(fields ...string) string { return strings.Join(fields, sep) + "\n" }

const jsonZoomed = `{"V":2,"L":{"t":"h","w":200,"h":50,"x":0,"y":0,"c":[{"t":"p","w":100,"h":50,"x":0,"y":0,"l":1,"i":0,"I":"%0"},{"t":"v","w":99,"h":50,"x":101,"y":0,"c":[{"t":"p","w":99,"h":25,"x":101,"y":0,"l":0,"i":1,"I":"%1"},{"t":"p","w":99,"h":24,"x":101,"y":26,"a":true,"i":2,"I":"%2"}]}]}}`

func TestParseTree(t *testing.T) {
	out := line("$1", "zeta", "0", "@5", "3", "w: x\ty", "1", "0", "L", "80", "24", "%9", "0", "1", "0", "nvim", "/tmp/a b", "t:i", "42", "80", "24", "0", "0") +
		line("$0", "alpha: 日本 ü", "2", "@2", "1", "two", "0", "1", jsonZoomed, "200", "50", "%2", "2", "1", "0", "sleep", "/x", "", "7", "200", "50", "0", "0") +
		line("$0", "alpha: 日本 ü", "2", "@2", "1", "two", "0", "1", jsonZoomed, "200", "50", "%0", "0", "0", "1", "sleep", "/x", "", "5", "100", "50", "0", "0") +
		line("$0", "alpha: 日本 ü", "2", "@1", "0", "one", "1", "0", "L", "200", "50", "%3", "0", "1", "0", "fish", "/", "", "9", "200", "50", "0", "0")
	got, err := parseTree(out)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Name != "alpha: 日本 ü" || got[1].Name != "zeta" {
		t.Fatalf("sessions not sorted by name: %+v", got)
	}
	a := got[0]
	if !a.Attached || got[1].Attached {
		t.Errorf("attached flags wrong")
	}
	if len(a.Windows) != 2 || a.Windows[0].ID != "@1" || a.Windows[1].ID != "@2" {
		t.Fatalf("windows not sorted by index: %+v", a.Windows)
	}
	w := a.Windows[1]
	if !w.Zoomed || w.Active || w.Layout != jsonZoomed || w.Width != 200 || w.Index != 1 || w.SessionID != "$0" {
		t.Errorf("window fields wrong: %+v", w)
	}
	if len(w.Panes) != 2 || w.Panes[0].ID != "%0" || w.Panes[1].ID != "%2" {
		t.Fatalf("panes not sorted by index: %+v", w.Panes)
	}
	if p := w.Panes[0]; !p.Dead || p.Active || p.PID != 5 || p.WindowID != "@2" || p.SessionID != "$0" {
		t.Errorf("pane fields wrong: %+v", p)
	}
	// Zoomed pane reported 200x50 at 0,0; the layout restores its real cell.
	if p := w.Panes[1]; p.Width != 99 || p.Height != 24 || p.Left != 101 || p.Top != 26 {
		t.Errorf("zoomed geometry not taken from layout: %+v", p)
	}
	z := got[1].Windows[0]
	if z.Name != "w: x\ty" || z.Panes[0].Path != "/tmp/a b" || z.Panes[0].Title != "t:i" || z.Panes[0].Command != "nvim" {
		t.Errorf("free text fields wrong: %+v", z)
	}
}

func TestParseTreeErrors(t *testing.T) {
	if _, err := parseTree("a" + sep + "b\n"); err == nil {
		t.Error("short line accepted")
	}
	bad := line("$0", "s", "x", "@1", "0", "w", "1", "0", "L", "1", "1", "%1", "0", "1", "0", "c", "/", "", "1", "1", "1", "0", "0")
	if _, err := parseTree(bad); err == nil {
		t.Error("non-numeric field accepted")
	}
	if got, err := parseTree(""); err != nil || len(got) != 0 {
		t.Errorf("empty output: %v %v", got, err)
	}
}

func TestLayoutGeometry(t *testing.T) {
	for _, tc := range []struct {
		name, layout string
		want         map[string]rect
	}{
		{"json", jsonZoomed, map[string]rect{
			"%0": {100, 50, 0, 0}, "%1": {99, 25, 101, 0}, "%2": {99, 24, 101, 26},
		}},
		{"json single", `{"V":2,"L":{"t":"p","w":200,"h":50,"x":0,"y":0,"a":true,"i":2,"I":"%2"}}`,
			map[string]rect{"%2": {200, 50, 0, 0}}},
		{"legacy single", "b25d,200x50,0,0,7", map[string]rect{"%7": {200, 50, 0, 0}}},
		{"legacy nested", "a1b2,200x50,0,0{100x50,0,0,0,99x50,101,0[99x25,101,0,1,99x24,101,26,12]}",
			map[string]rect{"%0": {100, 50, 0, 0}, "%1": {99, 25, 101, 0}, "%12": {99, 24, 101, 26}}},
		{"legacy deep", "0000,80x24,0,0[80x12,0,0{40x12,0,0,1,39x12,41,0,2},80x11,0,13,3]",
			map[string]rect{"%1": {40, 12, 0, 0}, "%2": {39, 12, 41, 0}, "%3": {80, 11, 0, 13}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := layoutGeometry(tc.layout)
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
			for k, v := range tc.want {
				if got[k] != v {
					t.Errorf("%s: got %v, want %v", k, got[k], v)
				}
			}
		})
	}
	for _, bad := range []string{"", "nochecksum", "a,200x50", "a,200x50,0,0{1x1,0,0,1", "a,1x1,0,0,1junk", "{not json", `{"V":2}`} {
		if _, err := layoutGeometry(bad); err == nil {
			t.Errorf("%q: expected error", bad)
		}
	}
}

func TestEscapeArg(t *testing.T) {
	for in, want := range map[string]string{
		"plain": "plain", "a;b": "a;b", "foo;": `foo\;`, ";": `\;`, cmdSep: ";",
	} {
		if got := escapeArg(in); got != want {
			t.Errorf("escapeArg(%q) = %q, want %q", in, got, want)
		}
	}
	if got := escapeFormat("a#S#{x}"); got != "a##S##{x}" {
		t.Errorf("escapeFormat = %q", got)
	}
}

func TestFloatingIn(t *testing.T) {
	l := `{"V":2,"L":{"t":"h","w":200,"h":50,"x":0,"y":0,"c":[{"t":"p","w":100,"h":50,"x":0,"y":0,"a":true,"i":0,"I":"%0"},{"t":"p","w":100,"h":12,"x":4,"y":2,"i":2,"z":0,"I":"%2"},{"t":"p","w":99,"h":50,"x":101,"y":0,"i":1,"I":"%1"}]}}`
	if got := floatingIn(l); len(got) != 1 || !got["%2"] {
		t.Errorf("floatingIn = %v", got)
	}
	if got := floatingIn("b25d,200x50,0,0,7"); len(got) != 0 {
		t.Errorf("legacy layout floating = %v", got)
	}
}
