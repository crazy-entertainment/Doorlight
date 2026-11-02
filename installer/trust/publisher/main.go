// Doorlight's offline metadata signer. This executable has no network client.
package main

import (
	"crypto"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/sigstore/sigstore/pkg/signature"
	"github.com/theupdateframework/go-tuf/v2/metadata"
)

var invalid = errors.New("publisher validation failed")
var roles = []string{"targets", "snapshot", "timestamp"}

const maxPolicy = 256 << 10

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "publisher failed; inspect inputs and custody permissions")
		os.Exit(1)
	}
}
func run(args []string) error {
	if len(args) == 0 {
		return invalid
	}
	f := flag.NewFlagSet(args[0], flag.ContinueOnError)
	f.SetOutput(io.Discard)
	keys := f.String("keys-dir", "", "private key directory")
	out := f.String("output-dir", "", "new public directory")
	var root, policy, previous *string
	var floor *int64
	if args[0] == "release" {
		root = f.String("root-file", "", "public trust root")
		policy = f.String("policy-file", "", "policy JSON")
		previous = f.String("previous-dir", "", "authenticated previous public feed")
		floor = f.Int64("metadata-version-floor", 0, "reserve metadata versions through this number")
	} else if args[0] != "init" {
		return invalid
	}
	if f.Parse(args[1:]) != nil || f.NArg() != 0 || *keys == "" || *out == "" {
		return invalid
	}
	if args[0] == "init" {
		return initialize(*keys, *out, time.Now().UTC())
	}
	if *root == "" || *policy == "" {
		return invalid
	}
	return release(*keys, *root, *policy, *previous, *out, *floor, time.Now().UTC())
}
func sign[T metadata.RootType | metadata.TargetsType | metadata.SnapshotType | metadata.TimestampType](m *metadata.Metadata[T], key ed25519.PrivateKey) ([]byte, error) {
	signer, e := signature.LoadSigner(key, crypto.Hash(0))
	if e != nil {
		return nil, e
	}
	if _, e = m.Sign(signer); e != nil {
		return nil, e
	}
	return m.ToBytes(false)
}
func bounded(path string, maximum int64) ([]byte, error) {
	if e := rejectLinks(path); e != nil {
		return nil, e
	}
	f, e := os.Open(path)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	st, e := f.Stat()
	if e != nil || !st.Mode().IsRegular() || st.Size() > maximum {
		return nil, invalid
	}
	b, e := io.ReadAll(io.LimitReader(f, maximum+1))
	if e != nil || int64(len(b)) > maximum {
		return nil, invalid
	}
	return b, nil
}
func writeNew(path string, b []byte) error {
	if e := rejectLinks(path); e != nil {
		return e
	}
	f, e := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	if _, e = f.Write(b); e != nil {
		f.Close()
		return e
	}
	if e = f.Sync(); e != nil {
		f.Close()
		return e
	}
	return f.Close()
}
func fresh(path string) error {
	if path == "" {
		return invalid
	}
	if e := rejectLinks(path); e != nil {
		return e
	}
	_, e := os.Lstat(path)
	if !errors.Is(e, os.ErrNotExist) {
		return invalid
	}
	st, e := os.Stat(filepath.Dir(path))
	if e != nil || !st.IsDir() {
		return invalid
	}
	return nil
}
func disjoint(a, b string) bool {
	a, _ = filepath.Abs(a)
	b, _ = filepath.Abs(b)
	a = strings.ToLower(filepath.Clean(a))
	b = strings.ToLower(filepath.Clean(b))
	return a != b && !strings.HasPrefix(a, b+string(os.PathSeparator)) && !strings.HasPrefix(b, a+string(os.PathSeparator))
}
func initialize(keys, out string, now time.Time) error {
	if !disjoint(keys, out) {
		return invalid
	}
	if e := fresh(keys); e != nil {
		return e
	}
	if e := fresh(out); e != nil {
		return e
	}
	root := metadata.Root(now.AddDate(5, 0, 0))
	root.Signed.ConsistentSnapshot = true
	private := map[string]ed25519.PrivateKey{}
	for _, role := range append([]string{"root"}, roles...) {
		_, k, e := ed25519.GenerateKey(nil)
		if e != nil {
			return e
		}
		private[role] = k
		pub, e := metadata.KeyFromPublicKey(k.Public())
		if e != nil {
			return e
		}
		if e = root.Signed.AddKey(pub, role); e != nil {
			return e
		}
	}
	rb, e := sign(root, private["root"])
	if e != nil {
		return e
	}
	if e = privateDirectory(keys); e != nil {
		return e
	}
	for role, key := range private {
		der, e := x509.MarshalPKCS8PrivateKey(key)
		if e != nil {
			return e
		}
		if e = writeNew(filepath.Join(keys, role+".pem"), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})); e != nil {
			return e
		}
	}
	return output(out, map[string][]byte{"bootstrap.root.json": rb, "1.root.json": rb})
}
func output(dir string, files map[string][]byte) error {
	// A directory is not publishable until this command exits successfully. Never
	// overwrite or repair a partial invocation; retain it for operator inspection.
	if e := fresh(dir); e != nil {
		return e
	}
	if e := os.Mkdir(dir, 0700); e != nil {
		return e
	}
	for name, b := range files {
		if e := writeNew(filepath.Join(dir, name), b); e != nil {
			return e
		}
	}
	return nil
}
func readKey(dir, role string) (ed25519.PrivateKey, error) {
	b, e := bounded(filepath.Join(dir, role+".pem"), 16<<10)
	if e != nil {
		return nil, e
	}
	block, rest := pem.Decode(b)
	if block == nil || block.Type != "PRIVATE KEY" || len(strings.TrimSpace(string(rest))) != 0 {
		return nil, invalid
	}
	v, e := x509.ParsePKCS8PrivateKey(block.Bytes)
	if e != nil {
		return nil, invalid
	}
	key, ok := v.(ed25519.PrivateKey)
	if !ok {
		return nil, invalid
	}
	return key, nil
}
func link(version int64, b []byte) *metadata.MetaFiles {
	h := sha256.Sum256(b)
	m := metadata.MetaFile(version)
	m.Length = int64(len(b))
	m.Hashes = metadata.Hashes{"sha256": h[:]}
	return m
}
func validVersion(v int64) bool { return v > 0 && v < math.MaxInt64 }
func verifyLink(m *metadata.MetaFiles, b []byte) error {
	if m == nil || !validVersion(m.Version) || m.Length <= 0 || len(m.Hashes) != 1 || len(m.Hashes["sha256"]) != 32 {
		return invalid
	}
	return m.VerifyLengthHashes(b)
}
func expiry(now, root time.Time, days int) time.Time {
	e := now.Add(time.Duration(days) * 24 * time.Hour)
	if root.Before(e) {
		return root
	}
	return e
}
func release(keys, rootFile, policyFile, previous, out string, floor int64, now time.Time) error {
	if floor < 0 || floor == math.MaxInt64 {
		return invalid
	}
	for _, p := range []string{keys, rootFile, policyFile, previous} {
		if p != "" && !disjoint(p, out) {
			return invalid
		}
	}
	if e := fresh(out); e != nil {
		return e
	}
	rb, e := bounded(rootFile, 2<<20)
	if e != nil {
		return e
	}
	root, e := metadata.Root().FromBytes(rb)
	if e != nil {
		return invalid
	}
	if root.VerifyDelegate("root", root) != nil || !root.Signed.Expires.After(now) || root.Signed.Version != 1 || !root.Signed.ConsistentSnapshot {
		return invalid
	}
	entries, e := os.ReadDir(keys)
	if e != nil || len(entries) != 3 {
		return invalid
	}
	for _, entry := range entries {
		if entry.IsDir() {
			return invalid
		}
		found := false
		for _, role := range roles {
			if entry.Name() == role+".pem" {
				found = true
			}
		}
		if !found {
			return invalid
		}
	}
	private := map[string]ed25519.PrivateKey{}
	for _, role := range roles {
		k, e := readKey(keys, role)
		if e != nil {
			return e
		}
		private[role] = k
		probe := metadata.Targets(now.Add(time.Hour))
		if _, e = sign(probe, k); e != nil {
			return e
		}
		if root.VerifyDelegate(role, probe) != nil {
			return invalid
		}
	}
	policy, e := bounded(policyFile, maxPolicy)
	if e != nil {
		return e
	}
	p, e := parsePolicy(policy)
	if e != nil {
		return e
	}
	tv, sv, tsv := int64(1), int64(1), int64(1)
	if previous != "" {
		old, e := previousFeed(root, rb, previous)
		if e != nil {
			return e
		}
		if p.Product != old.policy.Product || p.Channel != old.policy.Channel || p.Platform != old.policy.Platform || p.ReleaseSequence < old.policy.ReleaseSequence {
			return invalid
		}
		if p.ReleaseSequence == old.policy.ReleaseSequence && !samePolicy(policy, old.bytes) {
			return invalid
		}
		if compareVersion(p.Version, old.policy.Version) < 0 {
			return invalid
		}
		if p.Version == old.policy.Version && (p.Manifest != old.policy.Manifest || p.FullPackage != old.policy.FullPackage) {
			return invalid
		}
		tv = old.targets + 1
		sv = old.snapshot + 1
		tsv = old.timestamp + 1
	}
	// Hosted filenames reserve numbers only; they never authenticate feed content.
	tv = max(tv, floor+1)
	sv = max(sv, floor+1)
	tsv = max(tsv, floor+1)
	targets := metadata.Targets(expiry(now, root.Signed.Expires, 90))
	targets.Signed.Version = tv
	info, e := metadata.TargetFile().FromBytes("rollout.json", policy, "sha256")
	if e != nil {
		return e
	}
	targets.Signed.Targets["rollout.json"] = info
	tb, e := sign(targets, private["targets"])
	if e != nil {
		return e
	}
	snapshot := metadata.Snapshot(expiry(now, root.Signed.Expires, 30))
	snapshot.Signed.Version = sv
	snapshot.Signed.Meta["targets.json"] = link(tv, tb)
	sb, e := sign(snapshot, private["snapshot"])
	if e != nil {
		return e
	}
	timestamp := metadata.Timestamp(expiry(now, root.Signed.Expires, 14))
	timestamp.Signed.Version = tsv
	timestamp.Signed.Meta["snapshot.json"] = link(sv, sb)
	tsb, e := sign(timestamp, private["timestamp"])
	if e != nil {
		return e
	}
	h := sha256.Sum256(policy)
	return output(out, map[string][]byte{"bootstrap.root.json": rb, "1.root.json": rb, fmt.Sprintf("%d.targets.json", tv): tb, fmt.Sprintf("%d.snapshot.json", sv): sb, "timestamp.json": tsb, hex.EncodeToString(h[:]) + ".rollout.json": policy})
}

