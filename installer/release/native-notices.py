"""Inventory original native-source notices without asserting distribution clearance.

No network or archive extraction occurs. Selected regular members are copied as
exact bytes into a fresh directory, with source/member/hash provenance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile
import zipfile

PYWINMAKE_URL = "https://files.pythonhosted.org/packages/52/1c/39ab8f568cebf11896dffd95b5b922e1d9fbdab3f84fbfbd5085644f7dcf/pywinmake-0.5.11.tar.gz"
PYWINMAKE_HASH = "3e45525b9ccfa5db1d60f6c0197e8b55099fec38b10da5dd96a53d2cae6a861c"
MIT_URL = "https://raw.githubusercontent.com/spdx/license-list-data/v3.27.0/text/MIT.txt"
MIT_HASH = "b05785f9f18e6716bab63424b11454513b9943a222595b70411009202fc592b5"
EXPECTED_COMMIT = "3583e95bad46f5af7d8a826632bc68a6f7281551"
EXPECTED_FILES = {
    "expected.hpp": {"url": "https://raw.githubusercontent.com/martinmoene/expected-lite/" + EXPECTED_COMMIT + "/include/nonstd/expected.hpp",
                     "sha256": "ad67f55ce3f85b4c3cfaba5b1cea9d5db4f215e9f62f3e8ca261099a364cd8bf"},
    "LICENSE.txt": {"url": "https://raw.githubusercontent.com/martinmoene/expected-lite/" + EXPECTED_COMMIT + "/LICENSE.txt",
                    "sha256": "c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566"}}
GNUTLS_COMMIT = "23b07fd47ccf09b09f7d4fc2164a12411676b45f"
GNUTLS_SUBMODULES = {
    "gnulib-3639c57a.tar.gz": {"name": "gnutls-gnulib", "destination": "gnulib",
        "upstream": "https://gitlab.com/libidn/gnulib-mirror.git", "commit": "3639c57a970191e0bf7a9789bd1341786d0255a1",
        "tree": "2ca225316a90a5c700fdc27ff9df43c8faab73e0", "bytes": 7397877,
        "sha256": "d7d07f3e59d207a560f31ebdd7b8d66400e25e963b32f92914240439026c7c43"},
    "libtasn1-2b7ee166.tar.gz": {"name": "gnutls-libtasn1", "destination": "devel/libtasn1",
        "upstream": "https://gitlab.com/gnutls/libtasn1.git", "commit": "2b7ee166f031bea63c5e7badcedc69f1cea69c89",
        "tree": "464fe15bab132216ea2110b680cd6011073d5ed5", "bytes": 834340,
        "sha256": "7496a55741bb1c77e57702b1c2d6757d67bdff74c6d4716163e1bc30b46422dc"},
    "gnulib-aa52cadc.tar.gz": {"name": "gnutls-libtasn1-gnulib", "destination": "devel/libtasn1/gnulib",
        "upstream": "https://gitlab.com/libidn/gnulib-mirror.git", "commit": "aa52cadc36fb1af0509dc3a4bce4ce73197ece68",
        "tree": "4d3a97563e53fd6df7794b5d737650878d9cfac4", "bytes": 7731192,
        "sha256": "69d6667a5fcc8b2d13d50081762c50608ba53c62dcee8ccbbd1018a792cd531d"}}
NAMED = re.compile(r"^(licen[cs]e|copying|copyright|notice|patents)", re.I)
ROOT_CONTEXT = re.compile(r"^(authors|contributors|thanks|readme)([._-].*)?$", re.I)
RESERVED = re.compile(r"^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$", re.I)
TEXT_LIMIT = 8 << 20


def require(value, message):
    if not value:
        raise ValueError(message)


def no_links(path):
    path = Path(os.path.abspath(path))
    for candidate in (path, *path.parents):
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            continue
        require(not stat.S_ISLNK(info.st_mode)
                and not getattr(info, "st_file_attributes", 0) & 0x400,
                "Linked/reparse path rejected.")


def member_path(value):
    require(value and "\\" not in value and not value.startswith("/"), "Unsafe archive member.")
    while value.startswith("./"):
        value = value[2:]
    value = value.rstrip("/")
    require(value not in ("", "."), "Empty archive member.")
    parts = value.split("/")
    require(all(part not in ("", ".", "..") and ":" not in part
                and not part.endswith((".", " ")) and not RESERVED.fullmatch(part)
                and not any(ord(c) < 32 for c in part) for part in parts), "Unsafe archive member.")
    return PurePosixPath(*parts).as_posix()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    no_links(path)
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_file(path, limit=TEXT_LIMIT):
    no_links(path)
    require(path.is_file() and path.stat().st_size <= limit, "Invalid source text.")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    require(len(data) <= limit, "Source text too large.")
    return data


def write_new(root, relative, data):
    relative = member_path(relative)
    destination = root.joinpath(*relative.split("/"))
    no_links(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    no_links(destination)
    with destination.open("xb") as stream:
        stream.write(data)
    return {"path": relative, "bytes": len(data), "sha256": sha(data)}


class Archive:
    def __init__(self, path):
        no_links(path)
        self.zip = zipfile.is_zipfile(path)
        self.handle = zipfile.ZipFile(path) if self.zip else tarfile.open(path, "r:*")
        self.members = {}
        self.regular = {}
        try:
            entries = self.handle.infolist() if self.zip else self.handle.getmembers()
            require(len(entries) <= 250000, "Archive member bound exceeded.")
            seen = set()
            for entry in entries:
                raw = entry.filename if self.zip else entry.name
                # Some tar producers include a harmless root-directory marker.
                if raw in (".", "./") and not self.zip and entry.isdir():
                    continue
                name = member_path(raw)
                require(name.casefold() not in seen, "Duplicate archive path.")
                seen.add(name.casefold())
                self.members[name] = entry
                if self.zip:
                    kind = (entry.external_attr >> 16) & 0o170000
                    regular = not entry.is_dir() and kind in (0, stat.S_IFREG) and not entry.external_attr & 0x400
                else:
                    regular = entry.isfile()
                self.regular[name] = regular
            # A regular file or link cannot also act as an archive directory.
            for name in self.members:
                for parent in PurePosixPath(name).parents:
                    if str(parent) == ".":
                        continue
                    entry = self.members.get(str(parent))
                    if entry:
                        require(entry.is_dir() if self.zip else entry.isdir(), "Archive path conflict.")
        except Exception:
            self.handle.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.handle.close()

    def read(self, name):
        name = self.resolved_member(name)
        entry = self.members[name]
        require((entry.file_size if self.zip else entry.size) <= TEXT_LIMIT, "Notice member too large.")
        stream = self.handle.open(entry) if self.zip else self.handle.extractfile(entry)
        with stream:
            data = stream.read(TEXT_LIMIT + 1)
        require(len(data) <= TEXT_LIMIT, "Notice member too large.")
        return data

    def resolved_member(self, name):
        # Resolve archive-local aliases as data only; never create/follow an OS link.
        visited = set()
        while not self.regular[name]:
            require(not self.zip and name not in visited and len(visited) < 8,
                    "Selected notice is an unsafe archive link.")
            visited.add(name)
            entry = self.members[name]
            require(entry.issym() or entry.islnk(), "Selected notice is not a regular archive member.")
            target = member_path(entry.linkname)
            name = (PurePosixPath(name).parent / target).as_posix() if entry.issym() else target
            require(name in self.members, "Archive link target absent.")
        return name


def selection(package, name):
    parts = name.split("/")
    base = parts[-1]
    if NAMED.match(base) and not base.lower().endswith((".c", ".cpp", ".h", ".pm", ".py")):
        return "original named license/copyright/notice/patent text; applicability unreviewed"
    if len(parts) in (1, 2) and ROOT_CONTEXT.fullmatch(base):
        return "original package-root authorship/context"
    if "gnulib" in package and name.startswith("etc/license-notices/"):
        return "original GNU module license notice template; module applicability unreviewed"
    if package == "ffnvcodec" and name.endswith(".h"):
        return "complete original header retaining its file-specific copyright and MIT terms"
    if package == "zlib" and len(parts) == 2 and base == "zlib.h":
        return "complete original zlib.h retaining original license and attribution"
    if package == "ffmpeg" and name.endswith("/doc/legal.texi"):
        return "original licensing documentation"
    if base.lower() in ("license.dox", "license.dxx"):
        return "original licensing documentation"
    return None


def archive_inventory(package, archive, output, prefix):
    documents = []
    with Archive(archive) as source:
        for name in sorted(source.members):
            reason = selection(package, name)
            if not reason:
                continue
            entry = source.members[name]
            is_dir = entry.is_dir() if source.zip else entry.isdir()
            if is_dir:
                continue
            document = write_new(output, prefix + "/" + name, source.read(name))
            document.update({"sourceMember": name, "selectionReason": reason})
            resolved = source.resolved_member(name)
            if resolved != name:
                document["archiveLinkResolvedTo"] = resolved
            documents.append(document)
    return documents


def evidence_gaps(documents):
    evidence = [d for d in documents if "context" not in d["selectionReason"]]
    return [] if evidence else ["No standalone license/notice or targeted source-header text found; manual source review required."]


def source_identity(package):
    return {key: package[key] for key in ("name", "version", "url", "tarball", "bytes", "sha256")}


def expected_lite_inventory(workspace, output):
    directory = workspace / "source/jami-daemon/contrib/src/restinio/expected-lite"
    upstream_bytes = read_file(directory / "UPSTREAM.json")
    upstream = json.loads(upstream_bytes.decode("utf-8-sig"))
    require(upstream.get("project") == "expected-lite" and upstream.get("version") == "0.10.0"
            and upstream.get("commit") == EXPECTED_COMMIT and upstream.get("license") == "BSL-1.0",
            "Unexpected expected-lite identity.")
    records = upstream.get("files", [])
    require(len(records) == len(EXPECTED_FILES), "Incomplete expected-lite file binding.")
    seen, files, content = set(), [], {}
    for record in records:
        name = record.get("path")
        require(name in EXPECTED_FILES and name not in seen, "Unexpected expected-lite source file.")
        seen.add(name)
        expected = EXPECTED_FILES[name]
        require(record.get("url") == expected["url"] and record.get("sha256") == expected["sha256"],
                "Unexpected expected-lite provenance.")
        data = read_file(directory / name)
        require(sha(data) == expected["sha256"], "Vendored expected-lite input changed.")
        content[name] = data
        files.append({"path": name, "url": expected["url"], "bytes": len(data), "sha256": sha(data)})
    document = write_new(output, "native/expected-lite/LICENSE.txt", content["LICENSE.txt"])
    document.update({"sourceMember": "LICENSE.txt", "selectionReason": "original vendored license text"})
    return {"name": "expected-lite", "version": "0.10.0", "license": "BSL-1.0",
            "source": {"url": "https://github.com/martinmoene/expected-lite", "commit": EXPECTED_COMMIT,
                       "upstreamRecordSha256": sha(upstream_bytes), "files": files},
            "documents": [document], "gaps": []}


def gnutls_submodule_inventory(workspace, output):
    relative = "contrib/src/gnutls/source/"
    directory = workspace / "source/jami-daemon" / relative
    upstream_bytes = read_file(directory / "UPSTREAM.json")
    upstream = json.loads(upstream_bytes.decode("utf-8-sig"))
    require(upstream.get("schema") == 1 and upstream.get("gnutlsCommit") == GNUTLS_COMMIT,
            "Unexpected GnuTLS submodule source identity.")
    records = upstream.get("archives", [])
    require(len(records) == len(GNUTLS_SUBMODULES), "Incomplete GnuTLS submodule archive binding.")
    seen = set()
    for record in records:
        name = record.get("path")
        require(name in GNUTLS_SUBMODULES and name not in seen, "Unexpected GnuTLS submodule archive.")
        seen.add(name)
        expected = GNUTLS_SUBMODULES[name]
        require(all(record.get(key) == value for key, value in expected.items() if key != "name"),
                "Unexpected GnuTLS submodule provenance.")
        archive = directory / name
        require(file_hash(archive) == expected["sha256"] and archive.stat().st_size == expected["bytes"],
                "Vendored GnuTLS submodule archive changed.")
    result = []
    for name, expected in GNUTLS_SUBMODULES.items():
        documents = archive_inventory(expected["name"], directory / name, output, "native/" + expected["name"])
        result.append({"name": expected["name"], "version": expected["commit"],
            "source": {"url": expected["upstream"], "commit": expected["commit"], "tree": expected["tree"],
                       "archive": name, "sourcePath": relative + name, "bytes": expected["bytes"],
                       "sha256": expected["sha256"], "gnutlsCommit": GNUTLS_COMMIT,
                       "submoduleDestination": expected["destination"], "upstreamRecordSha256": sha(upstream_bytes)},
            "documents": documents, "gaps": evidence_gaps(documents)})
    return result


def runtime_inventory(inventory):
    def notices(documents):
        result = []
        for document in documents:
            require(document["path"].startswith("native/"), "Unexpected runtime notice path.")
            item = {"path": member_path(document["path"].removeprefix("native/")),
                    "bytes": document["bytes"], "sha256": document["sha256"]}
            for key in ("sourceMember", "archiveLinkResolvedTo"):
                if key in document:
                    item[key] = document[key]
            result.append(item)
        return result
    packages = []
    for package in inventory["packages"]:
        source = package.get("source") or {"url": package["url"], "archive": package["tarball"],
                                          "bytes": package["bytes"], "sha256": package["sha256"]}
        entry = {"name": package["name"], "version": package["version"], "source": source,
                 "notices": notices(package["documents"])}
        if "license" in package:
            entry["license"] = package["license"]
        packages.append(entry)
    source = inventory["core"]["source"]
    return {"schema": 1, "packages": packages,
            "jami": {"name": "jami-daemon", "source": {"url": source["upstream"],
                       "upstreamBaseCommit": source["baseCommit"], "sourceTree": source["gitTree"]},
                     "notices": notices(inventory["core"]["documents"])}}


def generate(workspace, output, pywinmake_archive, mit_text):
    no_links(workspace)
    no_links(output)
    require(not output.exists(), "Notice output must be fresh.")
    manifest_path = workspace / "source-manifest.json"
    manifest = json.loads(read_file(manifest_path).decode("utf-8-sig"))
    packages = manifest["dependencySourceManifest"]["packages"]
    names = [p["name"] for p in packages]
    require(len(names) == len(set(names)), "Duplicate package name.")
    for package in packages:
        require(re.fullmatch(r"[a-z0-9][a-z0-9-]*", package["name"]), "Invalid package name.")
        require(member_path(package["tarball"]) == Path(package["tarball"]).name, "Invalid archive name.")
        archive = workspace / "source/jami-daemon/contrib/tarballs" / package["tarball"]
        require(archive.stat().st_size == package["bytes"] and file_hash(archive) == package["sha256"],
                "Dependency original differs from source manifest.")
    require(file_hash(pywinmake_archive) == PYWINMAKE_HASH, "Unexpected pywinmake original.")
    require(file_hash(mit_text) == MIT_HASH, "Unexpected SPDX MIT template.")
    output.mkdir(parents=False)
    inventory = {"schema": 1, "status": "notice inventory; no binary applicability or legal clearance asserted",
                 "sourceManifestSha256": file_hash(manifest_path), "packages": [], "gaps": [],
                 "limitations": ["All named license texts are retained, including test/tool-only dependencies; selection is not a legal applicability decision.",
                                 "File-specific notices not in selected files remain in separately redistributed original source; binary inclusion mapping and review remain required.",
                                 "Proprietary SDK binaries, codec/patent rights, Flutter NOTICES.Z, other app dependencies and artwork are outside this inventory."]}
    for package in packages:
        archive = workspace / "source/jami-daemon/contrib/tarballs" / package["tarball"]
        entry = source_identity(package)
        entry["documents"] = archive_inventory(package["name"], archive, output, "native/" + package["name"])
        # A context README alone must never turn absence of license evidence into success.
        entry["gaps"] = evidence_gaps(entry["documents"])
        inventory["packages"].append(entry)
        inventory["gaps"].extend({"package": package["name"], "detail": gap} for gap in entry["gaps"])
    inventory["packages"].append(expected_lite_inventory(workspace, output))
    submodules = gnutls_submodule_inventory(workspace, output)
    inventory["packages"].extend(submodules)
    inventory["gaps"].extend({"package": component["name"], "detail": gap}
                             for component in submodules for gap in component["gaps"])
    core = {"name": "jami-daemon", "source": manifest["source"], "documents": []}
    for relative in ("COPYING", "README.md"):
        path = workspace / "source/jami-daemon" / relative
        record = next((r for r in manifest["sourceFiles"] if r["path"] in ("jami-daemon/" + relative, relative)), None)
        data = read_file(path)
        if record:
            require(sha(data) == record["sha256"], "Core source text changed.")
        doc = write_new(output, "native/jami-daemon/" + relative, data)
        doc["sourcePath"] = "source/jami-daemon/" + relative
        core["documents"].append(doc)
    inventory["core"] = core
    vendor = workspace / "source/vendor/pywinmake"
    tool = {"name": "pywinmake", "version": "0.5.11", "scope": "source build tool, not native runtime",
            "upstreamArchive": {"url": PYWINMAKE_URL, "sha256": PYWINMAKE_HASH},
            "licenseStatus": "No full upstream LICENSE in PyPI sdist; standard MIT terms referenced by source headers; not an upstream-supplied licence file.",
            "standardTerms": {"url": MIT_URL, "sha256": MIT_HASH, "label": "Unmodified SPDX MIT template, including its literal placeholders; copyright belongs to exact source headers below."},
            "sourceFiles": [], "missingHeaders": [], "contradictoryHeaders": []}
    tool["standardTerms"]["document"] = write_new(output, "build-tools/pywinmake/standard-MIT-template.txt", read_file(mit_text))
    for record in manifest["buildTooling"]["pywinmake"]["sourceFiles"]:
        rel = record["path"].removeprefix("vendor/pywinmake/")
        data = read_file(vendor.joinpath(*member_path(rel).split("/")))
        require(sha(data) == record["sha256"], "Vendor source changed since manifest.")
        header = data.decode("utf-8", "replace").splitlines()[:35]
        spdx = [line for line in header if "SPDX-License-Identifier:" in line]
        copyright_lines = [line for line in header if "Copyright" in line or "copyright" in line]
        document = write_new(output, "build-tools/pywinmake/source/" + rel, data)
        document.update({"sourcePath": record["path"], "spdxLines": spdx, "copyrightLines": copyright_lines})
        tool["sourceFiles"].append(document)
        if not spdx:
            tool["missingHeaders"].append(rel)
        elif any(line.strip() != "SPDX-License-Identifier: MIT License" for line in spdx):
            tool["contradictoryHeaders"].append(rel)
    tool["upstreamDocuments"] = archive_inventory("pywinmake", pywinmake_archive, output, "build-tools/pywinmake/upstream")
    inventory["buildTool"] = tool
    write_new(output, "native/index.json", (json.dumps(runtime_inventory(inventory), indent=2) + "\n").encode())
    write_new(output, "index.json", (json.dumps(inventory, indent=2) + "\n").encode())
    lines = ["Native source notices inventory", "", inventory["status"], "",
             f"Original dependency archives verified: {len(packages)}; 3 retained GnuTLS submodule archives and vendored expected-lite header/license also verified.", "",
             "Package evidence gaps:"]
    lines.extend(f"- {g['package']}: {g['detail']}" for g in inventory["gaps"])
    if not inventory["gaps"]:
        lines.append("- No package lacks selected notice evidence. This is not binary/legal qualification.")
    lines.extend(["", *inventory["limitations"], "", tool["licenseStatus"],
                  "Pywinmake files without SPDX header: " + ", ".join(tool["missingHeaders"]),
                  "Pywinmake contradictory SPDX headers: " + (", ".join(tool["contradictoryHeaders"]) or "none"),
                  "Copyright years vary (2023/2024); all original bytes retained.",
                  "", "Installer integration: copy only native/ contents, including native/index.json, into the app's notices/native/ directory.",
                  "Keep build-tools/ in corresponding-source delivery. Do not treat inputs/ downloads as application runtime files."])
    write_new(output, "README.txt", ("\n".join(lines) + "\n").encode())
    return inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pywinmake-archive", type=Path, required=True)
    parser.add_argument("--mit-text", type=Path, required=True)
    args = parser.parse_args()
    result = generate(args.workspace, args.output, args.pywinmake_archive, args.mit_text)
    print(f"Inventoried {len(result['packages'])} dependency components; {len(result['gaps'])} package evidence gaps. Review index.json limitations.")


if __name__ == "__main__":
    main()
