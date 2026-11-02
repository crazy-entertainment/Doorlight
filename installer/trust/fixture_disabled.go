//go:build !doorlight_fixture

package main

func fixtureCommand([]string) (bool, error) { return false, nil }
func fixtureHTTP() bool                     { return false }
