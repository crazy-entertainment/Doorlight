package main

import (
	"fmt"
	"github.com/theupdateframework/go-tuf/v2/metadata"
	"github.com/theupdateframework/go-tuf/v2/metadata/config"
	"github.com/theupdateframework/go-tuf/v2/metadata/updater"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func must(t *testing.T, e error) {
	t.Helper()
	if e != nil {
		t.Fatal(e)
	}
}

type fixture struct {
	dir, keys, root, policy, feed string
	now                           time.Time
}

func setup(t *testing.T) fixture {
	t.Helper()
	d := t.TempDir()
	f := fixture{dir: d, keys: filepath.Join(d, "online"), root: filepath.Join(d, "public", "bootstrap.root.json"), policy: filepath.Join(d, "policy.json"), feed: filepath.Join(d, "feed"), now: time.Now().UTC()}
	custody := filepath.Join(d, "initial-custody")
	must(t, initialize(custody, filepath.Join(d, "public"), f.now))
	must(t, privateDirectory(f.keys))
	for _, role := range roles {
		b, e := bounded(filepath.Join(custody, role+".pem"), 16<<10)
		must(t, e)
		must(t, writeNew(filepath.Join(f.keys, role+".pem"), b))
	}
	must(t, writeNew(f.policy, policyBytes(1)))
	must(t, release(f.keys, f.root, f.policy, "", f.feed, 0, f.now))
	return f
}
func policyBytes(seq int) []byte {
	return []byte(fmt.Sprintf(`{"schema":1,"product":"Doorlight","channel":"stable","platform":"windows-x64","releaseSequence":%d,"version":"1.2.3","minimumUpdaterVersion":"1.0.0","enabled":true,"rolloutBasisPoints":10000,"salt":"synthetic","manifest":{"url":"https://example.invalid/manifest","length":1,"sha256":"%s"},"fullPackage":{"url":"https://example.invalid/package","length":1,"sha256":"%s","format":"zip"}}`, seq, strings.Repeat("0", 64), strings.Repeat("0", 64)))
}
func TestHTTPSUpdaterAndRefresh(t *testing.T) {
	f := setup(t)
	server := httptest.NewTLSServer(http.FileServer(http.Dir(f.feed)))
	defer server.Close()
	root, e := os.ReadFile(f.root)
	must(t, e)
	cfg, e := config.New(server.URL+"/", root)
	must(t, e)
	cfg.RemoteTargetsURL = server.URL + "/"
	cfg.LocalMetadataDir = filepath.Join(f.dir, "cache")
	cfg.LocalTargetsDir = filepath.Join(f.dir, "targets")
	must(t, cfg.SetDefaultFetcherHTTPClient(server.Client()))
	u, e := updater.New(cfg)
	must(t, e)
	must(t, u.Refresh())
	info, e := u.GetTargetInfo("rollout.json")
	must(t, e)
	_, _, e = u.DownloadTarget(info, "", "")
	must(t, e)
	next := filepath.Join(f.dir, "next")
	must(t, release(f.keys, f.root, f.policy, f.feed, next, 0, f.now.Add(time.Hour)))
	rb, e := os.ReadFile(f.root)
	must(t, e)
	r, e := metadata.Root().FromBytes(rb)
	must(t, e)
	state, e := previousFeed(r, rb, next)
	must(t, e)
	if state.targets != 2 || state.snapshot != 2 || state.timestamp != 2 {
		t.Fatal("versions did not advance")
	}
	entries, e := os.ReadDir(next)
	must(t, e)
	if len(entries) != 6 {
		t.Fatalf("expected six flat public assets; got %d", len(entries))
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".pem") {
			t.Fatal("private output")
		}
	}
}
func TestRejectTamperWrongKeysRollbackAndOverwrite(t *testing.T) {
	for _, name := range []string{"tamper", "wrong-key", "rollback", "version-rollback", "same-version-manifest", "same-version-package", "equivocation", "unsafe-url", "overwrite", "root-online", "overlap"} {
		t.Run(name, func(t *testing.T) {
			f := setup(t)
			out := filepath.Join(f.dir, "next")
			previous := f.feed
			switch name {
			case "version-rollback":
				must(t, os.WriteFile(f.policy, []byte(strings.Replace(string(policyBytes(2)), "1.2.3", "1.2.2", 1)), 0600))
			case "same-version-manifest":
				must(t, os.WriteFile(f.policy, []byte(strings.Replace(string(policyBytes(2)), "https://example.invalid/manifest", "https://example.invalid/other-manifest", 1)), 0600))
			case "same-version-package":
				must(t, os.WriteFile(f.policy, []byte(strings.Replace(string(policyBytes(2)), "https://example.invalid/package", "https://example.invalid/other-package", 1)), 0600))
			case "tamper":
				must(t, os.WriteFile(filepath.Join(f.feed, "1.targets.json"), []byte(`{}`), 0600))
			case "wrong-key":
				other := filepath.Join(f.dir, "other")
				must(t, initialize(other, filepath.Join(f.dir, "other-public"), f.now))
				b, e := os.ReadFile(filepath.Join(other, "targets.pem"))
				must(t, e)
				must(t, os.WriteFile(filepath.Join(f.keys, "targets.pem"), b, 0600))
			case "rollback":
				must(t, os.WriteFile(f.policy, policyBytes(2), 0600))
				second := filepath.Join(f.dir, "second")
				must(t, release(f.keys, f.root, f.policy, f.feed, second, 0, f.now))
				previous = second
				must(t, os.WriteFile(f.policy, policyBytes(1), 0600))
			case "equivocation":
				must(t, os.WriteFile(f.policy, []byte(strings.Replace(string(policyBytes(1)), "1.2.3", "1.2.4", 1)), 0600))
			case "unsafe-url":
				must(t, os.WriteFile(f.policy, []byte(strings.ReplaceAll(string(policyBytes(2)), "https://", "http://")), 0600))
			case "overwrite":
				out = f.feed
			case "root-online":
				must(t, writeNew(filepath.Join(f.keys, "root.pem"), []byte("not even a key")))
			case "overlap":
				out = filepath.Join(f.keys, "output")
			}
			if release(f.keys, f.root, f.policy, previous, out, 0, f.now) == nil {
				t.Fatal("unsafe release accepted")
			}
		})
	}
}
func TestExpiredPreviousAndCappedValidity(t *testing.T) {
	f := setup(t)
	next := filepath.Join(f.dir, "late")
	must(t, release(f.keys, f.root, f.policy, f.feed, next, 0, f.now.Add(100*24*time.Hour)))
	last := filepath.Join(f.dir, "last")
	must(t, release(f.keys, f.root, f.policy, next, last, 0, f.now.AddDate(4, 11, 0)))
	b, e := os.ReadFile(filepath.Join(last, "timestamp.json"))
	must(t, e)
	ts, e := metadata.Timestamp().FromBytes(b)
	must(t, e)
	rootBytes, e := os.ReadFile(f.root)
	must(t, e)
	root, e := metadata.Root().FromBytes(rootBytes)
	must(t, e)
	if ts.Signed.Expires.After(root.Signed.Expires) {
		t.Fatal("validity exceeds root")
	}
	if release(f.keys, f.root, f.policy, last, filepath.Join(f.dir, "expired"), 0, f.now.AddDate(6, 0, 0)) == nil {
		t.Fatal("expired root accepted")
	}
}

