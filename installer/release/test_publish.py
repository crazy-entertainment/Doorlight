import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("publish", Path(__file__).with_name("publish.py"))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class HostedAssets:
    def __init__(self):
        self.values = {}
        self.operations = []
        self.fail_promotion = False
        self.next_id = 1

    def assets(self, release):
        return copy.deepcopy(self.values)

    def upload(self, release, path, name=None):
        name = name or path.name
        if name in self.values:
            raise AssertionError("Duplicate hosted asset")
        value = {"id": self.next_id, "name": name, "state": "uploaded",
                 "size": path.stat().st_size, "digest": "sha256:" + p.digest(path)}
        self.next_id += 1
        self.values[name] = value
        self.operations.append(("upload", name))
        return value

    def request(self, method, route, value=None):
        identity = int(route.rsplit("/", 1)[1])
        name = next(name for name, asset in self.values.items() if asset["id"] == identity)
        self.operations.append((method, name))
        if method == "DELETE":
            del self.values[name]
        elif method == "PATCH":
            if self.fail_promotion:
                raise RuntimeError("Synthetic promotion failure")
            asset = self.values.pop(name)
            asset["name"] = value["name"]
            self.values[asset["name"]] = asset
        else:
            raise AssertionError("Unexpected operation")


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.config = {"nativeInputs": {"archiveSha256": "a" * 64, "daemonSourceTree": "d" * 40,
                                       "correspondingSourceUrl": "https://example.invalid/native-source.tar.gz",
                                       "correspondingSourceSha256": "e" * 64}}
        self.commit = "b" * 40

    def candidate(self):
        version = "1.12.1"
        paths = ["Doorlight.Package.json", "Doorlight.Package.zip", "Doorlight.Source.tar.gz", "Doorlight-Setup.exe",
                 f"Doorlight-{version}-Setup.exe", f"Doorlight-{version}-Online-Setup.exe"]
        for name in paths:
            content = json.dumps({"Version": version}).encode() if name.endswith(".json") else b"synthetic artifact"
            if name.endswith("Setup.exe"):
                content = b"synthetic online installer" if "Online" in name else b"synthetic offline installer"
            (self.directory / name).write_bytes(content)
        receipt = {"schema": 1, "commit": self.commit, "version": version,
                   "daemonSourceTree": "d" * 40,
                   "releaseSequence": 12 * 65536 + 1, "nativeInputsSha256": "a" * 64,
                   "correspondingSourceUrl": self.config["nativeInputs"]["correspondingSourceUrl"],
                   "correspondingSourceSha256": self.config["nativeInputs"]["correspondingSourceSha256"],
                   "files": [{"name": name, "length": (self.directory / name).stat().st_size,
                              "sha256": p.digest(self.directory / name)} for name in paths]}
        (self.directory / "build-receipt.json").write_text(json.dumps(receipt))
        return receipt

    def test_disabled_configuration_blocks_without_provider_access(self):
        config = self.directory / "config.json"
        config.write_text(json.dumps({"schema": 1, "repository": p.REPOSITORY, "deliveryEnabled": False}))
        with self.assertRaisesRegex(ValueError, "disabled"):
            p.config_read(config, self.directory / "absent-root.json")

    def test_candidate_binds_all_bytes_revision_and_native_inputs(self):
        self.candidate()
        receipt, files = p.candidate_read(self.directory, self.commit, 12, 1, self.config)
        self.assertEqual(len(files), 6)
        with self.assertRaisesRegex(ValueError, "workflow"):
            p.candidate_read(self.directory, "c" * 40, 12, 1, self.config)
        (self.directory / "Doorlight.Package.zip").write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "changed"):
            p.candidate_read(self.directory, self.commit, 12, 1, self.config)

    def test_stable_installer_alias_requires_identical_offline_bytes(self):
        for replacement in (b"x" * len(b"synthetic offline installer"), b"synthetic online installer"):
            with self.subTest(replacement=replacement):
                receipt = self.candidate()
                alias = self.directory / "Doorlight-Setup.exe"
                alias.write_bytes(replacement)
                # Even a self-consistent receipt may not bind the stable URL to different bytes.
                entry = next(item for item in receipt["files"] if item["name"] == alias.name)
                entry.update(length=alias.stat().st_size, sha256=p.digest(alias))
                (self.directory / "build-receipt.json").write_text(json.dumps(receipt))
                with self.assertRaisesRegex(ValueError, "alias differs"):
                    p.candidate_read(self.directory, self.commit, 12, 1, self.config)

    def test_stable_installer_alias_cannot_be_omitted_from_receipt(self):
        receipt = self.candidate()
        receipt["files"] = [item for item in receipt["files"] if item["name"] != "Doorlight-Setup.exe"]
        (self.directory / "build-receipt.json").write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, "file set"):
            p.candidate_read(self.directory, self.commit, 12, 1, self.config)

    def test_receipt_cannot_escape_or_duplicate_files(self):
        receipt = self.candidate()
        for name in ("../outside.zip", receipt["files"][1]["name"]):
            receipt["files"][0]["name"] = name
            (self.directory / "build-receipt.json").write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, "artifact"):
                p.candidate_read(self.directory, self.commit, 12, 1, self.config)

    def test_receipt_binds_corresponding_source(self):
        for key, value in (("correspondingSourceUrl", "https://example.invalid/other.tar.gz"),
                           ("correspondingSourceSha256", "f" * 64)):
            receipt = self.candidate()
            receipt[key] = value
            (self.directory / "build-receipt.json").write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, "workflow"):
                p.candidate_read(self.directory, self.commit, 12, 1, self.config)

    def test_immutable_upload_never_overwrites_different_bytes(self):
        path = self.directory / "1.targets.json"
        path.write_bytes(b"first")
        host = HostedAssets()
        assets = {}
        p.immutable_upload(host, {"id": 1}, path, assets)
        p.immutable_upload(host, {"id": 1}, path, assets)
        self.assertEqual(len(host.operations), 1)
        path.write_bytes(b"different")
        with self.assertRaisesRegex(ValueError, "refusing overwrite"):
            p.immutable_upload(host, {"id": 1}, path, assets)
        self.assertEqual(len(host.operations), 1)

    def timestamp_fixture(self):
        previous = self.directory / "previous"
        previous.mkdir()
        old = previous / "timestamp.json"
        old.write_bytes(b"old signed timestamp")
        path = self.directory / "timestamp.json"
        path.write_bytes(b"new signed timestamp")
        host = HostedAssets()
        host.upload({"id": 1}, old)
        host.operations.clear()
        return host, old, path

    def test_timestamp_is_staged_before_old_head_is_removed(self):
        host, old, path = self.timestamp_fixture()
        p.timestamp_commit(host, {"id": 1}, path, p.digest(old), self.directory)
        self.assertEqual([operation[0] for operation in host.operations], ["upload", "DELETE", "PATCH"])
        self.assertEqual(host.values["timestamp.json"]["digest"], "sha256:" + p.digest(path))

    def test_failed_timestamp_promotion_restores_old_head(self):
        host, old, path = self.timestamp_fixture()
        host.fail_promotion = True
        with self.assertRaisesRegex(RuntimeError, "Synthetic"):
            p.timestamp_commit(host, {"id": 1}, path, p.digest(old), self.directory)
        self.assertEqual(host.values["timestamp.json"]["digest"], "sha256:" + p.digest(old))

    def test_concurrent_timestamp_change_cannot_be_overwritten(self):
        host, old, path = self.timestamp_fixture()
        with self.assertRaisesRegex(ValueError, "changed during"):
            p.timestamp_commit(host, {"id": 1}, path, "f" * 64, self.directory)
        self.assertFalse(any(operation[0] == "DELETE" for operation in host.operations))
        self.assertEqual(host.values["timestamp.json"]["digest"], "sha256:" + p.digest(old))

    def test_duplicate_json_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            p.decode('{"enabled":false,"enabled":true}')

    def test_review_date_requires_a_real_past_or_current_day(self):
        self.assertTrue(p.review_date("2026-01-01"))
        for invalid in ("2026-02-30", "2026-99-01", "2099-01-01", "2026-1-1", None):
            self.assertFalse(p.review_date(invalid))


if __name__ == "__main__":
    unittest.main()
