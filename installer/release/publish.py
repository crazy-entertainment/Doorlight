"""Publish qualified Windows artifacts, then advance the signed update feed.

Only the publication process receives the three online TUF keys. No root key is
accepted, and no credential is written to a public output directory.
"""
import argparse
from datetime import date, datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from urllib.error import HTTPError
from urllib.parse import quote, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener, urlopen

REPOSITORY = "crazy-entertainment/Doorlight"
HASH = re.compile(r"[0-9a-f]{64}\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")
FLAT = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\Z")
ROLE_KEYS = {role: "DOORLIGHT_TUF_" + role.upper() + "_KEY"
             for role in ("targets", "snapshot", "timestamp")}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON field.")
        result[key] = value
    return result


def decode(data):
    return json.loads(data, object_pairs_hook=unique_object)


def read_json(path, limit=2 << 20):
    require(path.is_file() and path.stat().st_size <= limit, "Invalid JSON input.")
    return decode(path.read_bytes())


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def https(url):
    value = urlparse(url or "")
    return (value.scheme == "https" and value.hostname and not value.username
            and not value.password and not value.fragment
            and value.port in (None, 443))


def review_date(value):
    try:
        return (isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", value)
                and date.fromisoformat(value) <= datetime.now(timezone.utc).date())
    except ValueError:
        return False


def config_read(path, root):
    config = read_json(path)
    require(config.get("schema") == 1 and config.get("repository") == REPOSITORY,
            "Wrong release configuration.")
    require(config.get("deliveryEnabled") is True,
            "Automatic delivery is disabled pending release qualification.")
    require(re.fullmatch(r"[a-z][a-z0-9-]{0,31}", config.get("channel", "")),
            "Invalid channel.")
    require(config.get("feedTag") == "update-feed", "Unexpected feed location.")
    require(root.is_file() and HASH.fullmatch(config.get("rootSha256") or "")
            and digest(root) == config["rootSha256"], "Bootstrap root mismatch.")
    native = config.get("nativeInputs", {})
    require(SHA.fullmatch(native.get("daemonSourceTree") or ""), "Native source tree identity is missing.")
    for stem in ("archive", "manifest", "correspondingSource"):
        require(https(native.get(stem + "Url"))
                and HASH.fullmatch(native.get(stem + "Sha256") or ""),
                "Qualified native inputs and corresponding source are required.")
    review = config.get("qualification") or {}
    require(isinstance(review.get("reviewer"), str) and bool(review["reviewer"].strip()) and review_date(review.get("date"))
            and https(review.get("evidenceUrl"))
            and review.get("nativeInputsSha256") == native["archiveSha256"]
            and review.get("correspondingSourceSha256") == native["correspondingSourceSha256"],
            "Release qualification is missing or belongs to different native inputs.")
    return config


def candidate_read(directory, commit, run_number, attempt, config):
    require(SHA.fullmatch(commit or "") and 0 < run_number <= 65535 and 0 < attempt <= 65535,
            "Invalid workflow revision or version.")
    version = f"1.{run_number}.{attempt}"
    receipt = read_json(directory / "build-receipt.json")
    require(receipt.get("schema") == 1 and receipt.get("commit") == commit
            and receipt.get("version") == version
            and receipt.get("releaseSequence") == run_number * 65536 + attempt
            and receipt.get("daemonSourceTree") == config["nativeInputs"]["daemonSourceTree"]
            and receipt.get("nativeInputsSha256") == config["nativeInputs"]["archiveSha256"]
            and receipt.get("correspondingSourceUrl") == config["nativeInputs"]["correspondingSourceUrl"]
            and receipt.get("correspondingSourceSha256") == config["nativeInputs"]["correspondingSourceSha256"],
            "Build receipt does not match this workflow or native inputs.")
    names = {"Doorlight.Package.json", "Doorlight.Package.zip", "Doorlight.Source.tar.gz", "Doorlight-Setup.exe",
             f"Doorlight-{version}-Setup.exe", f"Doorlight-{version}-Online-Setup.exe"}
    entries = receipt.get("files")
    require(isinstance(entries, list) and len(entries) == len(names), "Invalid build receipt file set.")
    files = {}
    for item in entries:
        name = item.get("name", "")
        require(name in names and name not in files, "Unexpected or duplicate release artifact.")
        path = directory / name
        require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= 2 << 30
                and path.stat().st_size == item.get("length") and digest(path) == item.get("sha256"),
                "Release artifact changed after qualification.")
        files[name] = path
    alias = files["Doorlight-Setup.exe"]
    offline = files[f"Doorlight-{version}-Setup.exe"]
    require(alias.stat().st_size == offline.stat().st_size and digest(alias) == digest(offline),
            "Stable offline installer alias differs from the versioned installer.")
    require(read_json(files["Doorlight.Package.json"], 8 << 20).get("Version") == version,
            "Package manifest version mismatch.")
    return receipt, files


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Authenticated GitHub request unexpectedly redirected.")


