package main

import (
	"errors"
	"flag"
	"fmt"
	"os"

	tea "charm.land/bubbletea/v2"

	"tpane/internal/tmux"
	"tpane/internal/ui"
)

var version = "dev"

var _ ui.Backend = (*tmux.Client)(nil)

func main() {
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: tpane [--version]\n\n"+
			"Manage tmux sessions, windows and panes: reorder, swap, break out, join.\n"+
			"Meant to run in a popup, e.g. bind P display-popup -E tpane\n")
	}
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "tpane:", err)
		os.Exit(1)
	}
}

func run() error {
	if os.Getenv("TMUX") == "" {
		return errors.New("not running inside tmux")
	}
	c := tmux.New()
	origin, err := c.Current()
	if err != nil {
		return err
	}
	_, err = tea.NewProgram(ui.New(c, ui.Options{Origin: origin})).Run()
	return err
}
