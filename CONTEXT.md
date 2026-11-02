# CUBRID CI Build Image

Vocabulary for the contract between a CUBRID source checkout and the third-party dependencies supplied by its CI build image.

## Language

**Prebuilt third-party prefix**:
An expanded, directly consumable directory of third-party headers and libraries installed in the CI build image. CUBRID links against it without downloading, copying, extracting, configuring, or compiling those dependencies in the CI pod.
_Avoid_: Third-party cache, third-party archive

**Third-party spec fingerprint**:
The stable identity of the dependency sources, checksums, patches, build options, and linkage settings represented by a prebuilt third-party prefix. Both the CUBRID source checkout and CI build image expose it so a mismatch can fail before compilation; toolchain and base-image identity are recorded separately.
_Avoid_: Cache key, archive version

**Third-party spec manifest**:
The canonical JSON file in CUBRID source that authoritatively declares third-party sources, checksums, patches, build options, linkage settings, schema version, and recipe revision. Its canonical SHA-256 determines the third-party spec fingerprint used by both CUBRID and the CI image builder.
_Avoid_: Duplicated Docker dependency list, manually maintained cache version

**Artifact provenance**:
Diagnostic identity for the environment that produced a prebuilt third-party prefix, including its image digest, architecture, compiler, base image, and producer CUBRID commit. It supports reproduction but is not part of the source-to-image compatibility comparison.
_Avoid_: Third-party spec fingerprint

**Third-party producer revision**:
The immutable full CUBRID commit SHA supplied as `CUBRID_3RDPARTY_REVISION` when the CI image builds its prefix. It identifies the commit that defines the selected manifest and build recipe, not the CUBRID commit currently being tested.
_Avoid_: Current test revision, moving branch, floating tag

**CI-prebuilt third-party mode**:
The explicit CMake mode `CUBRID_3RDPARTY_MODE=CI_PREBUILT`, which requires `CUBRID_3RDPARTY_ROOT` to name a compatible prebuilt third-party prefix. The CI image exports both values; CMake rejects conflicting cache values, a missing prefix or file, and a differing spec fingerprint, and never falls back to building dependencies from source.
_Avoid_: PREBUILT_FOR_CI, cache restore mode, automatic fallback

**Third-party prefix producer**:
The CUBRID build target `cubrid_thirdparty_prefix`, which builds every declared dependency and normalizes only its consumable headers, libraries, manifest, provenance, and licenses into a relocatable prefix for the CI image builder.
_Avoid_: Full ExternalProject build tree, Docker-maintained dependency recipe

**Third-party build variant**:
A distinct prebuilt-prefix build configuration required only when third-party ABI or instrumentation differs. The initial Linux x86_64 `build_rl8.10` integration uses one default variant shared by Release and OptDebug.
_Avoid_: CUBRID build type