class GitHub:
    def __init__(self, token):
        require(bool(token), "GitHub publication token is unavailable.")
        self.token = token
        self.transport = build_opener(NoRedirect())

    def request(self, method, route, value=None, upload=None):
        origin = "https://uploads.github.com" if upload else "https://api.github.com"
        headers = {"Accept": "application/vnd.github+json", "Authorization": "Bearer " + self.token,
                   "User-Agent": "Doorlight-release", "X-GitHub-Api-Version": "2022-11-28"}
        data = None
        if value is not None:
            data = json.dumps(value).encode()
            headers["Content-Type"] = "application/json"
        if upload:
            headers["Content-Type"] = "application/octet-stream"
            headers["Content-Length"] = str(upload.stat().st_size)
            data = upload.open("rb")
        try:
            request = Request(origin + "/repos/" + REPOSITORY + route, data=data, headers=headers, method=method)
            with self.transport.open(request, timeout=300 if upload else 60) as response:
                body = response.read(8 << 20)
            return decode(body) if body else None
        finally:
            if upload:
                data.close()

    def release(self, tag):
        try:
            return self.request("GET", "/releases/tags/" + quote(tag, safe=""))
        except HTTPError as error:
            if error.code == 404:
                return None
            raise

    def assets(self, release):
        result = {}
        for page in range(1, 1001):
            values = self.request("GET", f"/releases/{release['id']}/assets?per_page=100&page={page}")
            for value in values:
                require(value["name"] not in result, "Duplicate hosted asset name.")
                result[value["name"]] = value
            if len(values) < 100:
                return result
        raise ValueError("Update feed asset listing exceeded its bound.")

    def create(self, tag, commit, body):
        return self.request("POST", "/releases", {"tag_name": tag, "target_commitish": commit,
                            "name": tag, "body": body, "draft": True, "make_latest": "false"})

    def upload(self, release, path, name=None):
        return self.request("POST", f"/releases/{release['id']}/assets?name={quote(name or path.name, safe='')}", upload=path)

    def public(self, release, latest=False):
        return self.request("PATCH", f"/releases/{release['id']}",
                            {"draft": False, "make_latest": "true" if latest else "false"})


def download(url, path, maximum=2 << 20, timeout=60):
    require(https(url), "Unsafe public download URL.")
    with urlopen(Request(url, headers={"User-Agent": "Doorlight-release"}), timeout=timeout) as response:
        require(https(response.url), "Unsafe public download redirect.")
        with path.open("xb") as output:
            total = 0
            while chunk := response.read(1 << 20):
                total += len(chunk)
                require(total <= maximum, "Hosted input exceeded its size bound.")
                output.write(chunk)


def asset_matches(asset, path):
    # GitHub's authenticated asset digest avoids downloading multi-GB packages.
    return (asset.get("state") == "uploaded" and asset.get("size") == path.stat().st_size
            and asset.get("digest") == "sha256:" + digest(path))


def verify_public_timestamp(url, expected, scratch):
    # The canonical release URL can briefly retain its previous asset redirect.
    # Wait for that same URL; a cache-busting URL would not verify client access.
    expected_digest = digest(expected)
    deadline = time.monotonic() + 300
    attempt = 0
    while True:
        remaining = deadline - time.monotonic()
        require(remaining > 0, "Public timestamp readback did not match within the propagation budget.")
        attempt += 1
        hosted = scratch / f"hosted-timestamp-{attempt}.json"
        try:
            download(url, hosted, timeout=min(60, remaining))
            if digest(hosted) == expected_digest:
                return
        except HTTPError as error:
            if error.code != 404:
                raise
        if attempt == 1:
            print("Waiting for the canonical public timestamp to propagate.", flush=True)
        time.sleep(min(5, max(0, deadline - time.monotonic())))


def immutable_upload(github, release, path, assets):
    existing = assets.get(path.name)
    if existing:
        require(asset_matches(existing, path), "Immutable release asset differs; refusing overwrite.")
        return existing
    uploaded = github.upload(release, path)
    require(asset_matches(uploaded, path), "GitHub did not confirm the uploaded artifact digest.")
    assets[path.name] = uploaded
    return uploaded


