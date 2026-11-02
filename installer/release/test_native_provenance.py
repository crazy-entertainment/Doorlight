import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("native_provenance", HERE / "native-provenance.py")
NP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NP)
REPO = HERE.parents[1]


def put(root, rel, data):
    path = root.joinpath(*rel.split("/"))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def record(path):
    data = path.read_bytes()
    return {"path": path.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


class NativeProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.clean, self.producer = self.base / "clean", self.base / "producer"
        self.clean.mkdir(); self.producer.mkdir()
        self.clean_source = self.clean / "source" / "jami-daemon"
        self.prod_source = self.producer / "source" / "jami-daemon"
        self.source_files = []
        self.packages = []
        for i in range(32):
            name = "zlib" if i == 31 else ("gnutls" if i == 30 else f"pkg{i:02d}")
            archive = f"{name}.tar.gz"
            archive_data = f"source archive {name}".encode()
            recipe_rel = f"contrib/src/{name}/package.json"
            recipe = json.dumps({"name": name, "deps": []}, sort_keys=True).encode()
            for root in (self.clean_source, self.prod_source):
                put(root, f"contrib/tarballs/{archive}", archive_data)
                put(root, recipe_rel, recipe)
            self.source_files.append(self.entry(self.clean_source, recipe_rel))
            self.packages.append({"name": name, "version": "1", "url": f"https://example.invalid/{archive}",
                                  "tarball": archive, "bytes": len(archive_data),
                                  "sha256": hashlib.sha256(archive_data).hexdigest(),
                                  "canonicalRecipeSha256": hashlib.sha256(recipe).hexdigest()})
        gnutls_source = REPO / "native" / "jami" / "contrib" / "src" / "gnutls" / "source"
        for name in ("UPSTREAM.json", "gnulib-3639c57a.tar.gz", "libtasn1-2b7ee166.tar.gz",
                     "gnulib-aa52cadc.tar.gz"):
            rel = f"contrib/src/gnutls/source/{name}"
            data = (gnutls_source / name).read_bytes()
            for root in (self.clean_source, self.prod_source):
                put(root, rel, data)
            self.source_files.append(self.entry(self.clean_source, rel))
        canonical = REPO / "native" / "jami" / "contrib" / "src" / "restinio" / "expected-lite"
        for name in ("expected.hpp", "LICENSE.txt", "UPSTREAM.json"):
            data = (canonical / name).read_bytes()
            rel = f"contrib/src/restinio/expected-lite/{name}"
            for root in (self.clean_source, self.prod_source):
                put(root, rel, data)
            self.source_files.append(self.entry(self.clean_source, rel))
        copied_rel = "test/agent/examples/jami/fixture.scm"
        copied_data = b"contained source copy\n"
        for root in (self.clean_source, self.prod_source):
            put(root, copied_rel, copied_data)
        self.source_files.append({"path": "test/agent/examples/jami", "gitMode": "120000",
                                  "materializedAs": "copy-of-contained-tracked-directory",
                                  "symlinkTarget": "../jami", "copiedFiles": [
                                      {"path": copied_rel, "bytes": len(copied_data),
                                       "sha256": hashlib.sha256(copied_data).hexdigest()}]})
        py_rel = "vendor/pywinmake/one.py"
        py_data = b"# fixture\n"
        put(self.clean / "source", py_rel, py_data)
        put(self.producer / "source", py_rel, py_data)
        dep_manifest = {"packages": [{"name": p["name"], "version": p["version"], "url": p["url"],
                                      "tarball": p["tarball"], "tarballBytes": p["bytes"],
                                      "tarballSha256": p["sha256"]} for p in self.packages]}
        dep_bytes = json.dumps(dep_manifest, sort_keys=True).encode()
        put(self.clean, "qualification/dependency-sources.original.json", dep_bytes)
        source_manifest = {
            "schema": 1,
            "source": {"rootTree": "a" * 40, "resolvedCommit": None, "gitTree": "b" * 40,
                       "historicalImportedTree": "c" * 40, "upstream": "https://example.invalid/jami",
                       "baseCommit": "d" * 40},
            "sourceFiles": self.source_files,
            "dependencySourceManifest": {"sha256": hashlib.sha256(dep_bytes).hexdigest(), "packages": self.packages},
            "buildTooling": {"pywinmake": {"sourceFiles": [
                {"path": py_rel, "bytes": len(py_data), "sha256": hashlib.sha256(py_data).hexdigest()}]}},
        }
        (self.clean / "source-manifest.json").write_text(json.dumps(source_manifest), encoding="utf-8")
        self.source_manifest = source_manifest
        # One notice file and its index represent the exact staged source tree.
        notice_path = "notices/native/pkg00/LICENSE.txt"
        notice_data = b"fixture notice\n"
        notice = put(self.prod_source, notice_path, notice_data)
        index = {"schema": 1, "packages": [{"name": "pkg00", "source": {
            "url": "https://example.invalid/pkg00.tar.gz", "archive": "pkg00.tar.gz", "sha256": "e" * 64}, "notices": [
            {"path": "pkg00/LICENSE.txt", **{k: v for k, v in record(notice).items() if k != "path"}}]}],
            "jami": {"source": {"sourceTree": "b" * 40}, "notices": []}}
        index_data = json.dumps(index, sort_keys=True).encode()
        put(self.prod_source, "notices/native/index.json", index_data)
        (self.producer / "logs").mkdir()
        for marker, code, stem in (("contrib-build.exit", "1", "contrib-build"),
                                   ("contrib-build-pinned.exit", "0", "contrib-build-pinned"),
                                   ("contrib-build-offline.exit", "0", "contrib-build-offline"),
                                   ("core-build.exit", "0", "core-build"),
                                   ("core-build-offline.exit", "0", "core-build-offline")):
            put(self.producer, f"logs/{marker}", code.encode())
            put(self.producer, f"logs/{stem}.log", (stem + " log").encode())
        put(self.producer, "build-contrib.cmd", b"contrib invocation\n")
        put(self.producer, "build-core.cmd", b"core invocation\n")
        put(self.producer, "build-core/CMakeCache.txt",
            b"CMAKE_GENERATOR:INTERNAL=Visual Studio 17 2022\nCMAKE_GENERATOR_PLATFORM:INTERNAL=x64\nBUILD_CONTRIB:BOOL=OFF\n")
        self.native = self.base / "native-manifest.json"
        self.export_files = []
        for rel, data in (("build/lib/jami-core.lib", b"core lib"),
                          ("contrib/build/pkg00/pkg00.lib", b"package lib"),
                          ("contrib/msvc/lib/x64/libzlib.lib", b"zlib lib")):
            put(self.prod_source, rel, data)
            self.export_files.append({"path": rel, "length": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        for rel, data in ((notice_path, notice_data), ("notices/native/index.json", index_data)):
            self.export_files.append({"path": rel, "length": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        rel, data = "contrib/msvc/lib/x64/libgnutls.lib", b"gnutls lib"
        put(self.prod_source, rel, data)
        self.export_files.append({"path": rel, "length": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        self.write_native()

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def entry(root, rel):
        path = root.joinpath(*rel.split("/"))
        data = path.read_bytes()
        return {"path": rel, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}

    def write_native(self):
        self.native.write_text(json.dumps({"schema": 1, "files": self.export_files}), encoding="utf-8")

    def run_create(self):
        output = self.base / "receipt.json"
        args = type("Args", (), {"source_workspace": str(self.clean), "build_workspace": str(self.producer),
                                  "native_manifest": str(self.native), "output": str(output)})
        NP.create(args)
        return json.loads(output.read_text(encoding="utf-8"))

    def test_binds_sources_outputs_and_keeps_failed_attempt_history(self):
        receipt = self.run_create()
        self.assertEqual(receipt["source"]["canonicalSourceFileCount"], len(self.source_files))
        self.assertEqual(receipt["build"]["attempts"][0]["exitCode"], 0)
        self.assertIn(1, [a["exitCode"] for a in receipt["build"]["attempts"]])
        self.assertEqual(receipt["nativeExport"][0]["component"]["kind"], "jami-core")
        self.assertEqual(receipt["source"]["gnutlsSubmodules"]["gnutlsCommit"], NP.GNUTLS_COMMIT)
        gnutls = next(item for item in receipt["nativeExport"] if item["path"].endswith("libgnutls.lib"))
        gnutls_source = next(item for item in gnutls["component"]["sourceClosure"] if item["name"] == "gnutls")
        self.assertEqual(len(gnutls_source["submodules"]), 3)

    def test_rejects_tampered_gnutls_submodule_archive(self):
        archive = self.clean_source / "contrib/src/gnutls/source/gnulib-3639c57a.tar.gz"
        archive.write_bytes(archive.read_bytes() + b"tamper")
        with self.assertRaisesRegex(ValueError, "GnuTLS submodule archive hash/length mismatch"):
            NP.verify_gnutls_submodules(self.clean_source)

    def test_rejects_clean_producer_source_mismatch(self):
        put(self.prod_source, self.source_files[0]["path"], b"changed")
        with self.assertRaisesRegex(ValueError, "source mismatch"):
            self.run_create()

    def test_checks_materialized_source_directories_without_links_or_extras(self):
        NP.verify_sources(self.clean, self.producer, self.source_manifest)
        put(self.prod_source, "test/agent/examples/jami/extra.scm", b"unexpected\n")
        with self.assertRaisesRegex(ValueError, "contents differ"):
            NP.verify_sources(self.clean, self.producer, self.source_manifest)

    def test_requires_success_markers(self):
        (self.producer / "logs" / "core-build.exit").write_text("1", encoding="ascii")
        with self.assertRaisesRegex(ValueError, "successful core build marker"):
            self.run_create()

    def test_rejects_unmapped_or_mismatched_export(self):
        self.export_files.append({"path": "mystery/library.lib", "length": 1, "sha256": "0" * 64})
        self.write_native()
        with self.assertRaisesRegex(ValueError, "Unmapped native output path|No source archive mapping"):
            self.run_create()

    def test_rejects_native_manifest_hash_mismatch(self):
        self.export_files[0]["sha256"] = "0" * 64
        self.write_native()
        with self.assertRaisesRegex(ValueError, "Native export hash/length mismatch"):
            self.run_create()


if __name__ == "__main__":
    unittest.main()
