import importlib.util
import io
import json
from pathlib import Path
import stat
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("native_notices", Path(__file__).with_name("native-notices.py"))
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)


class NoticeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def archive(self, entries):
        path = self.root / "source.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name, data in entries:
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        return path

    def test_original_bytes_and_gap_are_preserved(self):
        data = b"Copyright \xc4\xe9\r\nExact permission terms.\n\x00"
        archive = self.archive([("p/LICENSE-MIT", data), ("p/README", b"Context, not license permission.")])
        output = self.root / "output"
        output.mkdir()
        documents = n.archive_inventory("p", archive, output, "native/p")
        license_doc = next(d for d in documents if d["sourceMember"].endswith("LICENSE-MIT"))
        self.assertEqual((output / license_doc["path"]).read_bytes(), data)
        self.assertEqual(license_doc["sha256"], n.sha(data))
        self.assertEqual(n.evidence_gaps(documents), [])
        self.assertEqual(len(n.evidence_gaps([d for d in documents if d is not license_doc])), 1)
        self.assertEqual(len(n.evidence_gaps([])), 1)

    def test_malicious_names_and_duplicate_paths_rejected(self):
        for name in ("../escape", "/absolute", "C:/escape", "p/../escape", "p\\escape", "p/NUL", "p/name.:"):
            with self.subTest(name=name):
                archive = self.archive([(name, b"bad")])
                with self.assertRaises(ValueError):
                    with n.Archive(archive):
                        pass
        for entries in ([('p/LICENSE', b'a'), ('p/LICENSE', b'b')],
                        [('p/LICENSE', b'a'), ('p/license', b'b')],
                        [('p', b'a'), ('p/LICENSE', b'b')]):
            with self.assertRaises(ValueError):
                with n.Archive(self.archive(entries)):
                    pass

    def test_zip_symlink_is_not_followed(self):
        path = self.root / "symlink.zip"
        with zipfile.ZipFile(path, "w") as archive:
            entry = zipfile.ZipInfo("p/LICENSE")
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, "../../private")
        with n.Archive(path) as archive:
            with self.assertRaises(ValueError):
                archive.read("p/LICENSE")

    def test_zip_windows_reparse_member_is_not_read(self):
        path = self.root / "reparse.zip"
        with zipfile.ZipFile(path, "w") as archive:
            entry = zipfile.ZipInfo("p/LICENSE")
            entry.external_attr = (stat.S_IFREG | 0o644) << 16 | 0x400
            archive.writestr(entry, "unsafe")
        with n.Archive(path) as archive:
            with self.assertRaises(ValueError):
                archive.read("p/LICENSE")

    def test_safe_archive_alias_materializes_regular_bytes_only(self):
        path = self.root / "aliases.tar"
        with tarfile.open(path, "w") as archive:
            entry = tarfile.TarInfo("p/LICENSE")
            entry.size = 5
            archive.addfile(entry, io.BytesIO(b"terms"))
            entry = tarfile.TarInfo("p/NOTICE")
            entry.type = tarfile.SYMTYPE
            entry.linkname = "LICENSE"
            archive.addfile(entry)
            entry = tarfile.TarInfo("p/COPYING")
            entry.type = tarfile.SYMTYPE
            entry.linkname = "../../private"
            archive.addfile(entry)
        with n.Archive(path) as archive:
            self.assertEqual(archive.read("p/NOTICE"), b"terms")
            with self.assertRaises(ValueError):
                archive.read("p/COPYING")

    def test_reparse_input_or_output_is_rejected(self):
        attributes = SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_file_attributes=0x400)
        with patch.object(Path, "lstat", return_value=attributes):
            with self.assertRaisesRegex(ValueError, "reparse"):
                n.no_links(self.root)
            with self.assertRaisesRegex(ValueError, "reparse"):
                n.write_new(self.root, "NOTICE", b"text")

    def test_targeted_header_and_gnu_versioned_names(self):
        for package, name in (("llhttp", "p/LICENSE-MIT"), ("zlib", "p/zlib.h"),
                              ("ffnvcodec", "p/include/dynlink_cuda.h"), ("gmp", "p/COPYINGv3"),
                              ("ffmpeg", "p/doc/legal.texi")):
            self.assertIsNotNone(n.selection(package, name))

    def test_runtime_index_excludes_build_tools_and_private_paths(self):
        document = {"path": "native/example/p/LICENSE", "bytes": 5, "sha256": "a" * 64,
                    "sourceMember": "p/LICENSE", "selectionReason": "internal process description"}
        inventory = {"status": "unqualified", "buildTool": {"sourcePath": "C:/private"},
                     "packages": [{"name": "example", "version": "1", "url": "https://example.invalid/source.tar.gz",
                                   "tarball": "source.tar.gz", "bytes": 50, "sha256": "b" * 64,
                                   "documents": [document]}],
                     "core": {"source": {"upstream": "https://example.invalid/jami", "baseCommit": "abc",
                                         "gitTree": "def", "canonicalPath": "F:/private"},
                              "documents": [{**document, "path": "native/jami-daemon/COPYING"}]}}
        runtime = n.runtime_inventory(inventory)
        text = __import__("json").dumps(runtime)
        for forbidden in ("buildTool", "C:/", "F:/", "unqualified", "selectionReason", "internal process"):
            self.assertNotIn(forbidden, text)
        self.assertEqual(runtime["packages"][0]["notices"][0]["path"], "example/p/LICENSE")
        self.assertEqual(runtime["jami"]["notices"][0]["path"], "jami-daemon/COPYING")

    def test_vendored_expected_lite_binds_header_and_license(self):
        directory = self.root / "source/jami-daemon/contrib/src/restinio/expected-lite"
        directory.mkdir(parents=True)
        data = {"expected.hpp": b"synthetic header", "LICENSE.txt": b"synthetic BSL terms\r\n"}
        pinned = {name: {"url": n.EXPECTED_FILES[name]["url"], "sha256": n.sha(content)}
                  for name, content in data.items()}
        provenance = {"project": "expected-lite", "version": "0.10.0", "commit": n.EXPECTED_COMMIT,
                      "license": "BSL-1.0", "files": [{"path": name, **values} for name, values in pinned.items()]}
        for name, content in data.items():
            (directory / name).write_bytes(content)
        (directory / "UPSTREAM.json").write_text(json.dumps(provenance))
        output = self.root / "output"
        output.mkdir()
        with patch.dict(n.EXPECTED_FILES, pinned, clear=True):
            component = n.expected_lite_inventory(self.root, output)
            self.assertEqual(component["license"], "BSL-1.0")
            self.assertEqual(len(component["source"]["files"]), 2)
            self.assertEqual((output / "native/expected-lite/LICENSE.txt").read_bytes(), data["LICENSE.txt"])
            for name in data:
                with self.subTest(tampered=name):
                    (directory / name).write_bytes(b"changed")
                    with self.assertRaisesRegex(ValueError, "changed"):
                        n.expected_lite_inventory(self.root, output)
                    (directory / name).write_bytes(data[name])
            provenance["files"][0]["sha256"] = "0" * 64
            (directory / "UPSTREAM.json").write_text(json.dumps(provenance))
            with self.assertRaisesRegex(ValueError, "provenance"):
                n.expected_lite_inventory(self.root, output)

    def test_gnutls_submodule_archives_bind_provenance_and_original_bytes(self):
        directory = self.root / "source/jami-daemon/contrib/src/gnutls/source"
        directory.mkdir(parents=True)
        pinned, originals = {}, {}
        for name, expected in n.GNUTLS_SUBMODULES.items():
            archive = directory / name
            with tarfile.open(archive, "w:gz") as handle:
                content = b"Exact synthetic terms\r\n"
                entry = tarfile.TarInfo("COPYING")
                entry.size = len(content)
                handle.addfile(entry, io.BytesIO(content))
            originals[name] = archive.read_bytes()
            pinned[name] = {**expected, "bytes": archive.stat().st_size, "sha256": n.sha(originals[name])}
        metadata = {"schema": 1, "gnutlsCommit": n.GNUTLS_COMMIT,
                    "archives": [{"path": name, **{k: v for k, v in record.items() if k != "name"}}
                                 for name, record in pinned.items()]}
        (directory / "UPSTREAM.json").write_text(json.dumps(metadata))
        output = self.root / "output"
        output.mkdir()
        with patch.dict(n.GNUTLS_SUBMODULES, pinned, clear=True):
            components = n.gnutls_submodule_inventory(self.root, output)
            self.assertEqual(len(components), 3)
            for component in components:
                self.assertEqual((output / component["documents"][0]["path"]).read_bytes(), b"Exact synthetic terms\r\n")
                self.assertIn("contrib/src/gnutls/source/", component["source"]["sourcePath"])
            for name in originals:
                with self.subTest(tampered=name):
                    (directory / name).write_bytes(b"changed")
                    with self.assertRaisesRegex(ValueError, "changed"):
                        n.gnutls_submodule_inventory(self.root, output)
                    (directory / name).write_bytes(originals[name])
            metadata["archives"][0]["commit"] = "0" * 40
            (directory / "UPSTREAM.json").write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError, "provenance"):
                n.gnutls_submodule_inventory(self.root, output)


if __name__ == "__main__":
    unittest.main()
