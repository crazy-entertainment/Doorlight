//go:build doorlight_fixture

package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestFixtureBuildProducesOnlyPublicRepository(t *testing.T) {
	d := t.TempDir()
	policy := filepath.Join(d, "input.json")
	repo := filepath.Join(d, "repository")
	if err := os.WriteFile(policy, []byte(`{"schema":1,"synthetic":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	handled, err := fixtureCommand([]string{"fixture", "--policy-file", policy, "--repository-dir", repo})
	if !handled || err != nil {
		t.Fatal("fixture build failed", err)
	}
	s := httptest.NewServer(http.FileServer(http.Dir(repo)))
	defer s.Close()
	o := options{filepath.Join(repo, "bootstrap.root.json"), s.URL + "/metadata", s.URL + "/targets", filepath.Join(d, "state"), "rollout.json", filepath.Join(d, "out.json")}
	r, err := verify(context.Background(), o, fixtureHTTP())
	if err != nil {
		t.Fatal(err)
	}
	if string(r.Target) != `{"schema":1,"synthetic":true}` {
		t.Fatal("fixture policy changed")
	}
	var files int
	err = filepath.WalkDir(repo, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.IsDir() {
			files++
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if files != 6 {
		t.Fatalf("unexpected repository files: %d", files)
	}
}