def previous_download(github, release, directory, root):
    directory.mkdir()
    assets = github.assets(release)
    require("timestamp.json" in assets, "Published feed has no timestamp; recovery is required.")
    # Signature and linkage validation belong to the offline publisher, not JSON parsing here.
    download(assets["timestamp.json"]["browser_download_url"], directory / "timestamp.json")
    timestamp_digest = digest(directory / "timestamp.json")
    ts = read_json(directory / "timestamp.json")
    version = ts["signed"]["meta"]["snapshot.json"]["version"]
    require(type(version) is int and version > 0, "Invalid hosted snapshot reference.")
    name = f"{version}.snapshot.json"
    require(name in assets, "Hosted snapshot is missing.")
    download(assets[name]["browser_download_url"], directory / name)
    snapshot = read_json(directory / name)
    version = snapshot["signed"]["meta"]["targets.json"]["version"]
    require(type(version) is int and version > 0, "Invalid hosted targets reference.")
    name = f"{version}.targets.json"
    require(name in assets, "Hosted targets are missing.")
    download(assets[name]["browser_download_url"], directory / name)
    targets = read_json(directory / name)
    sha = targets["signed"]["targets"]["rollout.json"]["hashes"]["sha256"]
    require(HASH.fullmatch(sha), "Invalid hosted policy reference.")
    name = sha + ".rollout.json"
    require(name in assets, "Hosted rollout policy is missing.")
    download(assets[name]["browser_download_url"], directory / name, 256 << 10)
    require("1.root.json" in assets, "Hosted root is missing.")
    download(assets["1.root.json"]["browser_download_url"], directory / "1.root.json")
    require(digest(directory / "1.root.json") == digest(root), "Hosted root changed unexpectedly.")
    shutil.copyfile(root, directory / "bootstrap.root.json")
    return timestamp_digest, read_json(directory / name)


def private_keys(directory):
    directory.mkdir(mode=0o700)
    if os.name == "nt":
        user = subprocess.run(["whoami"], check=True, capture_output=True, text=True).stdout.strip()
        subprocess.run(["icacls", str(directory), "/inheritance:r", "/grant:r",
                        user + ":(OI)(CI)F", "*S-1-5-18:(OI)(CI)F"], check=True, capture_output=True)
    for role, environment in ROLE_KEYS.items():
        value = os.environ.get(environment, "")
        require(value.startswith("-----BEGIN PRIVATE KEY-----") and len(value) < 16384,
                "An online update signing key is unavailable.")
        with (directory / (role + ".pem")).open("x", encoding="ascii", newline="\n") as stream:
            stream.write(value.rstrip() + "\n")


def timestamp_commit(github, release, path, previous_digest, scratch):
    staged_name = "timestamp-next-" + digest(path) + ".json"
    staged = github.upload(release, path, staged_name)
    require(asset_matches(staged, path), "Staged timestamp upload was not verified.")
    current = github.assets(release).get("timestamp.json")
    expected = "sha256:" + previous_digest if previous_digest else None
    require((current.get("digest") if current else None) == expected,
            "Published timestamp changed during this release; refusing lost update.")
    if current:
        github.request("DELETE", f"/releases/assets/{current['id']}")
    try:
        github.request("PATCH", f"/releases/assets/{staged['id']}", {"name": "timestamp.json"})
    except Exception:
        # GitHub has no atomic asset replacement. Restore the authenticated old head
        # if promotion failed and another publisher has not already supplied one.
        old = scratch / "previous" / "timestamp.json"
        if current and old.is_file() and "timestamp.json" not in github.assets(release):
            github.upload(release, old)
        raise


