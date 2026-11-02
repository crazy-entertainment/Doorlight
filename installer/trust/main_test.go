package main

import (
	"context"
	"crypto"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sigstore/sigstore/pkg/signature"
	"github.com/theupdateframework/go-tuf/v2/metadata"
)

// All private keys are generated in memory for each test. Only public metadata
// and synthetic policy bytes are written to the temporary fixture directories.
type repository struct {
	t      *testing.T
	mu     sync.RWMutex
	files  map[string][]byte
	keys   map[string]ed25519.PrivateKey
	root   *metadata.Metadata[metadata.RootType]
	server *httptest.Server
	o      options
}

func fixture(t *testing.T) *repository {
	t.Helper()
	r := &repository{t: t, files: map[string][]byte{}, keys: map[string]ed25519.PrivateKey{}}
	r.root = metadata.Root(time.Now().Add(time.Hour))
	for _, role := range []string{"root", "timestamp", "snapshot", "targets"} {
		_, key, err := ed25519.GenerateKey(nil)
		if err != nil {
			t.Fatal(err)
		}
		r.keys[role] = key
		pub, err := metadata.KeyFromPublicKey(key.Public())
		if err != nil {
			t.Fatal(err)
		}
		if err = r.root.Signed.AddKey(pub, role); err != nil {
			t.Fatal(err)
		}
	}
	r.root.Signed.ConsistentSnapshot = true
	rootBytes := sign(t, r.root, r.keys["root"])
	dir := t.TempDir()
	rootFile := filepath.Join(dir, "bootstrap.json")
	if err := os.WriteFile(rootFile, rootBytes, 0600); err != nil {
		t.Fatal(err)
	}
	r.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		r.mu.RLock()
		b, ok := r.files[req.URL.Path]
		r.mu.RUnlock()
		if !ok {
			http.NotFound(w, req)
			return
		}
		w.Write(b)
	}))
	t.Cleanup(r.server.Close)
	r.o = options{rootFile, r.server.URL + "/metadata", r.server.URL + "/policy", filepath.Join(dir, "state"), "rollout.json", filepath.Join(dir, "result.json")}
	r.publish(1, time.Now().Add(time.Hour), []byte(`{"schema":1,"sequence":1}`))
	return r
}

func sign[T metadata.RootType | metadata.TimestampType | metadata.SnapshotType | metadata.TargetsType](t *testing.T, m *metadata.Metadata[T], keys ...ed25519.PrivateKey) []byte {
	t.Helper()
	m.ClearSignatures()
	for _, key := range keys {
		s, e := signature.LoadSigner(key, crypto.Hash(0))
		if e != nil {
			t.Fatal(e)
		}
		if _, e = m.Sign(s); e != nil {
			t.Fatal(e)
		}
	}
	b, e := m.ToBytes(false)
	if e != nil {
		t.Fatal(e)
	}
	return b
}

func (r *repository) set(path string, b []byte) { r.mu.Lock(); defer r.mu.Unlock(); r.files[path] = b }
func (r *repository) publish(version int64, expiry time.Time, policy []byte) {
	targets := metadata.Targets(expiry)
	targets.Signed.Version = version
	info, err := metadata.TargetFile().FromBytes("rollout.json", policy, "sha256")
	if err != nil {
		r.t.Fatal(err)
	}
	targets.Signed.Targets["rollout.json"] = info
	b := sign(r.t, targets, r.keys["targets"])
	r.set(fmt.Sprintf("/metadata/%d.targets.json", version), b)
	snapshot := metadata.Snapshot(expiry)
	snapshot.Signed.Version = version
	snapshot.Signed.Meta["targets.json"] = metadata.MetaFile(version)
	b = sign(r.t, snapshot, r.keys["snapshot"])
	r.set(fmt.Sprintf("/metadata/%d.snapshot.json", version), b)
	ts := metadata.Timestamp(expiry)
	ts.Signed.Version = version
	ts.Signed.Meta["snapshot.json"] = metadata.MetaFile(version)
	r.set("/metadata/timestamp.json", sign(r.t, ts, r.keys["timestamp"]))
	h := sha256.Sum256(policy)
	r.set("/policy/"+hex.EncodeToString(h[:])+".rollout.json", policy)
}
func (r *repository) verify() (*result, error) { return verify(context.Background(), r.o, true) }

