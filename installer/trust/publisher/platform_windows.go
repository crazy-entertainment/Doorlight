package main

import (
	"errors"
	"golang.org/x/sys/windows"
	"path/filepath"
	"unsafe"
)

func rejectLinks(path string) error {
	p, e := filepath.Abs(path)
	if e != nil {
		return e
	}
	for {
		n, e := windows.UTF16PtrFromString(p)
		if e != nil {
			return e
		}
		a, e := windows.GetFileAttributes(n)
		if e == nil && a&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return invalid
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
func privateDirectory(path string) error {
	user, e := windows.GetCurrentProcessToken().GetTokenUser()
	if e != nil {
		return e
	}
	sd, e := windows.SecurityDescriptorFromString("D:P(A;OICI;FA;;;" + user.User.Sid.String() + ")(A;OICI;FA;;;SY)")
	if e != nil {
		return e
	}
	n, e := windows.UTF16PtrFromString(path)
	if e != nil {
		return e
	}
	return windows.CreateDirectory(n, &windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd})
}
