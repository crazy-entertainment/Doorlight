package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/url"
	"reflect"
	"regexp"
	"strconv"
	"strings"
)

type artifact struct {
	URL    string `json:"url"`
	Length int64  `json:"length"`
	SHA256 string `json:"sha256"`
}
type fullArtifact struct {
	URL    string `json:"url"`
	Length int64  `json:"length"`
	SHA256 string `json:"sha256"`
	Format string `json:"format"`
}
type delta struct {
	BaseVersion        string   `json:"baseVersion"`
	BasePackageSHA256  string   `json:"basePackageSha256"`
	BaseManifestSHA256 string   `json:"baseManifestSha256"`
	Patch              artifact `json:"patch"`
}
type widget struct {
	URL                   string `json:"url"`
	Version               string `json:"version"`
	PackageFamily         string `json:"packageFamily"`
	Publisher             string `json:"publisher"`
	MinimumDesktopVersion string `json:"minimumDesktopVersion"`
	MaximumProtocol       int    `json:"maximumProtocol"`
}
type policy struct {
	Schema                int          `json:"schema"`
	Product               string       `json:"product"`
	Channel               string       `json:"channel"`
	Platform              string       `json:"platform"`
	ReleaseSequence       int64        `json:"releaseSequence"`
	Version               string       `json:"version"`
	MinimumUpdaterVersion string       `json:"minimumUpdaterVersion"`
	Enabled               *bool        `json:"enabled"`
	RolloutBasisPoints    *int         `json:"rolloutBasisPoints"`
	Salt                  string       `json:"salt"`
	Manifest              artifact     `json:"manifest"`
	FullPackage           fullArtifact `json:"fullPackage"`
	Deltas                []delta      `json:"deltas"`
	Widget                *widget      `json:"widget"`
}

var channelPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
var versionPattern = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)

func text(s string, max int) bool {
	if strings.TrimSpace(s) == "" || len(s) > max {
		return false
	}
	for _, c := range s {
		if c < 32 || c == 127 {
			return false
		}
	}
	return true
}
func version(s string) bool {
	if !versionPattern.MatchString(s) {
		return false
	}
	for _, n := range strings.Split(s, ".") {
		if _, e := strconv.ParseInt(n, 10, 32); e != nil {
			return false
		}
	}
	return true
}
func safeURL(s string) bool {
	u, e := url.Parse(s)
	return e == nil && text(s, 2048) && u.Scheme == "https" && u.Hostname() != "" && u.User == nil && u.Fragment == "" && (u.Port() == "" || u.Port() == "443")
}
func validArtifact(a artifact, max int64) bool {
	return safeURL(a.URL) && a.Length > 0 && a.Length <= max && hashPattern.MatchString(a.SHA256)
}

// encoding/json otherwise silently accepts duplicate object fields.
func uniqueJSON(d *json.Decoder) error {
	token, e := d.Token()
	if e != nil {
		return e
	}
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := map[string]bool{}
		for d.More() {
			k, e := d.Token()
			if e != nil {
				return e
			}
			s, ok := k.(string)
			if !ok || seen[s] {
				return invalid
			}
			seen[s] = true
			if e = uniqueJSON(d); e != nil {
				return e
			}
		}
	case '[':
		for d.More() {
			if e = uniqueJSON(d); e != nil {
				return e
			}
		}
	default:
		return invalid
	}
	_, e = d.Token()
	return e
}
func parsePolicy(b []byte) (policy, error) {
	var p policy
	if len(b) > maxPolicy {
		return p, invalid
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	if uniqueJSON(d) != nil {
		return p, invalid
	}
	if _, e := d.Token(); e != io.EOF {
		return p, invalid
	}
	d = json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if d.Decode(&p) != nil {
		return p, invalid
	}
	if p.Schema != 1 || p.Product != "Doorlight" || !channelPattern.MatchString(p.Channel) || p.Platform != "windows-x64" || p.ReleaseSequence <= 0 || !version(p.Version) || !version(p.MinimumUpdaterVersion) || p.Enabled == nil || p.RolloutBasisPoints == nil || *p.RolloutBasisPoints < 0 || *p.RolloutBasisPoints > 10000 || !text(p.Salt, 128) || !validArtifact(p.Manifest, 8<<20) || !validArtifact(artifact{p.FullPackage.URL, p.FullPackage.Length, p.FullPackage.SHA256}, 2<<30) || (p.FullPackage.Format != "zip" && p.FullPackage.Format != "velopack") || len(p.Deltas) > 16 {
		return p, invalid
	}
	seen := map[string]bool{}
	for _, delta := range p.Deltas {
		if !version(delta.BaseVersion) || compareVersion(delta.BaseVersion, p.Version) >= 0 || seen[delta.BaseVersion] || !hashPattern.MatchString(delta.BasePackageSHA256) || !hashPattern.MatchString(delta.BaseManifestSHA256) || !validArtifact(delta.Patch, 2<<30) {
			return p, invalid
		}
		seen[delta.BaseVersion] = true
	}
	if p.FullPackage.Format == "zip" && len(p.Deltas) > 0 {
		return p, invalid
	}
	if w := p.Widget; w != nil {
		parts := strings.Split(w.Version, ".")
		if len(parts) != 4 {
			return p, invalid
		}
		for _, part := range parts {
			if _, e := strconv.ParseUint(part, 10, 16); e != nil {
				return p, invalid
			}
		}
		if !safeURL(w.URL) || !text(w.PackageFamily, 128) || !text(w.Publisher, 512) || !version(w.MinimumDesktopVersion) || w.MaximumProtocol < 1 || w.MaximumProtocol > 1024 {
			return p, invalid
		}
	}
	return p, nil
}
func compareVersion(a, b string) int {
	aa, bb := strings.Split(a, "."), strings.Split(b, ".")
	for i := range aa {
		x, _ := strconv.ParseInt(aa[i], 10, 32)
		y, _ := strconv.ParseInt(bb[i], 10, 32)
		if x < y {
			return -1
		}
		if x > y {
			return 1
		}
	}
	return 0
}
func samePolicy(a, b []byte) bool {
	pa, ea := parsePolicy(a)
	pb, eb := parsePolicy(b)
	return ea == nil && eb == nil && reflect.DeepEqual(pa, pb)
}