func TestVerifiedPolicyIndependentFlatAssetBases(t *testing.T) {
	r := fixture(t)
	got, err := r.verify()
	if err != nil {
		t.Fatal(err)
	}
	if got.Schema != 1 || got.RootVersion != 1 || got.TimestampVersion != 1 || got.TargetName != "rollout.json" || string(got.Target) != `{"schema":1,"sequence":1}` {
		t.Fatalf("unexpected result: %+v", got)
	}
	// Cached policy is still verified; metadata must refresh over the network.
	r.mu.Lock()
	for p := range r.files {
		if strings.HasPrefix(p, "/policy/") {
			delete(r.files, p)
		}
	}
	r.mu.Unlock()
	if _, err = r.verify(); err != nil {
		t.Fatal(err)
	}
	r.set("/metadata/timestamp.json", []byte("broken"))
	if _, err = r.verify(); err == nil {
		t.Fatal("accepted cached policy without current metadata")
	}
}

func TestBadSignatureRejected(t *testing.T) {
	r := fixture(t)
	ts := metadata.Timestamp(time.Now().Add(time.Hour))
	ts.Signed.Meta["snapshot.json"] = metadata.MetaFile(1)
	_, rogue, e := ed25519.GenerateKey(nil)
	if e != nil {
		t.Fatal(e)
	}
	r.set("/metadata/timestamp.json", sign(t, ts, rogue))
	if _, err := r.verify(); err == nil {
		t.Fatal("accepted rogue timestamp")
	}
}
func TestExpiredMetadataRejected(t *testing.T) {
	r := fixture(t)
	r.publish(1, time.Now().Add(-time.Second), []byte(`{}`))
	if _, err := r.verify(); err == nil {
		t.Fatal("accepted expired metadata")
	}
}
func TestReplayRejectedAcrossProcesses(t *testing.T) {
	r := fixture(t)
	r.publish(2, time.Now().Add(time.Hour), []byte(`{"sequence":2}`))
	if _, err := r.verify(); err != nil {
		t.Fatal(err)
	}
	r.publish(1, time.Now().Add(time.Hour), []byte(`{"sequence":1}`))
	if _, err := r.verify(); err == nil {
		t.Fatal("accepted replay against persisted metadata")
	}
}
func TestMissingTargetRejected(t *testing.T) {
	r := fixture(t)
	r.o.target = "absent.json"
	if _, err := r.verify(); err == nil {
		t.Fatal("accepted missing target")
	}
}
func TestCorruptPolicyRejected(t *testing.T) {
	r := fixture(t)
	r.mu.Lock()
	for p := range r.files {
		if strings.HasPrefix(p, "/policy/") {
			r.files[p] = []byte(`{"schema":9,"sequence":9}`)
		}
	}
	r.mu.Unlock()
	if _, err := r.verify(); err == nil {
		t.Fatal("accepted corrupt target")
	}
}
func TestRootRotationPersistsAndDoesNotResetToBootstrap(t *testing.T) {
	r := fixture(t)
	old := r.keys["root"]
	pub, err := metadata.KeyFromPublicKey(old.Public())
	if err != nil {
		t.Fatal(err)
	}
	id, err := pub.ID()
	if err != nil {
		t.Fatal(err)
	}
	if err = r.root.Signed.RevokeKey(id, "root"); err != nil {
		t.Fatal(err)
	}
	_, next, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	pub, err = metadata.KeyFromPublicKey(next.Public())
	if err != nil {
		t.Fatal(err)
	}
	if err = r.root.Signed.AddKey(pub, "root"); err != nil {
		t.Fatal(err)
	}
	r.root.Signed.Version = 2
	r.set("/metadata/2.root.json", sign(t, r.root, old, next))
	got, err := r.verify()
	if err != nil {
		t.Fatal(err)
	}
	if got.RootVersion != 2 {
		t.Fatal("rotation not accepted")
	}
	r.mu.Lock()
	delete(r.files, "/metadata/2.root.json")
	r.mu.Unlock()
	got, err = r.verify()
	if err != nil {
		t.Fatal(err)
	}
	if got.RootVersion != 2 {
		t.Fatal("root reset to bootstrap")
	}
}
func TestRootRotationRequiresOldAndNewSignatures(t *testing.T) {
	r := fixture(t)
	r.root.Signed.Version = 2
	_, rogue, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	r.set("/metadata/2.root.json", sign(t, r.root, rogue))
	if _, err = r.verify(); err == nil {
		t.Fatal("accepted untrusted root rotation")
	}
}
func TestCacheCorruptionFailsClosed(t *testing.T) {
	r := fixture(t)
	if _, err := r.verify(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(r.o.state, "metadata", "timestamp.json"), []byte("truncated"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := r.verify(); err == nil {
		t.Fatal("silently reset corrupt cache")
	}
}
func TestConcurrentStateUseRejected(t *testing.T) {
	r := fixture(t)
	if _, err := r.verify(); err != nil {
		t.Fatal(err)
	}
	unlock, err := lockState(filepath.Join(r.o.state, "trust.lock"))
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if _, err = r.verify(); err == nil {
		t.Fatal("allowed concurrent cache mutation")
	}
}
func TestProductionRejectsHTTPAndExistingOutput(t *testing.T) {
	r := fixture(t)
	if _, err := verify(context.Background(), r.o, false); err == nil {
		t.Fatal("production accepted HTTP")
	}
	if err := os.WriteFile(r.o.out, []byte("existing"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := r.verify(); err == nil {
		t.Fatal("allowed stale output")
	}
}
func TestFetcherBoundsAndTotalDeadline(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/large" {
			w.Write([]byte("123456789"))
			return
		}
		w.(http.Flusher).Flush()
		for i := 0; i < 20; i++ {
			select {
			case <-r.Context().Done():
				return
			case <-time.After(10 * time.Millisecond):
				w.Write([]byte(" "))
				w.(http.Flusher).Flush()
			}
		}
	}))
	defer s.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	f := newFetcher(ctx, s.URL, s.URL, true)
	if _, err := f.DownloadFile(s.URL+"/large", 4, 0); err == nil {
		t.Fatal("accepted oversized response")
	}
	if _, err := f.DownloadFile(s.URL+"/slow", 1000, 0); err == nil {
		t.Fatal("continuous bytes bypassed total deadline")
	}
}
func TestCLIResultSchemaSerialization(t *testing.T) {
	r := fixture(t)
	got, err := r.verify()
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	var v map[string]json.RawMessage
	if err = json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	if string(v["schema"]) != "1" || len(v["target"]) == 0 || len(v["expiresUtc"]) == 0 {
		t.Fatal("invalid C# result contract")
	}
}

