"""Bind a native Windows export to the exact staged Jami sources and build evidence.

This records a source-to-output association. It does not establish a reproducible
build, license clearance, or security approval.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys

EXPECTED_LITE_COMMIT = "3583e95bad46f5af7d8a826632bc68a6f7281551"
EXPECTED_LITE_HASHES = {
    "expected.hpp": "ad67f55ce3f85b4c3cfaba5b1cea9d5db4f215e9f62f3e8ca261099a364cd8bf",
    "LICENSE.txt": "c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566",
}
GNUTLS_COMMIT = "23b07fd47ccf09b09f7d4fc2164a12411676b45f"
GNUTLS_SUBMODULES = {
    "gnulib-3639c57a.tar.gz": {
        "destination": "gnulib", "upstream": "https://gitlab.com/libidn/gnulib-mirror.git",
        "commit": "3639c57a970191e0bf7a9789bd1341786d0255a1",
        "tree": "2ca225316a90a5c700fdc27ff9df43c8faab73e0", "bytes": 7397877,
        "sha256": "d7d07f3e59d207a560f31ebdd7b8d66400e25e963b32f92914240439026c7c43"},
    "libtasn1-2b7ee166.tar.gz": {
        "destination": "devel/libtasn1", "upstream": "https://gitlab.com/gnutls/libtasn1.git",
        "commit": "2b7ee166f031bea63c5e7badcedc69f1cea69c89",
        "tree": "464fe15bab132216ea2110b680cd6011073d5ed5", "bytes": 834340,
        "sha256": "7496a55741bb1c77e57702b1c2d6757d67bdff74c6d4716163e1bc30b46422dc"},
    "gnulib-aa52cadc.tar.gz": {
        "destination": "devel/libtasn1/gnulib", "upstream": "https://gitlab.com/libidn/gnulib-mirror.git",
        "commit": "aa52cadc36fb1af0509dc3a4bce4ce73197ece68",
        "tree": "4d3a97563e53fd6df7794b5d737650878d9cfac4", "bytes": 7731192,
        "sha256": "69d6667a5fcc8b2d13d50081762c50608ba53c62dcee8ccbbd1018a792cd531d"},
}
RECIPE_NAME_ALIASES = {"msgpack": "msgpack-c"}
MSVC_PACKAGES = {
    "archive_static.lib": "libarchive", "ixml.lib": "upnp", "libupnp.lib": "upnp",
    "lib_json.lib": "jsoncpp", "libgmp.lib": "gmp", "libgnutls.lib": "gnutls",
    "libhogweed.lib": "nettle", "libnettle.lib": "nettle", "libiconv.lib": "iconv",
    "libmfx.lib": "media-sdk", "libopus.lib": "opus", "libvpx.lib": "vpx",
    "libzlib.lib": "zlib", "pthreads.lib": "pthreads", "secp256k1.lib": "secp256k1",
}


def need(ok, message):
    if not ok:
        raise ValueError(message)


def relative(value):
    need(isinstance(value, str) and value and "\\" not in value and ":" not in value,
         f"Invalid relative path: {value!r}")
    p = PurePosixPath(value)
    need(not p.is_absolute() and all(x not in ("", ".", "..") for x in p.parts),
         f"Unsafe relative path: {value!r}")
    return p.as_posix()


def safe_file(root, rel):
    rel = relative(rel)
    root = Path(root).absolute()
    root_info = root.lstat()
    need(not stat.S_ISLNK(root_info.st_mode)
         and not (getattr(root_info, "st_file_attributes", 0) & 0x400),
         f"Linked/reparse root rejected: {root}")
    root = root.resolve(strict=True)
    path = root.joinpath(*rel.split("/"))
    current = root
    for part in rel.split("/"):
        current = current / part
        st = current.lstat()
        need(not stat.S_ISLNK(st.st_mode) and not (getattr(st, "st_file_attributes", 0) & 0x400),
             f"Linked/reparse path rejected: {current}")
    need(path.is_file(), f"Expected regular file: {path}")
    return path


def safe_directory(root, rel):
    rel = relative(rel)
    root = Path(root).absolute()
    root_info = root.lstat()
    need(not stat.S_ISLNK(root_info.st_mode)
         and not (getattr(root_info, "st_file_attributes", 0) & 0x400),
         f"Linked/reparse root rejected: {root}")
    path = root.resolve(strict=True)
    for part in rel.split("/"):
        path = path / part
        info = path.lstat()
        need(not stat.S_ISLNK(info.st_mode)
             and not (getattr(info, "st_file_attributes", 0) & 0x400),
             f"Linked/reparse path rejected: {path}")
    need(path.is_dir(), f"Expected regular directory: {path}")
    return path


def digest(path):
    h = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            size += len(block)
            h.update(block)
    return size, h.hexdigest()


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def hash_record(root, rel):
    path = safe_file(root, rel)
    size, sha = digest(path)
    return {"path": rel, "bytes": size, "sha256": sha}


def verify_sources(clean, producer, manifest):
    for entry in manifest["sourceFiles"]:
        rel = relative(entry["path"])
        if entry.get("materializedAs") == "copy-of-contained-tracked-directory":
            expected = {relative(item["path"]): (item["bytes"], item["sha256"])
                        for item in entry.get("copiedFiles", [])}
            prefix = rel + "/"
            need(expected and all(path.startswith(prefix) for path in expected),
                 f"Invalid copied directory manifest: {rel}")
            for root, label in ((clean, "clean"), (producer, "producer")):
                base = safe_directory(root / "source" / "jami-daemon", rel)
                actual = set()
                for path in base.rglob("*"):
                    info = path.lstat()
                    need(not stat.S_ISLNK(info.st_mode)
                         and not (getattr(info, "st_file_attributes", 0) & 0x400),
                         f"Linked/reparse copied source path: {path}")
                    if path.is_file():
                        actual.add(path.relative_to(root / "source" / "jami-daemon").as_posix())
                need(actual == set(expected), f"{label} copied source directory contents differ: {rel}")
                for file_rel, wanted in expected.items():
                    need(digest(safe_file(root / "source" / "jami-daemon", file_rel)) == wanted,
                         f"{label} copied source file mismatch: {file_rel}")
            continue
        expected = (entry["bytes"], entry["sha256"])
        for root, label in ((clean, "clean"), (producer, "producer")):
            got = digest(safe_file(root / "source" / "jami-daemon", rel))
            need(got == expected, f"{label} canonical source mismatch: {rel}")
    for entry in manifest["buildTooling"]["pywinmake"]["sourceFiles"]:
        rel = relative(entry["path"])
        expected = (entry["bytes"], entry["sha256"])
        for root, label in ((clean, "clean"), (producer, "producer")):
            got = digest(safe_file(root / "source", rel))
            need(got == expected, f"{label} vendored pywinmake mismatch: {rel}")


def verify_archives(clean, producer, manifest):
    original = clean / "qualification" / "dependency-sources.original.json"
    need(digest(safe_file(clean, "qualification/dependency-sources.original.json"))[1]
         == manifest["dependencySourceManifest"]["sha256"], "Retained dependency manifest hash mismatch")
    retained = load(original)
    expected = {p["name"]: p for p in manifest["dependencySourceManifest"]["packages"]}
    old = {p["name"]: p for p in retained["packages"]}
    need(set(old) == set(expected), "Retained archive manifest package set differs")
    checked = []
    for name, package in expected.items():
        oldp = old[name]
        need(oldp["tarball"] == package["tarball"] and oldp["tarballBytes"] == package["bytes"]
             and oldp["tarballSha256"] == package["sha256"], f"Retained archive metadata mismatch: {name}")
        rel = "contrib/tarballs/" + relative(package["tarball"])
        rec = hash_record(clean / "source" / "jami-daemon", rel)
        need((rec["bytes"], rec["sha256"]) == (package["bytes"], package["sha256"]),
             f"Clean source archive mismatch: {name}")
        producer_rec = hash_record(producer / "source" / "jami-daemon", rel)
        need((producer_rec["bytes"], producer_rec["sha256"]) == (package["bytes"], package["sha256"]),
             f"Producer source archive mismatch: {name}")
        checked.append({"name": name, "url": package["url"], "archive": package["tarball"],
                        "bytes": package["bytes"], "sha256": package["sha256"]})
    return checked


def verify_expected_lite(source_root):
    base = "contrib/src/restinio/expected-lite/"
    upstream = json.loads(safe_file(source_root, base + "UPSTREAM.json").read_text(encoding="utf-8"))
    need(upstream.get("commit") == EXPECTED_LITE_COMMIT and upstream.get("version") == "0.10.0"
         and upstream.get("license") == "BSL-1.0", "expected-lite upstream identity/license mismatch")
    entries = {Path(x["path"]).name: x for x in upstream.get("files", [])}
    result = []
    for name, expected_hash in EXPECTED_LITE_HASHES.items():
        need(entries.get(name, {}).get("sha256") == expected_hash, f"expected-lite pin mismatch: {name}")
        item = hash_record(source_root, base + name)
        need(item["sha256"] == expected_hash, f"expected-lite file mismatch: {name}")
        result.append(item)
    return {"commit": EXPECTED_LITE_COMMIT, "version": "0.10.0", "license": "BSL-1.0",
            "upstreamRecord": hash_record(source_root, base + "UPSTREAM.json"), "files": result}


def verify_gnutls_submodules(source_root):
    """Validate the exact initialized GnuTLS git-submodule source closure."""
    base = "contrib/src/gnutls/source/"
    upstream_path = base + "UPSTREAM.json"
    upstream = json.loads(safe_file(source_root, upstream_path).read_text(encoding="utf-8"))
    need(upstream.get("schema") == 1 and upstream.get("gnutlsCommit") == GNUTLS_COMMIT,
         "GnuTLS submodule upstream identity mismatch")
    records = upstream.get("archives")
    need(isinstance(records, list) and len(records) == len(GNUTLS_SUBMODULES),
         "GnuTLS submodule archive set mismatch")
    by_path = {}
    for item in records:
        need(isinstance(item, dict) and isinstance(item.get("path"), str),
             "Invalid GnuTLS submodule record")
        name = item["path"]
        need(name not in by_path, f"Duplicate GnuTLS submodule archive: {name}")
        by_path[name] = item
    need(set(by_path) == set(GNUTLS_SUBMODULES), "GnuTLS submodule archive names mismatch")
    archives = []
    for name, expected in GNUTLS_SUBMODULES.items():
        item = by_path[name]
        for key, value in expected.items():
            need(item.get(key) == value, f"GnuTLS submodule {key} pin mismatch: {name}")
        need(item.get("format") == "git archive --format=tar.gz of exact commit; submodules retained separately",
             f"GnuTLS submodule archive format mismatch: {name}")
        actual = hash_record(source_root, base + name)
        need((actual["bytes"], actual["sha256"]) == (expected["bytes"], expected["sha256"]),
             f"GnuTLS submodule archive hash/length mismatch: {name}")
        archives.append({"path": name, **expected, "format": item["format"],
                         "archiveSha256": actual["sha256"]})
    return {"gnutlsCommit": GNUTLS_COMMIT,
            "upstreamRecord": hash_record(source_root, upstream_path), "archives": archives}


def build_attempts(workspace):
    logs = workspace / "logs"
    attempts = []
    for marker in sorted(logs.glob("*-build*.exit")):
        text = marker.read_text(encoding="ascii").strip()
        need(re.fullmatch(r"\d+", text) is not None, f"Invalid build exit marker: {marker}")
        stem = marker.name[:-5]
        logfile = logs / (stem + ".log")
        rec = {"marker": marker.name, "exitCode": int(text), **hash_record(logs, marker.name)}
        rec["log"] = hash_record(logs, logfile.name) if logfile.is_file() else None
        attempts.append(rec)
    need(any(a["marker"] == "contrib-build-pinned.exit" and a["exitCode"] == 0 for a in attempts),
         "Missing successful pinned contrib build marker")
    need(any(a["marker"] == "contrib-build-offline.exit" and a["exitCode"] == 0 for a in attempts),
         "Missing successful offline contrib build marker")
    need(any(a["marker"] == "core-build.exit" and a["exitCode"] == 0 for a in attempts),
         "Missing successful core build marker")
    need(any(a["marker"] == "core-build-offline.exit" and a["exitCode"] == 0 for a in attempts),
         "Missing successful offline core build marker")
    return attempts


def cmake_evidence(workspace, source_tree):
    cache = workspace / "build-core" / "CMakeCache.txt"
    rec = hash_record(workspace, "build-core/CMakeCache.txt")
    values = {}
    for line in cache.read_text(encoding="utf-8", errors="strict").splitlines():
        m = re.match(r"^([^:#]+):[^=]+=([^\r\n]*)$", line)
        if m and m.group(1) in {
            "CMAKE_GENERATOR", "CMAKE_GENERATOR_INSTANCE", "CMAKE_GENERATOR_PLATFORM",
            "CMAKE_BUILD_TYPE", "CMAKE_CONFIGURATION_TYPES", "BUILD_CONTRIB", "BUILD_SHARED_LIBS",
            "BUILD_TESTING", "CMAKE_CXX_COMPILER", "CMAKE_C_COMPILER",
        }:
            values[m.group(1)] = m.group(2)
    need(values.get("CMAKE_GENERATOR") == "Visual Studio 17 2022", "Unexpected core CMake generator")
    need(values.get("CMAKE_GENERATOR_PLATFORM") == "x64", "Unexpected core CMake platform")
    return {"cache": rec, "sourceTree": source_tree, "selected": values}


def native_entries(path):
    data = load(path)
    need(data.get("schema") == 1, "Unsupported native export manifest schema")
    entries = data.get("files") if isinstance(data, dict) else None
    need(isinstance(entries, list) and entries, "Native export manifest must contain files[]")
    result, seen = [], set()
    for item in entries:
        rel = relative(item.get("path"))
        key = rel.casefold()
        need(key not in seen, f"Duplicate native output: {rel}")
        seen.add(key)
        need(isinstance(item.get("length"), int) and isinstance(item.get("sha256"), str),
             f"Invalid native manifest entry: {rel}")
        need(item["length"] >= 0 and re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) is not None,
             f"Invalid native manifest length/hash: {rel}")
        result.append({"path": rel, "bytes": item["length"], "sha256": item["sha256"]})
    return result


def output_file(producer, rel):
    if rel.startswith("build/"):
        return safe_file(producer / "source" / "jami-daemon", rel)
    if rel.startswith("contrib/"):
        return safe_file(producer / "source" / "jami-daemon", rel)
    if rel.startswith("notices/native/"):
        return safe_file(producer / "source" / "jami-daemon", rel)
    raise ValueError(f"Unmapped native output path: {rel}")


def package_records(manifest, source_root, packages):
    recipes = {}
    files_by_folder = {}
    for entry in manifest["sourceFiles"]:
        rel = entry["path"]
        m = re.fullmatch(r"contrib/src/([^/]+)/package\.json", rel)
        if not m:
            continue
        recipe = safe_file(source_root / "source" / "jami-daemon", rel)
        obj = json.loads(recipe.read_text(encoding="utf-8"))
        recipes[m.group(1)] = {"entry": entry, "json": obj}
    for entry in manifest["sourceFiles"]:
        m = re.match(r"contrib/src/([^/]+)/", entry["path"])
        if m:
            files_by_folder.setdefault(m.group(1), []).append(entry)
    for folder, recipe in recipes.items():
        recipe["entries"] = files_by_folder[folder]
    folder_by_name = {v["json"].get("name"): k for k, v in recipes.items() if v["json"].get("name")}
    for package_name, recipe_name in RECIPE_NAME_ALIASES.items():
        if recipe_name in folder_by_name:
            need(package_name not in folder_by_name, f"Ambiguous package recipe alias: {package_name}")
            folder_by_name[package_name] = folder_by_name[recipe_name]
    for name, package in packages.items():
        need(name in folder_by_name, f"Missing canonical package recipe: {name}")
        recipe = recipes[folder_by_name[name]]["entry"]
        need(recipe["sha256"] == package["canonicalRecipeSha256"],
             f"Canonical recipe hash differs from retained manifest: {name}")
    deps = {name: list((recipes[folder]["json"].get("deps") or []))
            for name, folder in folder_by_name.items()}
    return recipes, folder_by_name, deps


def component_for(rel, manifest, source_root, packages, folder_by_name, deps, recipes, notice_index,
                  gnutls_submodules):
    if rel == "build/lib/jami-core.lib":
        return {"kind": "jami-core", "sourceTree": manifest["source"]["gitTree"],
                "upstream": manifest["source"]["upstream"], "baseCommit": manifest["source"]["baseCommit"]}
    if rel.startswith("notices/native/"):
        if rel == "notices/native/index.json":
            return {"kind": "native-notice-index"}
        suffix = rel[len("notices/native/"):]
        for item in notice_index["packages"]:
            for notice in item.get("notices", []):
                if notice["path"] == suffix:
                    source = item["source"]
                    if item["name"] == "expected-lite":
                        return {"kind": "vendored-upstream-notice", "package": item["name"],
                                "upstream": source["url"], "commit": source["commit"],
                                "upstreamRecordSha256": source["upstreamRecordSha256"],
                                "sourceFiles": source["files"], "noticeSha256": notice["sha256"]}
                    return {"kind": "native-notice", "package": item["name"],
                            "archive": source["archive"], "archiveUrl": source["url"],
                            "archiveSha256": source["sha256"], "sourceMember": notice.get("sourceMember"),
                            "noticeSha256": notice["sha256"]}
        jami = notice_index.get("jami", {})
        for notice in jami.get("notices", []):
            if notice["path"] == suffix:
                source = jami["source"]
                return {"kind": "jami-notice", "sourceTree": source["sourceTree"],
                        "sourceUrl": source["url"], "sourceMember": notice["path"],
                        "noticeSha256": notice["sha256"]}
        raise ValueError(f"Native notice has no provenance index entry: {rel}")
    if rel.startswith("contrib/msvc/lib/x64/"):
        name = PurePosixPath(rel).name
        package = MSVC_PACKAGES.get(name)
        need(package in packages, f"No source mapping for MSVC export {name}")
        return package_component(package, packages, folder_by_name, deps, recipes, gnutls_submodules)
    m = re.match(r"contrib/build/([^/]+)/", rel)
    need(m, f"Unmapped native output path: {rel}")
    folder = m.group(1)
    package = folder if folder in packages else ("msgpack" if folder == "msgpack-c" else None)
    need(package in packages, f"No source archive mapping for contrib output: {folder}")
    return package_component(package, packages, folder_by_name, deps, recipes, gnutls_submodules)


def package_component(name, packages, folder_by_name, deps, recipes, gnutls_submodules):
    need(name in packages, f"Missing retained package record: {name}")
    seen = set()
    def visit(pkg):
        need(pkg in packages and pkg in folder_by_name, f"Unmapped package dependency: {pkg}")
        if pkg in seen:
            return
        seen.add(pkg)
        folder = folder_by_name[pkg]
        need(folder in deps, f"Missing recipe for package: {pkg}")
        for child in deps[pkg]:
            visit(child)
    visit(name)
    sources = []
    for pkg in sorted(seen):
        source = {"name": pkg, "archive": packages[pkg]["tarball"],
                        "url": packages[pkg]["url"], "archiveSha256": packages[pkg]["sha256"],
                        "recipeSha256": packages[pkg]["canonicalRecipeSha256"],
                        "patches": [{"path": e["path"], "sha256": e["sha256"]}
                                    for e in recipes[folder_by_name[pkg]]["entries"]
                                    if PurePosixPath(e["path"]).suffix.lower() in (".patch", ".diff")]}
        if pkg == "gnutls":
            source["submodules"] = gnutls_submodules["archives"]
        sources.append(source)
    return {"kind": "contrib-package", "package": name, "sourceClosure": sources}


def validate_notices(producer, entries, index):
    listed = {"notices/native/index.json"}
    for package in index["packages"]:
        for notice in package.get("notices", []):
            listed.add("notices/native/" + relative(notice["path"]))
    for notice in index.get("jami", {}).get("notices", []):
        listed.add("notices/native/" + relative(notice["path"]))
    by_path = {e["path"]: e for e in entries}
    for rel in by_path:
        if rel.startswith("notices/native/"):
            need(rel in listed, f"Native notice payload not indexed: {rel}")
    for rel in listed - {"notices/native/index.json"}:
        item = by_path.get(rel)
        need(item is not None, f"Indexed notice missing from native export: {rel}")
        data = next((n for p in index["packages"] for n in p.get("notices", [])
                     if "notices/native/" + n["path"] == rel), None)
        if data is None:
            data = next((n for n in index.get("jami", {}).get("notices", [])
                         if "notices/native/" + n["path"] == rel), None)
        need(data is not None and item["bytes"] == data["bytes"] and item["sha256"] == data["sha256"],
             f"Notice index hash/length does not bind exported payload: {rel}")


def create(args):
    clean, producer = Path(args.source_workspace), Path(args.build_workspace)
    manifest = load(clean / "source-manifest.json")
    need(manifest.get("schema") == 1 and manifest.get("source", {}).get("gitTree"),
         "Unsupported or incomplete clean source manifest")
    source_root = clean / "source"
    verify_sources(clean, producer, manifest)
    archives = verify_archives(clean, producer, manifest)
    expected_lite = verify_expected_lite(source_root / "jami-daemon")
    gnutls_submodules = verify_gnutls_submodules(source_root / "jami-daemon")
    attempts = build_attempts(producer)
    cmake = cmake_evidence(producer, manifest["source"]["gitTree"])
    package_list = manifest["dependencySourceManifest"]["packages"]
    packages = {p["name"]: p for p in package_list}
    recipes, folder_by_name, deps = package_records(manifest, clean, packages)
    entries = native_entries(args.native_manifest)
    index_path = safe_file(producer / "source" / "jami-daemon", "notices/native/index.json")
    index = json.loads(index_path.read_text(encoding="utf-8"))
    need(index.get("schema") == 1, "Unsupported native notice index")
    need(index.get("jami", {}).get("source", {}).get("sourceTree") == manifest["source"]["gitTree"],
         "Notice index Jami source tree mismatch")
    validate_notices(producer, entries, index)
    bound = []
    for entry in entries:
        actual = digest(output_file(producer, entry["path"]))
        need(actual == (entry["bytes"], entry["sha256"]), f"Native export hash/length mismatch: {entry['path']}")
        component = component_for(entry["path"], manifest, clean, packages, folder_by_name, deps, recipes,
                                  index, gnutls_submodules)
        bound.append({**entry, "component": component})
    command_records = []
    for file in sorted(producer.glob("build*.cmd")):
        command_records.append(hash_record(producer, file.name))
    need(command_records, "Build command records not found")
    receipt = {
        "schema": 1,
        "purpose": "native source-to-output provenance association",
        "claims": {"bitForBitReproducible": False, "licenseClearance": False,
                   "securityApproval": False, "failedBuildAttemptsHidden": False},
        "source": {"rootTree": manifest["source"]["rootTree"], "resolvedCommit": manifest["source"]["resolvedCommit"],
                   "jamiTree": manifest["source"]["gitTree"], "historicalImportedTree": manifest["source"]["historicalImportedTree"],
                   "sourceManifest": hash_record(clean, "source-manifest.json"),
                   "dependencySourceManifest": hash_record(clean, "qualification/dependency-sources.original.json"),
                   "canonicalSourceFileCount": len(manifest["sourceFiles"]),
                   "vendoredPywinmakeFileCount": len(manifest["buildTooling"]["pywinmake"]["sourceFiles"]),
                   "sourceFilesComparedCleanAndProducer": True,
                   "cleanReferenceHadNoContribBuild": not (source_root / "jami-daemon" / "contrib" / "build").exists(),
                   "expectedLite": expected_lite, "gnutlsSubmodules": gnutls_submodules},
        "dependencyArchives": archives,
        "build": {"workspaceInitialState": "clean source reference had no contrib/build; producer build-root initial emptiness is not independently asserted",
                  "attempts": attempts, "commands": command_records, "coreCMake": cmake},
        "nativeExport": bound,
    }
    out = Path(args.output)
    need(not out.exists(), f"Output already exists: {out}")
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True)
        stream.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-workspace", required=True)
    parser.add_argument("--build-workspace", required=True)
    parser.add_argument("--native-manifest", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        create(args)
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        print(f"native provenance: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
