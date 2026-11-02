import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "validate-thirdparty-prefix.py"
SPEC = importlib.util.spec_from_file_location("validate_thirdparty_prefix", SCRIPT)
VALIDATOR = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(VALIDATOR)


class PrefixFixture:
    revision = "a" * 40

    def __init__(self, root: Path):
        self.root = root
        for directory in ("include/example", "lib", "licenses", "share/cubrid-thirdparty"):
            (root / directory).mkdir(parents=True, exist_ok=True)

        (root / "include/example/example.h").write_text("#define EXAMPLE 1\n")
        (root / "lib/libexample.a").write_bytes(b"archive")
        (root / "licenses/example.txt").write_text("license\n")

        self.manifest = {
            "dependencies": [
                {
                    "licenses": [{"destination": "licenses/example.txt"}],
                    "outputs": {
                        "headers": ["include/example"],
                        "libraries": [
                            {
                                "link_name": "lib/libexample.a",
                                "linkage": "static",
                                "soname": None,
                            }
                        ],
                    },
                }
            ],
            "platform": {
                "architecture": platform.machine(),
                "os": "linux",
                "variant": "build_rl8.10-default",
            },
            "schema": "cubrid-thirdparty-manifest-v1",
        }
        self.manifest_path = root / "share/cubrid-thirdparty/manifest.json"
        self.manifest_path.write_text(json.dumps(self.manifest, sort_keys=True) + "\n")
        self.fingerprint = self._sha256(self.manifest_path)
        self.write_provenance()

    @staticmethod
    def _sha256(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def write_provenance(self, *, revision=None):
        regular_files = []
        symlinks = []
        for path in sorted(self.root.rglob("*")):
            if path.is_symlink():
                symlinks.append(
                    {"path": path.relative_to(self.root).as_posix(), "target": os.readlink(path)}
                )
            elif path.is_file() and path.name != "provenance.json":
                regular_files.append(
                    {"path": path.relative_to(self.root).as_posix(), "sha256": self._sha256(path)}
                )
        provenance = {
            "artifacts": {"regular_files": regular_files, "symlinks": symlinks},
            "platform": {
                "declared": self.manifest["platform"],
                "observed": {"architecture": platform.machine(), "os": "linux"},
            },
            "producer": {"commit": revision or self.revision, "dirty": False},
            "schema": "cubrid-thirdparty-provenance-v1",
            "spec_fingerprint": self.fingerprint,
        }
        (self.root / "share/cubrid-thirdparty/provenance.json").write_text(
            json.dumps(provenance, sort_keys=True) + "\n"
        )

    def persist_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest, sort_keys=True) + "\n")
        self.fingerprint = self._sha256(self.manifest_path)
        self.write_provenance()

    def make_shared_library_chain(self):
        static_library = self.root / "lib/libexample.a"
        static_library.unlink()
        payload = self.root / "lib/libexample.so.2.0.0"
        payload.write_bytes(b"ELF fixture")
        os.symlink("libexample.so.2", self.root / "lib/libexample.so")
        os.symlink(payload.name, self.root / "lib/libexample.so.2")
        library = self.manifest["dependencies"][0]["outputs"]["libraries"][0]
        library.update(
            {
                "link_name": "lib/libexample.so",
                "linkage": "shared",
                "soname": "libexample.so.2",
            }
        )
        self.persist_manifest()


class ValidatePrefixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "prefix"
        self.fixture = PrefixFixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def validate(self):
        VALIDATOR.validate_prefix(
            self.root, self.fixture.revision, self.fixture.fingerprint
        )

    def test_accepts_complete_manifest_derived_inventory(self):
        self.validate()

    def test_rejects_missing_manifest_declared_artifact(self):
        (self.root / "lib/libexample.a").unlink()

        with self.assertRaisesRegex(VALIDATOR.ValidationError, "lib/libexample.a"):
            self.validate()

    def test_rejects_corrupt_manifest_bytes(self):
        with self.fixture.manifest_path.open("a") as manifest_file:
            manifest_file.write(" ")

        with self.assertRaisesRegex(VALIDATOR.ValidationError, "manifest fingerprint"):
            self.validate()

    def test_rejects_wrong_producer_revision(self):
        self.fixture.write_provenance(revision="b" * 40)

        with self.assertRaisesRegex(VALIDATOR.ValidationError, "producer revision"):
            self.validate()

    def test_rejects_corrupt_provenance_inventory(self):
        (self.root / "include/example/example.h").write_text("corrupt\n")

        with self.assertRaisesRegex(VALIDATOR.ValidationError, "artifact digest"):
            self.validate()

    def test_rejects_unrecorded_build_state(self):
        (self.root / "include/Download").mkdir()

        with self.assertRaisesRegex(VALIDATOR.ValidationError, "forbidden build-state"):
            self.validate()

    def test_rejects_provenance_recorded_artifact_not_declared_by_manifest(self):
        (self.root / "lib/unrequested.a").write_bytes(b"not declared")
        self.fixture.write_provenance()

        with self.assertRaisesRegex(VALIDATOR.ValidationError, "manifest inventory mismatch"):
            self.validate()

    def test_rejects_directory_at_static_library_path(self):
        library = self.root / "lib/libexample.a"
        library.unlink()
        library.mkdir()
        self.fixture.write_provenance()

        with self.assertRaisesRegex(VALIDATOR.ValidationError, "static library"):
            self.validate()

    def test_accepts_complete_shared_library_chain_and_soname(self):
        self.fixture.make_shared_library_chain()

        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=" 0x000000000000000e (SONAME) Library soname: [libexample.so.2]\n",
            stderr="",
        )
        with mock.patch.object(VALIDATOR.subprocess, "run", return_value=completed):
            self.validate()

    def test_rejects_shared_library_with_wrong_elf_soname(self):
        self.fixture.make_shared_library_chain()

        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=" 0x000000000000000e (SONAME) Library soname: [libwrong.so.1]\n",
            stderr="",
        )
        with mock.patch.object(VALIDATOR.subprocess, "run", return_value=completed):
            with self.assertRaisesRegex(VALIDATOR.ValidationError, "ELF SONAME"):
                self.validate()

    def test_rejects_manifest_path_escape(self):
        self.fixture.manifest["dependencies"][0]["outputs"]["headers"] = ["../escape"]
        self.fixture.persist_manifest()

        with self.assertRaisesRegex(VALIDATOR.ValidationError, "unsafe manifest path"):
            self.validate()

    def test_rejects_symlink_that_escapes_prefix(self):
        artifact = self.root / "lib/libexample.a"
        artifact.unlink()
        os.symlink("/etc/passwd", artifact)
        self.fixture.write_provenance()

        with self.assertRaisesRegex(VALIDATOR.ValidationError, "escapes prefix"):
            self.validate()

if __name__ == "__main__":
    unittest.main()