def publish(args):
    require(args.repository == REPOSITORY and SHA.fullmatch(args.commit), "Unexpected release repository or commit.")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        require(os.environ.get("GITHUB_REF") == "refs/heads/main"
                and os.environ.get("GITHUB_REPOSITORY") == REPOSITORY,
                "Only this repository's main branch may publish updates.")
    root = Path(args.root)
    config = config_read(Path(args.config), root)
    scratch = Path(args.scratch)
    require(not scratch.exists(), "Publication scratch directory must be fresh.")
    scratch.mkdir(parents=True)
    github = GitHub(os.environ.get("GITHUB_TOKEN"))
    feed = github.release(config["feedTag"])
    require(not feed or not feed.get("immutable"), "Update metadata requires a mutable feed release.")
    # A failed run may have uploaded a signed generation without promoting its
    # timestamp. Reserve numbers above those assets; never overwrite their bytes.
    metadata_floor = max((int(match[1]) for name in (github.assets(feed) if feed else {})
                          if (match := re.fullmatch(r"([1-9][0-9]*)\.(targets|snapshot)\.json", name))), default=0)
    require(metadata_floor < (1 << 63) - 1, "Hosted metadata version space is exhausted.")
    previous_digest, previous_policy = None, None
    if feed and not feed.get("draft"):
        previous_digest, previous_policy = previous_download(github, feed, scratch / "previous", root)
    elif args.refresh:
        raise ValueError("Cannot refresh a feed that has never been published.")
    else:
        require(not feed, "An unfinished draft feed requires explicit recovery.")
    if args.refresh:
        policy = previous_policy
        files, receipt = {}, None
    else:
        require(args.candidate, "Candidate artifacts are required.")
        source_tree = subprocess.run(["git", "rev-parse", args.commit + ":native/jami"],
                                     check=True, capture_output=True, text=True).stdout.strip()
        require(source_tree == config["nativeInputs"]["daemonSourceTree"],
                "Candidate daemon source differs from qualified native inputs.")
        receipt, files = candidate_read(Path(args.candidate), args.commit, args.run_number, args.attempt, config)
        version = receipt["version"]
        base = f"https://github.com/{REPOSITORY}/releases/download/windows-v{version}/"
        def artifact(name):
            return {"url": base + quote(name), "length": files[name].stat().st_size, "sha256": digest(files[name])}
        policy = {"schema": 1, "product": "Doorlight", "channel": config["channel"], "platform": "windows-x64",
                  "releaseSequence": receipt["releaseSequence"], "version": version, "minimumUpdaterVersion": "1.0.0",
                  "enabled": True, "rolloutBasisPoints": 10000, "salt": "doorlight-stable-v1",
                  "manifest": artifact("Doorlight.Package.json"),
                  "fullPackage": {**artifact("Doorlight.Package.zip"), "format": "zip"}, "deltas": [], "widget": None}
    policy_file = scratch / "policy.json"
    policy_file.write_text(json.dumps(policy), encoding="utf-8")
    keys = scratch / "online-keys"
    try:
        private_keys(keys)
        command = [args.publisher, "release", "--keys-dir", str(keys), "--root-file", str(root.resolve()),
                   "--policy-file", str(policy_file), "--output-dir", str(scratch / "feed"),
                   "--metadata-version-floor", str(metadata_floor)]
        if previous_digest:
            command += ["--previous-dir", str(scratch / "previous")]
        subprocess.run(command, check=True, capture_output=True)
    finally:
        if keys.is_dir():
            for key in keys.iterdir():
                key.unlink()
            keys.rmdir()
    # No provider writes occur until offline signature/policy/previous-head validation succeeds.
    if files:
        tag = "windows-v" + receipt["version"]
        app_release = github.release(tag)
        require(not app_release or app_release.get("target_commitish") == args.commit,
                "Version tag belongs to another source revision.")
        if not app_release:
            body = (f"Doorlight Windows {receipt['version']}\n\n"
                    "Unsigned Windows test build. Signing and broader release qualification are pending.\n\n"
                    f"Built from {args.commit}.\n\n"
                    "Application source: Doorlight.Source.tar.gz in this release.\n"
                    "Native corresponding source: " + config["nativeInputs"]["correspondingSourceUrl"]
                    + "\n\nThe Game Bar widget is serviced separately.")
            app_release = github.create(tag, args.commit, body)
        assets = github.assets(app_release)
        for path in files.values():
            immutable_upload(github, app_release, path, assets)
        immutable_upload(github, app_release, Path(args.candidate) / "build-receipt.json", assets)
        if app_release.get("draft"):
            github.public(app_release, latest=True)
    if not feed:
        feed = github.create(config["feedTag"], args.commit, "Signed Doorlight update metadata. Retain all versioned assets.")
    assets = github.assets(feed)
    for path in sorted((scratch / "feed").iterdir()):
        require(FLAT.fullmatch(path.name), "Unexpected publisher output filename.")
        if path.name != "timestamp.json":
            immutable_upload(github, feed, path, assets)
    timestamp_commit(github, feed, scratch / "feed" / "timestamp.json", previous_digest, scratch)
    if feed.get("draft"):
        github.public(feed)
    # Read the public head back without a token; do not equate an API upload with client reachability.
    verify_public_timestamp(f"https://github.com/{REPOSITORY}/releases/download/{config['feedTag']}/timestamp.json",
                            scratch / "feed" / "timestamp.json", scratch)
    print("Signed update feed published and public timestamp verified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("config", "root", "publisher", "repository", "commit", "scratch"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--candidate")
    parser.add_argument("--run-number", type=int, default=0)
    parser.add_argument("--attempt", type=int, default=0)
    parser.add_argument("--refresh", action="store_true")
    try:
        publish(parser.parse_args())
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print("Release publication failed. Preserve the workflow evidence and inspect hosting state.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
