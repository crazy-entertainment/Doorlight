package main

import (
	"errors"
	"golang.org/x/sys/windows"
	"os"
	"path/filepath"
)

func rejectLinks(path string) error {
	p, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	for {
		name, e := windows.UTF16PtrFromString(p)
		if e != nil {
			return e
		}
		attrs, e := windows.GetFileAttributes(name)
		if e == nil && attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return errors.New("linked path")
		}
		if e != nil && !errors.Is(e, windows.ERROR_FILE_NOT_FOUND) && !errors.Is(e, windows.ERROR_PATH_NOT_FOUND) {
			return e
		}
		parent := filepath.Dir(p)
		if parent == p {
			return nil
		}
		p = parent
	}
}

func lockState(path string) (func(), error) {
	if err := rejectLinks(path); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	var overlapped windows.Overlapped
	err = windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlapped)
	if err != nil {
		f.Close()
		return nil, err
	}
	return func() { windows.UnlockFileEx(windows.Handle(f.Fd()), 0, 1, 0, &overlapped); f.Close() }, nil
}
