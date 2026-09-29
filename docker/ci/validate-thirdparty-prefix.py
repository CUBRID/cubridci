#!/usr/bin/env python3
"""Validate a baked CUBRID third-party prefix before invoking build.sh."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import subprocess
import sys


REVISION_PATTERN = re.compile(r"^[0-9a-f]{40}$")
FINGERPRINT_PATTERN = re.compile(r"^[0-9a-f]{64}$")
ALLOWED_TOP_LEVEL = {"include", "lib", "licenses", "share"}
FORBIDDEN_DIRECTORIES = {"Build", "Download", "Source", "Stamp", "CMakeFiles"}
FORBIDDEN_FILES = {".ninja_deps", ".ninja_log", "CMakeCache.txt"}
FORBIDDEN_SUFFIXES = {".lo", ".o", ".obj"}


class ValidationError(Exception):
    pass


def _sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as input_file:
        for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_json(path, description):
    try:
        with path.open(encoding="utf-8") as input_file:
            value = json.load(input_file)
    except (OSError, UnicodeError, ValueError) as error:
        raise ValidationError("invalid {0}: {1}".format(description, error))
    if not isinstance(value, dict):
        raise ValidationError("invalid {0}: top level must be an object".format(description))
    return value


def _safe_relative_path(value, description):
    if not isinstance(value, str) or not value:
        raise ValidationError("unsafe manifest path for {0}: {1!r}".format(description, value))
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or not path.parts
        or ".." in path.parts
        or path.parts[0] not in ALLOWED_TOP_LEVEL
    ):
        raise ValidationError("unsafe manifest path for {0}: {1}".format(description, value))
    return path


def _inside(root, path):
    try:
        return os.path.commonpath((str(root), str(path))) == str(root)
    except ValueError:
        return False


def _resolved_artifact(root, relative, description):
    path = root.joinpath(*relative.parts)
    if not os.path.lexists(str(path)):
        raise ValidationError("missing manifest artifact {0}: {1}".format(description, relative))
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ValidationError(
            "invalid manifest artifact {0} ({1}): {2}".format(description, relative, error)
        )
    if not _inside(root, resolved):
        raise ValidationError("manifest artifact escapes prefix: {0}".format(relative))
    return path


def _relative_to_root(root, path):
    return path.relative_to(root).as_posix()


def _require_regular_nonempty(root, path, description):
    try:
        mode = path.lstat().st_mode
    except OSError as error:
        raise ValidationError("missing {0}: {1}".format(description, error))
    if not stat.S_ISREG(mode) or path.stat().st_size == 0:
        raise ValidationError("{0} must be a non-empty regular file: {1}".format(description, path))
    if not _inside(root, path.resolve(strict=True)):
        raise ValidationError("{0} escapes prefix: {1}".format(description, path))


def _header_inventory(root, relative):
    path = _resolved_artifact(root, relative, "header")
    mode = path.lstat().st_mode
    if stat.S_ISREG(mode):
        _require_regular_nonempty(root, path, "manifest header")
        return {_relative_to_root(root, path)}
    if not stat.S_ISDIR(mode):
        raise ValidationError("manifest header must be a regular file or directory: {0}".format(relative))

    inventory = set()
    for candidate in path.rglob("*"):
        candidate_mode = candidate.lstat().st_mode
        if stat.S_ISDIR(candidate_mode):
            continue
        _require_regular_nonempty(root, candidate, "manifest header")
        inventory.add(_relative_to_root(root, candidate))
    if not inventory:
        raise ValidationError("empty manifest header directory: {0}".format(relative))
    return inventory


def _shared_library_inventory(root, relative, expected_soname):
    if relative.parts[0] != "lib":
        raise ValidationError("shared library must be under lib/: {0}".format(relative))
    if (
        not isinstance(expected_soname, str)
        or not expected_soname
        or PurePosixPath(expected_soname).name != expected_soname
    ):
        raise ValidationError("shared library has invalid SONAME: {0}".format(expected_soname))

    link_path = root.joinpath(*relative.parts)
    if not link_path.is_symlink():
        raise ValidationError("shared library link must be a symlink: {0}".format(relative))

    library_root = (root / "lib").resolve(strict=True)
    current = link_path
    inventory = set()
    seen = set()
    saw_soname_link = False
    for _ in range(32):
        current_string = str(current)
        if current_string in seen:
            raise ValidationError("shared library symlink chain is cyclic: {0}".format(relative))
        seen.add(current_string)
        if not current.is_symlink():
            break
        inventory.add(_relative_to_root(root, current))
        saw_soname_link = saw_soname_link or current.name == expected_soname
        target = os.readlink(current_string)
        if os.path.isabs(target):
            raise ValidationError("shared library symlink target must be relative: {0}".format(current))
        current = Path(os.path.abspath(os.path.join(str(current.parent), target)))
        if not _inside(library_root, current):
            raise ValidationError("shared library symlink escapes lib/: {0}".format(relative))
    else:
        raise ValidationError("shared library symlink chain is too deep: {0}".format(relative))

    if not saw_soname_link:
        raise ValidationError(
            "shared library chain does not contain SONAME link {0}: {1}".format(
                expected_soname, relative
            )
        )
    _require_regular_nonempty(root, current, "shared library payload")
    if not _inside(library_root, current.resolve(strict=True)):
        raise ValidationError("shared library payload escapes lib/: {0}".format(relative))
    inventory.add(_relative_to_root(root, current))

    try:
        result = subprocess.run(
            ["readelf", "-d", str(current)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )
    except OSError as error:
        raise ValidationError("cannot inspect shared library ELF SONAME: {0}".format(error))
    match = re.search(r"\(SONAME\)[^\n]*\[([^]]+)\]", result.stdout)
    actual_soname = match.group(1) if match else None
    if result.returncode != 0 or actual_soname != expected_soname:
        raise ValidationError(
            "shared library ELF SONAME mismatch for {0}: expected {1}, got {2}".format(
                relative, expected_soname, actual_soname
            )
        )
    return inventory


def _manifest_inventory(root, manifest):
    dependencies = manifest.get("dependencies")
    if not isinstance(dependencies, list) or not dependencies:
        raise ValidationError("invalid manifest: dependencies must be a non-empty array")

    inventory = {"share/cubrid-thirdparty/manifest.json"}
    for dependency_index, dependency in enumerate(dependencies):
        if not isinstance(dependency, dict):
            raise ValidationError("invalid manifest dependency at index {0}".format(dependency_index))
        outputs = dependency.get("outputs")
        licenses = dependency.get("licenses")
        if not isinstance(outputs, dict) or not isinstance(licenses, list):
            raise ValidationError("invalid manifest outputs/licenses at index {0}".format(dependency_index))

        headers = outputs.get("headers")
        libraries = outputs.get("libraries")
        if not isinstance(headers, list) or not isinstance(libraries, list):
            raise ValidationError("invalid manifest output inventory at index {0}".format(dependency_index))

        for header_index, header in enumerate(headers):
            relative = _safe_relative_path(
                header, "dependencies[{0}].outputs.headers[{1}]".format(dependency_index, header_index)
            )
            inventory.update(_header_inventory(root, relative))

        for library_index, library in enumerate(libraries):
            if not isinstance(library, dict):
                raise ValidationError("invalid manifest library at index {0}".format(library_index))
            relative = _safe_relative_path(
                library.get("link_name"),
                "dependencies[{0}].outputs.libraries[{1}].link_name".format(
                    dependency_index, library_index
                ),
            )
            if relative.parts[0] != "lib":
                raise ValidationError("manifest library must be under lib/: {0}".format(relative))
            path = _resolved_artifact(root, relative, "library")
            linkage = library.get("linkage")
            soname = library.get("soname")
            if linkage == "static":
                if soname is not None:
                    raise ValidationError("static library SONAME must be null: {0}".format(relative))
                _require_regular_nonempty(root, path, "static library")
                inventory.add(str(relative))
            elif linkage == "shared":
                inventory.update(_shared_library_inventory(root, relative, soname))
            else:
                raise ValidationError("unsupported manifest library linkage: {0}".format(linkage))

        for license_index, license_entry in enumerate(licenses):
            if not isinstance(license_entry, dict):
                raise ValidationError("invalid manifest license at index {0}".format(license_index))
            relative = _safe_relative_path(
                license_entry.get("destination"),
                "dependencies[{0}].licenses[{1}].destination".format(
                    dependency_index, license_index
                ),
            )
            path = _resolved_artifact(root, relative, "license")
            _require_regular_nonempty(root, path, "manifest license")
            inventory.add(str(relative))
    return inventory


def _validate_recorded_inventory(root, provenance):
    artifacts = provenance.get("artifacts")
    if not isinstance(artifacts, dict):
        raise ValidationError("invalid provenance: missing artifact inventory")
    regular_files = artifacts.get("regular_files")
    symlinks = artifacts.get("symlinks")
    if not isinstance(regular_files, list) or not isinstance(symlinks, list):
        raise ValidationError("invalid provenance: malformed artifact inventory")

    recorded = set()
    for entry in regular_files:
        if not isinstance(entry, dict):
            raise ValidationError("invalid provenance regular-file entry")
        relative = _safe_relative_path(entry.get("path"), "provenance regular file")
        relative_string = str(relative)
        if relative_string in recorded:
            raise ValidationError("duplicate provenance artifact: {0}".format(relative))
        recorded.add(relative_string)
        path = root.joinpath(*relative.parts)
        try:
            mode = path.lstat().st_mode
        except OSError:
            raise ValidationError("missing recorded artifact: {0}".format(relative))
        if not stat.S_ISREG(mode) or path.stat().st_size == 0:
            raise ValidationError("recorded artifact is not a non-empty regular file: {0}".format(relative))
        if not _inside(root, path.resolve(strict=True)):
            raise ValidationError("recorded artifact escapes prefix: {0}".format(relative))
        expected_digest = entry.get("sha256")
        if not isinstance(expected_digest, str) or not FINGERPRINT_PATTERN.match(expected_digest):
            raise ValidationError("invalid artifact digest in provenance: {0}".format(relative))
        actual_digest = _sha256(path)
        if actual_digest != expected_digest:
            raise ValidationError(
                "artifact digest mismatch for {0}: expected {1}, got {2}".format(
                    relative, expected_digest, actual_digest
                )
            )

    for entry in symlinks:
        if not isinstance(entry, dict):
            raise ValidationError("invalid provenance symlink entry")
        relative = _safe_relative_path(entry.get("path"), "provenance symlink")
        relative_string = str(relative)
        if relative_string in recorded:
            raise ValidationError("duplicate provenance artifact: {0}".format(relative))
        recorded.add(relative_string)
        path = root.joinpath(*relative.parts)
        if not path.is_symlink():
            raise ValidationError("missing recorded symlink: {0}".format(relative))
        target = entry.get("target")
        if not isinstance(target, str) or os.path.isabs(target) or os.readlink(str(path)) != target:
            raise ValidationError("invalid recorded symlink target: {0}".format(relative))
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise ValidationError("invalid recorded symlink {0}: {1}".format(relative, error))
        if not _inside(root, resolved):
            raise ValidationError("recorded symlink escapes prefix: {0}".format(relative))

    provenance_relative = "share/cubrid-thirdparty/provenance.json"
    actual = set()
    for path in root.rglob("*"):
        if path.is_symlink() or path.is_file():
            relative = path.relative_to(root).as_posix()
            if relative != provenance_relative:
                actual.add(relative)
    if actual != recorded:
        missing = sorted(recorded - actual)
        unrecorded = sorted(actual - recorded)
        raise ValidationError(
            "provenance inventory mismatch: missing={0}, unrecorded={1}".format(missing, unrecorded)
        )
    return recorded


def _validate_layout(root):
    top_level = {path.name for path in root.iterdir()}
    if top_level != ALLOWED_TOP_LEVEL:
        raise ValidationError(
            "invalid prefix top-level layout: expected {0}, got {1}".format(
                sorted(ALLOWED_TOP_LEVEL), sorted(top_level)
            )
        )
    for path in root.rglob("*"):
        if path.is_dir() and path.name in FORBIDDEN_DIRECTORIES:
            raise ValidationError("forbidden build-state directory in prefix: {0}".format(path))
        if path.is_file() and (
            path.name in FORBIDDEN_FILES or path.suffix in FORBIDDEN_SUFFIXES
        ):
            raise ValidationError("forbidden build-state file in prefix: {0}".format(path))


def validate_prefix(root, expected_revision, expected_fingerprint):
    root = Path(root)
    if not REVISION_PATTERN.match(expected_revision or ""):
        raise ValidationError("expected revision must be a full lowercase 40-character SHA")
    if not FINGERPRINT_PATTERN.match(expected_fingerprint or ""):
        raise ValidationError("expected fingerprint must be a lowercase SHA-256")
    if not root.is_absolute() or not root.is_dir():
        raise ValidationError("prefix root must be an absolute directory: {0}".format(root))
    root = root.resolve(strict=True)

    _validate_layout(root)
    manifest_path = root / "share/cubrid-thirdparty/manifest.json"
    provenance_path = root / "share/cubrid-thirdparty/provenance.json"
    if not manifest_path.is_file() or manifest_path.stat().st_size == 0:
        raise ValidationError("missing prefix manifest: {0}".format(manifest_path))
    if not provenance_path.is_file() or provenance_path.stat().st_size == 0:
        raise ValidationError("missing prefix provenance: {0}".format(provenance_path))

    actual_fingerprint = _sha256(manifest_path)
    if actual_fingerprint != expected_fingerprint:
        raise ValidationError(
            "manifest fingerprint mismatch: expected {0}, got {1}".format(
                expected_fingerprint, actual_fingerprint
            )
        )
    manifest = _load_json(manifest_path, "manifest")
    provenance = _load_json(provenance_path, "provenance")
    if manifest.get("schema") != "cubrid-thirdparty-manifest-v1":
        raise ValidationError("unsupported manifest schema: {0}".format(manifest.get("schema")))
    if provenance.get("schema") != "cubrid-thirdparty-provenance-v1":
        raise ValidationError("unsupported provenance schema: {0}".format(provenance.get("schema")))
    if provenance.get("spec_fingerprint") != expected_fingerprint:
        raise ValidationError("provenance fingerprint does not match expected fingerprint")

    producer = provenance.get("producer")
    if not isinstance(producer, dict) or producer.get("commit") != expected_revision:
        raise ValidationError("provenance producer revision does not match image revision")
    if producer.get("dirty") is not False:
        raise ValidationError("provenance producer must be a clean source revision")

    manifest_platform = manifest.get("platform")
    provenance_platform = provenance.get("platform")
    if not isinstance(manifest_platform, dict) or not isinstance(provenance_platform, dict):
        raise ValidationError("missing manifest/provenance platform metadata")
    if provenance_platform.get("declared") != manifest_platform:
        raise ValidationError("provenance declared platform does not match manifest")
    observed = provenance_platform.get("observed")
    if not isinstance(observed, dict):
        raise ValidationError("missing observed platform metadata")
    if observed.get("os") != "linux" or observed.get("architecture") != platform.machine():
        raise ValidationError("provenance observed platform does not match running image")

    manifest_inventory = _manifest_inventory(root, manifest)
    recorded_inventory = _validate_recorded_inventory(root, provenance)
    if recorded_inventory != manifest_inventory:
        missing = sorted(manifest_inventory - recorded_inventory)
        unexpected = sorted(recorded_inventory - manifest_inventory)
        raise ValidationError(
            "manifest inventory mismatch: missing={0}, unexpected={1}".format(
                missing, unexpected
            )
        )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--fingerprint", required=True)
    arguments = parser.parse_args(argv)
    try:
        validate_prefix(Path(arguments.root), arguments.revision, arguments.fingerprint)
    except ValidationError as error:
        print("[ci-prebuilt-3rdparty] error: {0}".format(error), file=sys.stderr)
        return 1
    print(
        "[ci-prebuilt-3rdparty] validated root={0} producer={1} fingerprint={2}".format(
            arguments.root, arguments.revision, arguments.fingerprint
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
