---
status: accepted
---

# Use a CI-image prebuilt third-party prefix

CUBRID's Linux x86_64 `build_rl8.10` CI will consume an expanded third-party prefix baked into the cubridci image instead of rebuilding dependencies or restoring an ExternalProject build-tree archive in each pod. CUBRID source owns a canonical third-party spec manifest and a `cubrid_thirdparty_prefix` producer target; the image builds that target from an immutable `CUBRID_3RDPARTY_REVISION`, retains only consumable headers, libraries, metadata, and licenses, and exposes the result through `CUBRID_3RDPARTY_MODE=CI_PREBUILT` and `CUBRID_3RDPARTY_ROOT`.

## Considered Options

- A shared compressed ExternalProject tree avoids recompilation but still requires per-pod transfer and extraction, preserves path-dependent build state, and needs archive publication logic.
- Distribution packages do not reliably preserve CUBRID's exact dependency versions, patches, linkage, and build options.
- An expanded image-owned prefix removes third-party network and build work from the pod while making third-party changes an explicit image-build event.

## Consequences

- CMake compares the source manifest's canonical SHA-256 with the image prefix and fails without fallback when the prefix, a required file, or the fingerprint differs.
- The image records toolchain, base-image, architecture, image, and producer-revision provenance separately from the source-to-image spec fingerprint.
- Release and OptDebug initially share one prefix, and existing linkage remains unchanged, including unixODBC's shared linkage.
- Builds without `CI_PREBUILT` retain the current ExternalProject behavior.
- Image tagging and rollout coordination remain an operational decision outside this ADR.
- The previous ccache-independent zstd archive, shared archive directory, and publish/restore design is not retained.
