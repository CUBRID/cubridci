# Prototype proposal: immutable CUBRID third-party archives

> **PROTOTYPE — NOT FOR MERGE OR PRODUCTION USE**
>
> This proposal gives `@tw-kang` a concrete starting point for discussion. It does not change the image, entrypoint,
> Jenkins job, or Kubernetes deployment. Production work should be split and implemented under a valid CUBRIDQA ticket.

Target branch: `build_rl8.10`

Target revision inspected: `4ea4e8a714078e11002d9402b9011e647c473bea`

## Question

Can CI preserve CUBRID's completed `build_<target>_<mode>/3rdparty/` tree between Kubernetes pods, while keeping each
pod's writable build tree isolated and preserving the existing clean first-party build?

Open [`prototypes/thirdparty-archive-protocol.html`](../../prototypes/thirdparty-archive-protocol.html) in a browser to
exercise the suggested disabled, configuration-error, hit, miss, corrupt-entry, publisher, and publication-race states.

## Why the rebuild happens

The image entrypoint currently runs:

```sh
./build.sh -p "$CUBRID" "$@" clean build
```

`build.sh clean` removes the complete build directory. CUBRID puts the ExternalProject downloads, extracted sources,
build trees, installed headers and libraries, and completion stamps below that directory's `3rdparty/` subtree. Once
the stamps and outputs are gone, the next build downloads and rebuilds the dependencies.

This proposal preserves the current third-party outputs rather than replacing their build commands. Most compiled
dependencies are already static archives; unixODBC remains the existing shared-library exception.

## Suggested interface

Use archive terminology so this feature is not confused with `ccache`:

```text
CUBRID_3RDPARTY_ARCHIVE_DIR=/mounted/shared/cubrid-3rdparty
CUBRID_3RDPARTY_ARCHIVE_PUBLISH=true   # trusted producer only
```

- An unset archive directory disables the feature and preserves today's behavior.
- A declared directory that is missing or unreadable is a configuration error.
- A normal build is a read-only consumer.
- Exact `CUBRID_3RDPARTY_ARCHIVE_PUBLISH=true` grants publication authority to a trusted job.
- Do not reuse the existing generic `CACHE_WRITE` variable; it is currently associated with `ccache` and would blur
  two independent storage mechanisms.

Suggested entry layout:

```text
<archive-dir>/v1/<content-key>/
├── manifest.txt
├── thirdparty.tar.zst
├── thirdparty.tar.zst.sha256
└── complete
```

## Suggested build sequence

```text
compute the content key and validate the declared archive directory
run build.sh clean

if a complete entry has a valid checksum:
    extract build_<target>_<mode>/3rdparty into pod-local storage
else:
    record a miss and continue with an empty local third-party tree

run build.sh build

if the build succeeded, the entry was absent or corrupt, and this job may publish:
    create a uniquely named staging directory in the archive directory
    write the zstd archive, checksum, manifest, and complete marker there
    atomically rename the staging directory to the final content key
```

The outer `tee build.log`/progress filter and its `pipefail` behavior should remain unchanged.

## Why archive the complete subtree

Copying only `lib/*.a` is insufficient. CMake ExternalProject uses completion stamps, and some consumed libraries and
headers live below `Source/` rather than the installed `lib/` and `include/` directories. The bridge therefore needs the
complete `3rdparty/` subtree, including `Download/`, `Source/`, `Build/`, `Stamp/`, installed outputs, and
`CMakeFiles/*-complete`.

Generated ExternalProject files contain absolute paths. Until CUBRID gains a relocatable prebuilt-dependency mode, the
absolute source and build directories must be part of the content key.

## Why zstd instead of gzip

A measured completed third-party tree was roughly 363 MiB before compression. Warm restoration happens much more often
than publication, so decompression latency matters more than maximizing the compression ratio. `zstd` provides much
faster decompression than gzip while still substantially reducing traffic from shared storage. A low setting such as
level 3 also keeps the uncommon publication path fast and avoids replacing compilation time with compression time.