func TestSameVersionRolloutAndMinimumUpdaterEdits(t *testing.T) {
	f := setup(t)
	changed := strings.Replace(string(policyBytes(2)), `"enabled":true`, `"enabled":false`, 1)
	changed = strings.Replace(changed, `"minimumUpdaterVersion":"1.0.0"`, `"minimumUpdaterVersion":"1.1.0"`, 1)
	must(t, os.WriteFile(f.policy, []byte(changed), 0600))
	must(t, release(f.keys, f.root, f.policy, f.feed, filepath.Join(f.dir, "halt"), 0, f.now))
}

func TestOrphanVersionFloorWithExistingUpdater(t *testing.T) {
	f := setup(t)
	served := f.feed
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.FileServer(http.Dir(served)).ServeHTTP(w, r)
	}))
	defer server.Close()
	rootBytes, e := os.ReadFile(f.root)
	must(t, e)
	cfg, e := config.New(server.URL+"/", rootBytes)
	must(t, e)
	cfg.RemoteTargetsURL = server.URL + "/"
	cfg.LocalMetadataDir = filepath.Join(f.dir, "cache")
	cfg.LocalTargetsDir = filepath.Join(f.dir, "targets")
	must(t, cfg.SetDefaultFetcherHTTPClient(server.Client()))
	u, e := updater.New(cfg)
	must(t, e)
	must(t, u.Refresh())
	must(t, release(f.keys, f.root, f.policy, f.feed, filepath.Join(f.dir, "orphan"), 0, f.now))
	next := filepath.Join(f.dir, "recovered")
	must(t, release(f.keys, f.root, f.policy, f.feed, next, 2, f.now.Add(time.Hour)))
	root, e := metadata.Root().FromBytes(rootBytes)
	must(t, e)
	state, e := previousFeed(root, rootBytes, next)
	must(t, e)
	if state.targets != 3 || state.snapshot != 3 || state.timestamp != 3 {
		t.Fatal("orphan metadata version reused")
	}
	served = next
	u, e = updater.New(cfg)
	must(t, e)
	must(t, u.Refresh())
	info, e := u.GetTargetInfo("rollout.json")
	must(t, e)
	_, _, e = u.DownloadTarget(info, "", "")
	must(t, e)
	for _, floor := range []int64{-1, math.MaxInt64} {
		out := filepath.Join(f.dir, fmt.Sprintf("invalid-%d", floor))
		if release(f.keys, f.root, f.policy, f.feed, out, floor, f.now) == nil {
			t.Fatal("invalid metadata floor accepted")
		}
		if _, e := os.Stat(out); !os.IsNotExist(e) {
			t.Fatal("invalid floor wrote output")
		}
	}
}
func TestPolicyDuplicatesAndBounds(t *testing.T) {
	for _, b := range [][]byte{[]byte(strings.Replace(string(policyBytes(1)), `"schema":1`, `"schema":1,"schema":1`, 1)), []byte(strings.Replace(string(policyBytes(1)), `"enabled":true,`, "", 1)), []byte(strings.Repeat(" ", maxPolicy+1))} {
		if _, e := parsePolicy(b); e == nil {
			t.Fatal("malformed policy accepted")
		}
	}
}
func TestInitDoesNotOverwrite(t *testing.T) {
	d := t.TempDir()
	keys, out := filepath.Join(d, "keys"), filepath.Join(d, "public")
	must(t, initialize(keys, out, time.Now()))
	if initialize(keys, out, time.Now()) == nil {
		t.Fatal("overwrite accepted")
	}
	if initialize(filepath.Join(d, "new"), filepath.Join(d, "new", "public"), time.Now()) == nil {
		t.Fatal("overlapping custody accepted")
	}
}
