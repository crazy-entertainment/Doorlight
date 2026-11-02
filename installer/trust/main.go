package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/theupdateframework/go-tuf/v2/metadata"
	"github.com/theupdateframework/go-tuf/v2/metadata/config"
	"github.com/theupdateframework/go-tuf/v2/metadata/updater"
)

const maxMetadata int64 = 2 << 20
const maxPolicy int64 = 256 << 10

var flatName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$`)

type options struct{ root, metadataURL, targetsURL, state, target, out string }
type result struct {
	Schema           int             `json:"schema"`
	TargetName       string          `json:"targetName"`
	Length           int64           `json:"length"`
	SHA256           string          `json:"sha256"`
	Target           json.RawMessage `json:"target"`
	RootVersion      int64           `json:"rootVersion"`
	TimestampVersion int64           `json:"timestampVersion"`
	SnapshotVersion  int64           `json:"snapshotVersion"`
	TargetsVersion   int64           `json:"targetsVersion"`
	ExpiresUTC       time.Time       `json:"expiresUtc"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		// URLs and local paths can contain private deployment details.
		fmt.Fprintln(os.Stderr, "Doorlight trust verification failed.")
		os.Exit(1)
	}
}

func run(args []string) error {
	if handled, err := fixtureCommand(args); handled {
		return err
	}
	if len(args) == 0 || args[0] != "verify" {
		return errors.New("expected verify")
	}
	f := flag.NewFlagSet("verify", flag.ContinueOnError)
	f.SetOutput(io.Discard)
	var o options
	f.StringVar(&o.root, "root-file", "", "public bootstrap root")
	f.StringVar(&o.metadataURL, "metadata-url", "", "metadata base URL")
	f.StringVar(&o.targetsURL, "targets-url", "", "target base URL")
	f.StringVar(&o.state, "state-dir", "", "persistent private state directory")
	f.StringVar(&o.target, "target-name", "rollout.json", "flat target name")
	f.StringVar(&o.out, "out", "", "new result file")
	if err := f.Parse(args[1:]); err != nil {
		return err
	}
	if f.NArg() != 0 {
		return errors.New("unexpected argument")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	r, err := verify(ctx, o, fixtureHTTP())
	if err != nil {
		return err
	}
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return writeNew(o.out, data)
}

// Test HTTP is available only to in-process fixtures, never as a CLI option.
func verify(ctx context.Context, o options, testHTTP bool) (*result, error) {
	if o.root == "" || o.state == "" || o.out == "" || !flatName.MatchString(o.target) || strings.Contains(o.target, "..") {
		return nil, errors.New("invalid arguments")
	}
	for _, raw := range []string{o.metadataURL, o.targetsURL} {
		if _, err := baseURL(raw, testHTTP); err != nil {
			return nil, err
		}
	}
	if err := rejectLinks(o.root); err != nil {
		return nil, err
	}
	if err := rejectLinks(o.state); err != nil {
		return nil, err
	}
	if err := rejectLinks(o.out); err != nil {
		return nil, err
	}
	if _, err := os.Lstat(o.out); !errors.Is(err, os.ErrNotExist) {
		return nil, errors.New("output must not exist")
	}
	if err := os.MkdirAll(o.state, 0700); err != nil {
		return nil, err
	}
	unlock, err := lockState(filepath.Join(o.state, "trust.lock"))
	if err != nil {
		return nil, err
	}
	defer unlock()
	root, err := readBounded(o.root, maxMetadata)
	if err != nil {
		return nil, err
	}
	bootstrapHash := sha256.Sum256(root)
	anchor := filepath.Join(o.state, "bootstrap.sha256")
	if b, e := readBounded(anchor, 64); e == nil {
		if string(b) != hex.EncodeToString(bootstrapHash[:]) {
			return nil, errors.New("bootstrap changed")
		}
	} else if !errors.Is(e, os.ErrNotExist) {
		return nil, e
	} else {
		entries, e := os.ReadDir(o.state)
		if e != nil {
			return nil, e
		}
		if len(entries) != 1 || entries[0].Name() != "trust.lock" {
			return nil, errors.New("unanchored existing state")
		}
		if e = writeNew(anchor, []byte(hex.EncodeToString(bootstrapHash[:]))); e != nil {
			return nil, e
		}
	}
	md := filepath.Join(o.state, "metadata")
	cache := filepath.Join(o.state, "targets")
	completePath := filepath.Join(o.state, "complete")
	complete, completeErr := readBounded(completePath, 1)
	if completeErr != nil && !errors.Is(completeErr, os.ErrNotExist) {
		return nil, completeErr
	}
	if completeErr == nil && string(complete) != "1" {
		return nil, errors.New("invalid state marker")
	}
	// Never silently reset trusted state after corruption or an I/O failure.
	for _, dir := range []string{md, cache} {
		if err = rejectLinks(dir); err != nil {
			return nil, err
		}
		if err = os.MkdirAll(dir, 0700); err != nil {
			return nil, err
		}
	}
	for _, role := range []string{"root", "timestamp", "snapshot", "targets"} {
		p := filepath.Join(md, role+".json")
		b, e := readBounded(p, maxMetadata)
		if errors.Is(e, os.ErrNotExist) {
			if completeErr == nil {
				return nil, errors.New("trusted metadata missing")
			}
			continue
		}
		if e != nil {
			return nil, e
		}
		if !json.Valid(b) {
			return nil, errors.New("corrupt trusted metadata")
		}
		if role == "root" {
			root = b
		}
	}
	cfg, err := config.New(o.metadataURL, root)
	if err != nil {
		return nil, err
	}
	cfg.RemoteTargetsURL = o.targetsURL
	cfg.LocalMetadataDir, cfg.LocalTargetsDir = md, cache
	cfg.RootMaxLength, cfg.TimestampMaxLength = maxMetadata, 64<<10
	cfg.SnapshotMaxLength, cfg.TargetsMaxLength = maxMetadata, maxMetadata
	cfg.MaxRootRotations, cfg.MaxDelegations = 32, 0
	cfg.Fetcher = newFetcher(ctx, o.metadataURL, o.targetsURL, testHTTP)
	u, err := updater.New(cfg)
	if err != nil {
		return nil, err
	}
	if err = u.Refresh(); err != nil {
		return nil, err
	}
	// Only a top-level flat policy is supported: no delegated filesystem paths.
	info, ok := u.GetTopLevelTargets()[o.target]
	if !ok {
		return nil, errors.New("target missing")
	}
	if info.Length <= 0 || info.Length > maxPolicy || len(info.Hashes) != 1 || len(info.Hashes["sha256"]) != 32 {
		return nil, errors.New("unsupported policy target")
	}
	info, err = u.GetTargetInfo(o.target)
	if err != nil {
		return nil, err
	}
	policyPath := filepath.Join(cache, "policy.json")
	if err = rejectLinks(policyPath); err != nil {
		return nil, err
	}
	var data []byte
	if b, e := readBounded(policyPath, maxPolicy); e == nil && info.VerifyLengthHashes(b) == nil {
		data = b
	}
	if data == nil {
		_, data, err = u.DownloadTarget(info, policyPath, "")
		if err != nil {
			return nil, err
		}
	}
	var object map[string]json.RawMessage
	if err = json.Unmarshal(data, &object); err != nil || object == nil {
		return nil, errors.New("policy must be a JSON object")
	}
	t := u.GetTrustedMetadataSet()
	expires := t.Root.Signed.Expires
	for _, e := range []time.Time{t.Timestamp.Signed.Expires, t.Snapshot.Signed.Expires, t.Targets["targets"].Signed.Expires} {
		if e.Before(expires) {
			expires = e
		}
	}
	if !time.Now().Before(expires) {
		return nil, errors.New("metadata expired during verification")
	}
	for _, role := range []string{"root", "timestamp", "snapshot", "targets"} {
		if err = syncFile(filepath.Join(md, role+".json")); err != nil {
			return nil, err
		}
	}
	if errors.Is(completeErr, os.ErrNotExist) {
		if err = writeNew(completePath, []byte("1")); err != nil {
			return nil, err
		}
	}
	return &result{1, o.target, info.Length, hex.EncodeToString(info.Hashes["sha256"]), data,
		t.Root.Signed.Version, t.Timestamp.Signed.Version, t.Snapshot.Signed.Version,
		t.Targets["targets"].Signed.Version, expires.UTC()}, nil
}

type boundedFetcher struct {
	ctx      context.Context
	client   *http.Client
	bases    []*url.URL
	testHTTP bool
}

func newFetcher(ctx context.Context, md, targets string, testHTTP bool) *boundedFetcher {
	a, _ := baseURL(md, testHTTP)
	b, _ := baseURL(targets, testHTTP)
	f := &boundedFetcher{ctx: ctx, bases: []*url.URL{a, b}, testHTTP: testHTTP}
	f.client = &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 4 {
			return errors.New("redirect limit")
		}
		if !safeURL(req.URL, testHTTP) {
			return errors.New("unsafe redirect")
		}
		for _, base := range f.bases {
			if req.URL.Host == base.Host {
				return nil
			}
		}
		if via[0].URL.Hostname() == "github.com" && (req.URL.Hostname() == "release-assets.githubusercontent.com" || req.URL.Hostname() == "objects.githubusercontent.com") {
			return nil
		}
		return errors.New("untrusted redirect")
	}}
	return f
}

