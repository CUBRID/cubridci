[![image size](https://img.shields.io/docker/image-size/cubridci/cubridci/build_rl8.10?label=image%20size)](https://hub.docker.com/r/cubridci/cubridci/tags?name=build_rl8.10)

# CUBRID build image — Rocky Linux 8.10

This branch defines `cubridci/cubridci:build_rl8.10`, the image that compiles CUBRID.
It is **build-only**: no CTP, no test cases, no test tooling. To run tests, use the
[`test_rl8.10`](https://github.com/CUBRID/cubridci/tree/test_rl8.10) branch and its image.

The image definition is `docker/ci/` — `Dockerfile` and `docker-entrypoint.sh`.

## The tag

Jenkins multibranch on `ci.cubrid.org` builds `docker/ci` on every push to this branch and
pushes the result as `cubridci/cubridci:build_rl8.10`. The tag appears on Docker Hub about a
minute after the push. A new branch needs no job registration — Jenkins picks it up on its own.
Jenkins itself is reachable only from the internal network.

|            |                                                                                  |
| ---------- | -------------------------------------------------------------------------------- |
| Base       | `rockylinux/rockylinux:8.10`                                                      |
| Size       | 1.02 GB on disk, 342 MiB to pull                                                  |
| Toolchain  | gcc/g++ and make from the Rocky 8 appstream, cmake, ninja 1.11.1, bison 3.0.5, flex, ant, ccache |
| JDK        | Temurin 8u442-b06 at `/opt/jdk8` (`JAVA_HOME`); `java-1.8.0-openjdk-devel` is also installed because `find_package(JNI)` looks under `/usr/lib/jvm` |
| Python     | `python2-devel` and `python3-devel`                                               |
| Locale, TZ | `en_US`, `Asia/Seoul`                                                             |

`CC` and `CXX` are preset to `ccache gcc` and `ccache g++`.

Two dependencies are built from source instead of installed from a repository: bison, because
appstream carries only 3.0.4 and the parser needs 3.x, and ninja, because powertools carries
only 1.8.2.

## Usage

The entrypoint takes a verb. Anything that is not a verb runs as a command.

```
/entrypoint.sh checkout [<ref>]
/entrypoint.sh [build] [<build.sh args>...]   # build is the default verb
/entrypoint.sh dist [<build.sh args>...]
/entrypoint.sh coverage [<build.sh args>...]
/entrypoint.sh <command> [<args>...]
```

`build` and `dist` look for `build.sh` in the working directory, then in `cubrid/`, and run
`./build.sh -p $CUBRID <args> clean build` or `./build.sh -p $CUBRID <args> dist`. Extra
arguments pass straight through to `build.sh`; run `./build.sh -h` for the list.

|              |                                                                            |
| ------------ | -------------------------------------------------------------------------- |
| Source tree  | `checkout` puts it in `./cubrid`; mounting your own at `/home/cubrid` also works |
| Install tree | `$CUBRID` = `/home/CUBRID`                                                 |
| Packages     | `dist -o <dir>` writes the packages into `<dir>`                            |
| gcov archives| `coverage` writes them into `$GCOV_OUTPUT_DIR` (default: the working directory) |
| Logs         | `build.log` and `dist.log` in the working directory                        |

The exit code is 0 on success and non-zero on failure. On a build failure the last 500 lines of
`build.log` are printed.

### checkout

`checkout` clones CUBRID and its three submodules into `./cubrid`, relative to the working
directory, which is where `build` looks second. Bring your own source instead if you prefer —
mount it and skip this verb. CI usually does, because the pipeline checks the source out before
the container starts.

|             |                                                                            |
| ----------- | -------------------------------------------------------------------------- |
| Which ref   | the argument, else `$CUBRID_REF`, else `develop`. A branch, a tag or a full 40-character SHA. |
| Submodules  | all three, at the commits the ref pins                                      |
| Re-running  | idempotent — it fetches, resets hard, and cleans the tree and the submodules |
| On failure  | five attempts with a growing delay, then exit 1                             |

```bash
/entrypoint.sh checkout                                           # develop
/entrypoint.sh checkout release/11.4                              # a branch
/entrypoint.sh checkout v11.4.5                                   # a tag
/entrypoint.sh checkout 138f4881243f4dfe107bf5e11969979b7fd5c33f  # a commit
```

**The clone is never shallow.** `build.sh` reads the build serial off
`git rev-list --count HEAD`, so a `--depth 1` tree stamps every package `0001`. A full clone
gives the real number — `11.5.0.2496-138f488`.

### Reusing a local mirror

Set `BUILD_MIRROR` to a directory of bare clones and `checkout` borrows their objects with
`git clone --shared` instead of pulling ~471 MB over the network. The mirror is only ever read.

```bash
docker run --rm \
  -v /home/build-cache/cubrid-mirror:/mirror:ro \
  -e BUILD_MIRROR=/mirror \
  cubridci/cubridci:build_rl8.10 checkout
```

`BUILD_MIRROR` set with no mirror there is an error, not a fallback — a silent 471 MB clone
would hide the missing mount. Submodules are borrowed only where the mirror already holds the
pinned commit; one bumped after the mirror was seeded comes from GitHub.

**A borrowed tree needs the mirror on every later run.** `--shared` records the mirror in
`.git/objects/info/alternates`, so the history is only readable while it stays mounted. Without
it `build.sh` cannot count the commits, swallows the error, and stamps the package
`11.5.0.-<hash>` — so `build` and `dist` check the history first and refuse to start rather than
producing that quietly. Mount the mirror for the build too, or check out without one.

### Run a container

Check the source out and build it, keeping both in a mounted workspace:

```bash
docker run --rm \
  -v "$PWD/workspace:/home" \
  -e MAKEFLAGS=-j \
  cubridci/cubridci:build_rl8.10 \
  bash -lc '/entrypoint.sh checkout && /entrypoint.sh build'
```

`MAKEFLAGS=-j` is what the CUBRID `Jenkinsfile` passes.

With source you already have on the host, mount it and skip `checkout`:

```bash
docker run --rm \
  -v "$PWD/cubrid:/home/cubrid" \
  -e MAKEFLAGS=-j \
  -e GIT_CONFIG_COUNT=1 \
  -e GIT_CONFIG_KEY_0=safe.directory \
  -e GIT_CONFIG_VALUE_0='*' \
  cubridci/cubridci:build_rl8.10 build
```

The `safe.directory` variables matter whenever the source comes from a bind mount. The
container runs as root and the tree belongs to your host user, so git calls it dubious
ownership and refuses to read it — which stops the build outright, since `build` counts the
commits before it starts. A tree that `checkout` created inside the container is root-owned
already and needs none of this.

An unreadable history — from this or from a missing mirror — stops at the same guard, which
quotes git and names both causes:

```
** ERROR: cannot walk the history of cubrid; the build number would be empty.
   git: fatal: detected dubious ownership in repository at '/home/cubrid'
   ...
   A tree checked out with BUILD_MIRROR needs that mirror mounted here too.
   A bind-mounted tree owned by another user needs safe.directory.
```

To pack release artifacts as well:

```bash
docker run --rm \
  -v "$PWD/workspace:/home" \
  -v "$PWD/packages:/packages" \
  cubridci/cubridci:build_rl8.10 dist -o /packages
```

### Coverage builds

`coverage` makes a `-m coverage` build and packs the two archives the
[code coverage guide](https://github.com/CUBRID/cubrid-testtools/blob/develop/doc/code_coverage_guide.md)
asks for. `-m coverage` is forced, so anything else the caller passes for `-m` is overridden.

```bash
docker run --rm \
  -v "$PWD/workspace:/home" \
  -v "$PWD/gcov:/gcov" \
  -e GCOV_OUTPUT_DIR=/gcov \
  cubridci/cubridci:build_rl8.10 \
  bash -lc '/entrypoint.sh checkout && /entrypoint.sh coverage'
```

| Archive                                         | Holds                                          |
| ----------------------------------------------- | ---------------------------------------------- |
| `CUBRID-<version>-gcov-Linux.x86_64.tar.gz`     | the install tree, top-level directory `CUBRID` |
| `cubrid-<version>-gcov-src-Linux.x86_64.tar.gz` | the source tree with the `.gcno` and the objects, top-level directory `cubrid` |

`dist` cannot do this, and is not the thing to fix. It refuses `-m coverage` outright, and its
source package is built from `git ls-files`, which by construction leaves out both the `.gcno`
files and the build directory `.gitignore` hides. The nightly regression does not use `build.sh`
for it either — `run_coverage.sh` in `cubrid-testtools-internal` just tars the two trees.

**Unpack the source archive on the test node so its tree lands at the path it was built at.**
The `.gcda` paths are compiled into the binaries. The build and test images both work under
`/home`, so a `checkout` here and a `tar -C /home -xzf <source archive>` there line up exactly,
and lcov then needs neither `GCOV_PREFIX` nor `geninfo_adjust_src_path`. `coverage` prints the
path it built at and the `tar` line to use. The archive keeps the tree's own directory name
rather than the guide's `cubrid-<build id>`, precisely so the paths can line up.

`GCOV_OUTPUT_DIR` has to be outside the source tree — tar cannot archive a directory it is
writing into. The default working directory `/home` is fine, since the tree sits at
`/home/cubrid`; a source tree mounted at `/home` itself needs this set somewhere else.

Coverage objects are much bigger than release ones, and the source archive carries the whole
build directory, so leave room for it on whatever volume `$GCOV_OUTPUT_DIR` points at.

### Parallelism on a memory-tight host

`cc1plus` needs roughly 1 GB per compile job. An unbounded `-j` on a host or cgroup with only
a few GB gets the compiler OOM-killed part way through the build. Cap the job count instead —
`build.sh` drives the build through cmake, so `CMAKE_BUILD_PARALLEL_LEVEL` applies to both the
ninja and the make generator:

```bash
docker run --rm \
  -v "$PWD/workspace:/home" \
  -e CMAKE_BUILD_PARALLEL_LEVEL=4 \
  cubridci/cubridci:build_rl8.10 build
```

One job per GB of memory available to the container is a safe starting point.
