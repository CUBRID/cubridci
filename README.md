[![image size](https://img.shields.io/docker/image-size/cubridci/cubridci/build_cl6.10?label=image%20size)](https://hub.docker.com/r/cubridci/cubridci/tags?name=build_cl6.10)

# CUBRID build image — CentOS 6.10

This branch defines `cubridci/cubridci:build_cl6.10`, the image that compiles CUBRID.
It is **build-only**: no CTP, no test cases, no test tooling. To run tests, use the
[`test_rl8.10`](https://github.com/CUBRID/cubridci/tree/test_rl8.10) branch and its image.

The image definition is `docker/ci/` — `Dockerfile` and `docker-entrypoint.sh`.

## The tag

Jenkins multibranch on `ci.cubrid.org` builds `docker/ci` on every push to this branch and
pushes the result as `cubridci/cubridci:build_cl6.10`. The tag appears on Docker Hub about a
minute after the push. A new branch needs no job registration — Jenkins picks it up on its own.
Jenkins itself is reachable only from the internal network.

|            |                                                                                  |
| ---------- | -------------------------------------------------------------------------------- |
| Base       | `centos:6.10`; packages from `vault.centos.org`                                  |
| Size       | 1.63 GB on disk, 758 MB to pull                                                   |
| Toolchain  | gcc/g++ 8.3.1 and make from devtoolset-8, git 2.12 from sclo-git212, cmake 3.26.3, ninja 1.11.1, bison 3.0.5, flex, ant, ccache 3.7.7 |
| JDK        | Temurin 8u442-b06 at `/opt/jdk8` (`JAVA_HOME`); `ant` pulls in `java-1.7.0-openjdk-devel`, which is `/usr/bin/java` and where `find_package(JNI)` finds the headers, as in the `develop` image |
| Locale, TZ | `en_US`, `Asia/Seoul`                                                             |

`CC` and `CXX` are preset to `ccache gcc` and `ccache g++`.

devtoolset-8 and sclo-git212 are on `PATH` through the image environment rather than
`scl enable`, so a shell that skips the profile — a GitHub Actions `container:` step — gets
them too.

Four tools come from upstream instead of a repository: cmake, because base carries only 2.8.12;
bison, because base carries only 2.4.1 and the parser needs 3.x; ninja, which base does not
carry; and ccache, because EPEL 6 carries only 3.1.6, which compiles the preprocessed source
and so loses the `/* fall through */` comments that `-Werror=implicit-fallthrough` relies on.

## Usage

The entrypoint takes a verb. Anything that is not a verb runs as a command.

```
/entrypoint.sh checkout [<ref>]
/entrypoint.sh [build] [<build.sh args>...]   # build is the default verb
/entrypoint.sh dist [<build.sh args>...]
/entrypoint.sh coverage [<build.sh args>...]
/entrypoint.sh <command> [<args>...]
```

`build`, `dist` and `coverage` look for `build.sh` in the working directory, then in `cubrid/`,
and run `./build.sh -p $CUBRID <args> clean build` or `./build.sh -p $CUBRID <args> dist`. Extra
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
  cubridci/cubridci:build_cl6.10 checkout
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
  cubridci/cubridci:build_cl6.10 \
  bash -lc '/entrypoint.sh checkout && /entrypoint.sh build'
```

`MAKEFLAGS=-j` is what the CUBRID `Jenkinsfile` passes.

With source you already have on the host, mount it and skip `checkout`:

```bash
docker run --rm \
  -v "$PWD/cubrid:/home/cubrid" \
  -e MAKEFLAGS=-j \
  cubridci/cubridci:build_cl6.10 build
```

git here is 2.12, older than the ownership check git 2.35.2 added, so a mounted tree reads as
it is, whoever owns it, and needs no `safe.directory`.

An unreadable history — a tree checked out with `BUILD_MIRROR` and built without that mirror —
stops at a guard before the build, which quotes git. Its hint about `safe.directory` is shared
with `build_rl8.10` and does not apply here.

To pack release artifacts as well:

```bash
docker run --rm \
  -v "$PWD/workspace:/home" \
  -v "$PWD/packages:/packages" \
  cubridci/cubridci:build_cl6.10 dist -o /packages
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
  cubridci/cubridci:build_cl6.10 \
  bash -lc '/entrypoint.sh checkout && /entrypoint.sh coverage'
```

| Archive                                         | Holds                                          |
| ----------------------------------------------- | ---------------------------------------------- |
| `CUBRID-<version>-gcov-Linux.x86_64.tar.gz`     | the install tree, top-level directory `CUBRID` |
| `cubrid-<version>-gcov-src-Linux.x86_64.tar.gz` | the source tree with the `.gcno` and the objects, top-level directory `cubrid` |

The nightly regression builds it the same way — CTP's `common/ext/run_coverage.sh` runs
`build.sh -m coverage` — and packages it with two plain `tar` calls, which is what this does.
`dist` cannot package it and is not the thing to fix: it refuses `-m coverage` outright, and its
source package is built from `git ls-files`, which by construction leaves out both the `.gcno`
files and the build directory `.gitignore` hides.

**Unpack the source archive on the test node so its tree lands at the path it was built at.**
The `.gcda` paths are compiled into the binaries. The build and test images both work under
`/home`, so a `checkout` here and a `tar -C /home -xzf <source archive>` there line up exactly,
and lcov then needs neither `GCOV_PREFIX` nor `geninfo_adjust_src_path`. `coverage` prints the
path it built at and the `tar` line to use.

The names are the nightly's; the layout is not. It tars the trees from the inside, with no
top-level directory, and `run_cubrid_install` unpacks them into a `cubrid-<build id>` of its own
making. Keeping the tree's real directory name instead is what lets the paths line up. The
consumer here is the test image, not that installer.

`GCOV_OUTPUT_DIR` has to be outside the source tree — tar cannot archive a directory it is
writing into. The default working directory `/home` is fine, since the tree sits at
`/home/cubrid`; a source tree mounted at `/home` itself needs this set somewhere else.

Leave room on whatever volume `$GCOV_OUTPUT_DIR` points at. A full `develop` build on
`build_rl8.10` measured 241 MB for the install archive and 1.1 GB for the source one, from a
3.3 GB tree; the object files are 1.3 GB of that and the `.gcno` only 222 MB. The build itself
took about 2.5 hours at `CMAKE_BUILD_PARALLEL_LEVEL=32`, most of it the third-party
dependencies, which build serially.

### Parallelism on a memory-tight host

`cc1plus` needs roughly 1 GB per compile job. An unbounded `-j` on a host or cgroup with only
a few GB gets the compiler OOM-killed part way through the build. Cap the job count instead —
`build.sh` drives the build through cmake, so `CMAKE_BUILD_PARALLEL_LEVEL` applies to both the
ninja and the make generator:

```bash
docker run --rm \
  -v "$PWD/workspace:/home" \
  -e CMAKE_BUILD_PARALLEL_LEVEL=4 \
  cubridci/cubridci:build_cl6.10 build
```

One job per GB of memory available to the container is a safe starting point.
