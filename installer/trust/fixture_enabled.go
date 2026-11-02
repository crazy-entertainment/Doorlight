//go:build doorlight_fixture

package main

import (
	"crypto"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/sigstore/sigstore/pkg/signature"
	"github.com/theupdateframework/go-tuf/v2/metadata"
)

func fixtureHTTP() bool { return true }

// This command and loopback HTTP support do not exist in production builds.
// Keys never leave this function's memory. Outputs contain public metadata only.
func fixtureCommand(args []string) (bool, error) {
	if len(args) == 0 || args[0] != "fixture" {
		return false, nil
	}
	f := flag.NewFlagSet("fixture", flag.ContinueOnError)
	f.SetOutput(io.Discard)
	var policyFile, repo, manifestFile, packageFile, artifactBase string
	f.StringVar(&policyFile, "policy-file", "", "synthetic policy JSON")
	f.StringVar(&repo, "repository-dir", "", "new fixture repository")
	f.StringVar(&manifestFile, "manifest-file", "", "optional public fixture manifest")
	f.StringVar(&packageFile, "package-file", "", "optional public fixture package")
	f.StringVar(&artifactBase, "artifact-base-url", "", "artifact HTTP(S) base")
	if err := f.Parse(args[1:]); err != nil {
		return true, err
	}
	if f.NArg() != 0 || repo == "" || policyFile == "" {
		return true, errors.New("invalid fixture arguments")
	}
	if err := rejectLinks(repo); err != nil {
		return true, err
	}
	if _, err := os.Lstat(repo); !errors.Is(err, os.ErrNotExist) {
		return true, errors.New("fixture directory must be new")
	}
	policy, err := readBounded(policyFile, maxPolicy)
	if err != nil {
		return true, err
	}
	var value map[string]any
	if err = json.Unmarshal(policy, &value); err != nil || value == nil {
		return true, errors.New("invalid fixture policy")
	}
	if (manifestFile == "") != (packageFile == "") {
		return true, errors.New("both artifact inputs required")
	}
	if manifestFile != "" {
		if _, err = baseURL(artifactBase, true); err != nil {
			return true, err
		}
	}
	for _, dir := range []string{repo, filepath.Join(repo, "metadata"), filepath.Join(repo, "targets"), filepath.Join(repo, "artifacts")} {
		if err = os.MkdirAll(dir, 0700); err != nil {
			return true, err
		}
	}
	if manifestFile != "" {
		for _, input := range []struct{ field, path, name string }{{"manifest", manifestFile, "manifest.json"}, {"fullPackage", packageFile, "package.zip"}} {
			if input.field == "fullPackage" {
				if field, ok := value[input.field].(map[string]any); ok && field["format"] == "velopack" {
					input.name = "package.nupkg"
				}
			}
			length, hash, e := copyFixtureArtifact(input.path, filepath.Join(repo, "artifacts", input.name))
			if e != nil {
				return true, e
			}
			field, ok := value[input.field].(map[string]any)
			if !ok {
				return true, errors.New("missing fixture artifact descriptor")
			}
			field["url"] = artifactBase + "/" + input.name
			field["length"] = length
			field["sha256"] = hash
		}
		policy, err = json.Marshal(value)
		if err != nil {
			return true, err
		}
	}
	if int64(len(policy)) > maxPolicy {
		return true, errors.New("fixture policy too large")
	}
	expiry := time.Now().UTC().Add(24 * time.Hour)
	root := metadata.Root(expiry)
	root.Signed.ConsistentSnapshot = true
	keys := map[string]ed25519.PrivateKey{}
	for _, role := range []string{"root", "timestamp", "snapshot", "targets"} {
		_, key, e := ed25519.GenerateKey(nil)
		if e != nil {
			return true, e
		}
		keys[role] = key
		pub, e := metadata.KeyFromPublicKey(key.Public())
		if e != nil {
			return true, e
		}
		if e = root.Signed.AddKey(pub, role); e != nil {
			return true, e
		}
	}
	rootBytes, err := signFixture(root, keys["root"])
	if err != nil {
		return true, err
	}
	targets := metadata.Targets(expiry)
	info, err := metadata.TargetFile().FromBytes("rollout.json", policy, "sha256")
	if err != nil {
		return true, err
	}
	targets.Signed.Targets["rollout.json"] = info
	targetBytes, err := signFixture(targets, keys["targets"])
	if err != nil {
		return true, err
	}
	snapshot := metadata.Snapshot(expiry)
	snapshot.Signed.Meta["targets.json"] = metadata.MetaFile(1)
	snapshotBytes, err := signFixture(snapshot, keys["snapshot"])
	if err != nil {
		return true, err
	}
	ts := metadata.Timestamp(expiry)
	ts.Signed.Meta["snapshot.json"] = metadata.MetaFile(1)
	timestampBytes, err := signFixture(ts, keys["timestamp"])
	if err != nil {
		return true, err
	}
	h := sha256.Sum256(policy)
	outputs := map[string][]byte{
		"bootstrap.root.json":                                              rootBytes,
		filepath.Join("metadata", "1.root.json"):                           rootBytes,
		filepath.Join("metadata", "1.targets.json"):                        targetBytes,
		filepath.Join("metadata", "1.snapshot.json"):                       snapshotBytes,
		filepath.Join("metadata", "timestamp.json"):                        timestampBytes,
		filepath.Join("targets", hex.EncodeToString(h[:])+".rollout.json"): policy,
	}
	for name, b := range outputs {
		if err = writeNew(filepath.Join(repo, name), b); err != nil {
			return true, err
		}
	}
	return true, nil
}

func signFixture[T metadata.RootType | metadata.TimestampType | metadata.SnapshotType | metadata.TargetsType](m *metadata.Metadata[T], key ed25519.PrivateKey) ([]byte, error) {
	s, err := signature.LoadSigner(key, crypto.Hash(0))
	if err != nil {
		return nil, err
	}
	if _, err = m.Sign(s); err != nil {
		return nil, err
	}
	return m.ToBytes(false)
}
func copyFixtureArtifact(source, destination string) (int64, string, error) {
	if err := rejectLinks(source); err != nil {
		return 0, "", err
	}
	in, err := os.Open(source)
	if err != nil {
		return 0, "", err
	}
	defer in.Close()
	st, err := in.Stat()
	if err != nil {
		return 0, "", err
	}
	if !st.Mode().IsRegular() || st.Size() <= 0 || st.Size() > 2<<30 {
		return 0, "", errors.New("invalid fixture artifact")
	}
	out, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return 0, "", err
	}
	defer out.Close()
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(out, h), io.LimitReader(in, (2<<30)+1))
	if err != nil {
		return 0, "", err
	}
	if n != st.Size() {
		return 0, "", errors.New("fixture artifact changed")
	}
	if err = out.Sync(); err != nil {
		return 0, "", err
	}
	return n, hex.EncodeToString(h.Sum(nil)), nil
}