func TestMissingPersistedRoleFailsClosed(t *testing.T) {
	for _, role := range []string{"root", "timestamp", "snapshot", "targets"} {
		t.Run(role, func(t *testing.T) {
			r := fixture(t)
			if _, err := r.verify(); err != nil {
				t.Fatal(err)
			}
			if err := os.Remove(filepath.Join(r.o.state, "metadata", role+".json")); err != nil {
				t.Fatal(err)
			}
			if _, err := r.verify(); err == nil {
				t.Fatal("reset missing persisted role")
			}
		})
	}
}

func TestPolicyBoundAndObjectContract(t *testing.T) {
	for _, policy := range [][]byte{[]byte(`[]`), []byte(`null`), []byte(`"string"`), []byte(strings.Repeat(" ", int(maxPolicy)) + `{}`)} {
		r := fixture(t)
		r.publish(1, time.Now().Add(time.Hour), policy)
		if _, err := r.verify(); err == nil {
			t.Fatal("accepted invalid policy object or size")
		}
	}
}

func TestUnsafeRedirectRejected(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://example.invalid/redirect", http.StatusFound)
	}))
	defer s.Close()
	f := newFetcher(context.Background(), s.URL, s.URL, true)
	if _, err := f.DownloadFile(s.URL+"/target", 100, 0); err == nil {
		t.Fatal("followed untrusted redirect")
	}
}

func TestExpiredCachedTimestampCannotReplay(t *testing.T) {
	r := fixture(t)
	r.publish(2, time.Now().Add(time.Hour), []byte(`{}`))
	if _, err := r.verify(); err != nil {
		t.Fatal(err)
	}
	// Simulate passage of time with a correctly signed expired cached timestamp,
	// then serve a lower version. The TUF client must retain its rollback floor.
	ts := metadata.Timestamp(time.Now().Add(-time.Hour))
	ts.Signed.Version = 2
	ts.Signed.Meta["snapshot.json"] = metadata.MetaFile(2)
	if err := os.WriteFile(filepath.Join(r.o.state, "metadata", "timestamp.json"), sign(t, ts, r.keys["timestamp"]), 0600); err != nil {
		t.Fatal(err)
	}
	r.publish(1, time.Now().Add(time.Hour), []byte(`{}`))
	if _, err := r.verify(); err == nil {
		t.Fatal("expiry reset rollback floor")
	}
}
