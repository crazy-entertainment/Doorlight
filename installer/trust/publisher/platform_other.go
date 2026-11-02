//go:build !windows

package main

import (
	"errors"
	"os"
	"path/filepath"
)

func rejectLinks(path string) error {
	p, e := filepath.Abs(path)
	if e != nil {
		return e
	}
	for {
		st, e := os.Lstat(p)
		if e == nil && st.Mode()&os.ModeSymlink != 0 {
			return invalid
		}
		if e != nil && !errors.Is(e, os.ErrNotExist) {
			return e
		}
		parent := filepath.Dir(p)
		if parent == p {
			return nil
		}
		p = parent
	}
}
func privateDirectory(path string) error { return os.Mkdir(path, 0700) }