type previousState struct {
	policy                       policy
	bytes                        []byte
	targets, snapshot, timestamp int64
}

func previousFeed(root *metadata.Metadata[metadata.RootType], rb []byte, dir string) (*previousState, error) {
	oldRoot, e := bounded(filepath.Join(dir, "1.root.json"), 2<<20)
	if e != nil || string(oldRoot) != string(rb) {
		return nil, invalid
	}
	tsb, e := bounded(filepath.Join(dir, "timestamp.json"), 64<<10)
	if e != nil {
		return nil, e
	}
	ts, e := metadata.Timestamp().FromBytes(tsb)
	if e != nil || root.VerifyDelegate("timestamp", ts) != nil || !validVersion(ts.Signed.Version) || len(ts.Signed.Meta) != 1 {
		return nil, invalid
	}
	sm := ts.Signed.Meta["snapshot.json"]
	if sm == nil || !validVersion(sm.Version) {
		return nil, invalid
	}
	sb, e := bounded(filepath.Join(dir, fmt.Sprintf("%d.snapshot.json", sm.Version)), 2<<20)
	if e != nil || verifyLink(sm, sb) != nil {
		return nil, invalid
	}
	s, e := metadata.Snapshot().FromBytes(sb)
	if e != nil || root.VerifyDelegate("snapshot", s) != nil || s.Signed.Version != sm.Version || len(s.Signed.Meta) != 1 {
		return nil, invalid
	}
	tm := s.Signed.Meta["targets.json"]
	if tm == nil || !validVersion(tm.Version) {
		return nil, invalid
	}
	tb, e := bounded(filepath.Join(dir, fmt.Sprintf("%d.targets.json", tm.Version)), 2<<20)
	if e != nil || verifyLink(tm, tb) != nil {
		return nil, invalid
	}
	t, e := metadata.Targets().FromBytes(tb)
	if e != nil || root.VerifyDelegate("targets", t) != nil || t.Signed.Version != tm.Version || len(t.Signed.Targets) != 1 || t.Signed.Delegations != nil {
		return nil, invalid
	}
	target := t.Signed.Targets["rollout.json"]
	if target == nil || target.Length <= 0 || target.Length > maxPolicy || len(target.Hashes) != 1 || len(target.Hashes["sha256"]) != 32 {
		return nil, invalid
	}
	b, e := bounded(filepath.Join(dir, hex.EncodeToString(target.Hashes["sha256"])+".rollout.json"), maxPolicy)
	if e != nil || target.VerifyLengthHashes(b) != nil {
		return nil, invalid
	}
	p, e := parsePolicy(b)
	if e != nil {
		return nil, e
	}
	return &previousState{p, b, t.Signed.Version, s.Signed.Version, ts.Signed.Version}, nil
}