func (f *boundedFetcher) DownloadFile(raw string, limit int64, _ time.Duration) ([]byte, error) {
	u, err := url.Parse(raw)
	if err != nil || !safeURL(u, f.testHTTP) {
		return nil, errors.New("unsafe URL")
	}
	allowed := false
	for _, b := range f.bases {
		if u.Host == b.Host && strings.HasPrefix(u.Path, strings.TrimRight(b.Path, "/")+"/") {
			allowed = true
		}
	}
	if !allowed || limit <= 0 || limit > maxMetadata {
		return nil, errors.New("download outside bounds")
	}
	req, err := http.NewRequestWithContext(f.ctx, http.MethodGet, raw, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Doorlight-Trust/1")
	res, err := f.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, &metadata.ErrDownloadHTTP{StatusCode: res.StatusCode, URL: raw}
	}
	if res.ContentLength > limit {
		return nil, errors.New("download too large")
	}
	b, err := io.ReadAll(io.LimitReader(res.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, errors.New("download too large")
	}
	return b, nil
}

func safeURL(u *url.URL, testHTTP bool) bool {
	if u == nil || u.User != nil || u.Fragment != "" || u.Hostname() == "" {
		return false
	}
	if testHTTP && u.Scheme == "http" && u.Hostname() == "127.0.0.1" {
		return true
	}
	return u.Scheme == "https" && (u.Port() == "" || u.Port() == "443")
}
func baseURL(raw string, testHTTP bool) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || !safeURL(u, testHTTP) || u.RawQuery != "" || u.RawPath != "" {
		return nil, errors.New("invalid base URL")
	}
	return u, nil
}
func readBounded(path string, limit int64) ([]byte, error) {
	if err := rejectLinks(path); err != nil {
		return nil, err
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() || st.Size() > limit {
		return nil, errors.New("invalid local file")
	}
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if int64(len(b)) > limit {
		return nil, errors.New("local file too large")
	}
	return b, err
}
func writeNew(path string, data []byte) error {
	if err := rejectLinks(path); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, e := f.Write(data)
	if e == nil {
		e = f.Sync()
	}
	return errors.Join(e, f.Close())
}
func syncFile(path string) error {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	return errors.Join(f.Sync(), f.Close())
}