The production change would need to install `zstd` in the image and use an explicit pipeline such as
`tar -cf - ... | zstd -T0 -3`, because the Rocky Linux 8 tar version should not be assumed to provide a native
`--zstd` option.

## Suggested content identity

Do not key on the CUBRID commit: ordinary engine changes should reuse the same third-party entry. Hash a canonical
manifest containing at least:

- archive schema version;
- SHA-256 of `3rdparty/CMakeLists.txt` and third-party patch/build-recipe inputs;
- OS, architecture, libc, compiler target and compiler versions;
- CMake and relevant RPM versions;
- build mode, target, generator, compiler selection, and relevant flags/options;
- absolute source and build paths.

The runtime fingerprint avoids depending on a movable image tag or on an OCI digest that the container cannot reliably
discover about itself.

## Concurrency and trust suggestion

Never mount shared storage directly over a live `build/3rdparty` tree. Each pod restores and builds in pod-local storage.
Shared storage contains immutable archives only.

A publisher writes `.tmp.<key>.<pod-id>/` and renames it only after every file is complete. Readers ignore temporary
directories. Concurrent publishers create independent staging directories; the first successful final rename wins and
losers discard only their own staging output. This avoids locks that can become permanently stale when a pod dies.

This design requires atomic same-filesystem directory rename from the chosen shared filesystem. That property must be
proved against the actual Kubernetes/GlusterFS mount before production rollout.

PR and other untrusted builds should consume archives but never publish them. A dedicated trusted seed or develop job
should publish new content identities.

## Failure and cleanup suggestion

- Missing content key: cold build.
- Bad archive checksum or incomplete entry: warn, ignore it, and cold build.
- Declared archive directory missing or unreadable: fail immediately with a configuration error.
- Publication failure after a successful CUBRID build: warn without changing the build result.
- Entrypoint cleanup: remove only staging data created by the current process.
- Shared retention: a separately authorized infrastructure janitor should enforce quota/age policy and remove abandoned
  temporary or quarantined entries. Ordinary build pods should not delete shared entries.

## Production follow-up for `@tw-kang`

Create appropriately scoped work under a valid CUBRIDQA ticket before implementation. Suggested work breakdown:

1. Confirm the archive mount, capacity, permissions, and per-job environment injection.
2. Prove atomic directory rename and concurrent-reader behavior on the actual GlusterFS/PVC implementation.
3. Finalize publisher authorization and the trusted seed/develop workflow.
4. Implement `build.sh` argument parsing and canonical manifest/key generation.
5. Implement safe archive inspection, checksum verification, extraction, staging, publication, and corruption recovery.
6. Define the external retention/janitor policy.
7. Add an entrypoint harness covering disabled, misconfigured, miss, hit, corruption, read-only, publisher, and race cases.
8. Gate image publication on that harness.
9. Validate real release and optdebug cold/warm builds; prove that warm builds run no third-party download, configure,
   build, or install steps and preserve the expected linkage.

Once those decisions are accepted, record the production architecture in an ADR. This prototype intentionally does not
claim that the storage and concurrency assumptions have been validated.

## Primary-source pointers

- [`docker-entrypoint.sh` at the inspected branch](https://github.com/CUBRID/cubridci/blob/4ea4e8a714078e11002d9402b9011e647c473bea/docker/ci/docker-entrypoint.sh#L116-L140)
- [`build.sh` destructive clean](https://github.com/CUBRID/cubrid/blob/a0026f9293523bed2af4c52d8c7299c6ce9b14d0/build.sh#L162-L186)
- [CUBRID ExternalProject base directory](https://github.com/CUBRID/cubrid/blob/a0026f9293523bed2af4c52d8c7299c6ce9b14d0/3rdparty/CMakeLists.txt#L91-L118)
- [CMake ExternalProject directory layout](https://cmake.org/cmake/help/latest/module/ExternalProject.html#directory-options)
