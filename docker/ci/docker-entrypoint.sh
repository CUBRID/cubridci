#!/bin/bash -le
# The log filter below would otherwise mask build.sh's exit code.
set -o pipefail

CUBRID_URL=https://github.com/CUBRID/cubrid.git
CUBRID_SRC=cubrid

# Every stage below reaches the network, and a clone of the full history is big
# enough to fail halfway. The subshell is for the `cd` a stage does, so the next
# attempt starts from the same directory as the first.
#
# Testing a subshell with && switches `set -e` off inside it, for the stage
# function too. Every command in a stage therefore has to carry its own
# `&&` or `|| return`; a bare one would go unnoticed when it fails.
function retry ()
{
  local what=$1 i
  shift
  for i in 1 2 3 4 5; do
    ( "$@" ) && return 0
    if [ $i -lt 5 ]; then
      echo "[warn] $what attempt $i/5 failed; retrying in $((i * 10))s" >&2
      sleep $((i * 10))
    fi
  done
  echo "** ERROR: $what failed after retries" >&2
  exit 1
}

function mirror_of ()
{
  local url=$1
  echo "$BUILD_MIRROR/$(basename "${url%.git}").git"
}

# Never shallow: build.sh reads the build serial off `git rev-list --count`, so a
# shallow clone stamps the package 0001.
function fetch_source ()
{
  local ref=$1

  if [ ! -d "$CUBRID_SRC/.git" ]; then
    if [ -n "$BUILD_MIRROR" ]; then
      # Borrow the history, never write to it: a container dying mid-fetch would
      # leave a .lock behind that stalls every later run.
      git clone -q --shared --no-checkout "$(mirror_of "$CUBRID_URL")" "$CUBRID_SRC" \
        || return 1
    else
      git -c fetch.parallel=0 clone -q --no-checkout "$CUBRID_URL" "$CUBRID_SRC" \
        || return 1
    fi
  fi

  # Fetching the ref by name is what makes a bare commit work and not just a branch.
  cd "$CUBRID_SRC" \
    && git remote set-url origin "$CUBRID_URL" \
    && git -c fetch.parallel=0 fetch -q --no-tags origin "$ref" \
    && git reset -q --hard FETCH_HEAD \
    && git clean -qfdx
}

function fetch_submodules ()
{
  cd "$CUBRID_SRC" \
    && git submodule sync -q \
    && git submodule init -q \
    || return 1

  if [ -n "$BUILD_MIRROR" ]; then
    # Only where the mirror already holds the pinned commit; a submodule bumped
    # after the mirror was seeded still comes from GitHub.
    local sha path url m
    while read -r sha path; do
      url=$(git config -f .gitmodules --get "submodule.${path}.url") || return 1
      m=$(mirror_of "$url")
      if git -C "$m" cat-file -e "${sha}^{commit}" 2> /dev/null; then
        git config "submodule.${path}.url" "$m" || return 1
        echo "[checkout] $path borrowed from the mirror"
      fi
    done < <(git ls-tree HEAD | awk '$2 == "commit" { print $3, $4 }')
  fi

  # A build writes into the submodules, so update cannot move them until the
  # leftovers are gone.
  git submodule foreach -q 'git reset -q --hard && git clean -qfdx' || true
  # git 2.38 stopped cloning a submodule from a local path (CVE-2022-39253).
  git -c protocol.file.allow=always submodule update -q --init --force
}

function run_checkout ()
{
  local ref=${1:-${CUBRID_REF:-develop}} m

  if [ -n "$BUILD_MIRROR" ]; then
    m=$(mirror_of "$CUBRID_URL")
    [ -d "$m" ] \
      || { echo "** ERROR: BUILD_MIRROR is set but $m is not there" >&2; return 1; }
  fi

  retry "checkout of cubrid ($ref)" fetch_source "$ref"
  retry "checkout of the submodules" fetch_submodules

  echo "[checkout] cubrid @ $ref -> $(git -C $CUBRID_SRC rev-parse --verify HEAD)" \
       "($(git -C $CUBRID_SRC rev-list --count HEAD) commits)"
}

# A checkout that borrowed from BUILD_MIRROR reads its history through
# .git/objects/info/alternates, so it needs that mirror on every later run too.
# build.sh swallows the read error and stamps the package 11.5.0.-<hash>, which
# is why this refuses to build rather than warning.
function check_history ()
{
  local dir=$1 err
  [ -d "$dir/.git" ] || return 0
  # git names the real cause; a fixed hint can only guess at one of the two.
  err=$(git -C "$dir" rev-list --count HEAD 2>&1 > /dev/null) && return 0
  echo "** ERROR: cannot walk the history of $dir; the build number would be empty." >&2
  echo "$err" | sed 's/^/   git: /' >&2
  echo "   A tree checked out with BUILD_MIRROR needs that mirror mounted here too." >&2
  echo "   A bind-mounted tree owned by another user needs safe.directory." >&2
  return 1
}

# PROTOTYPE: preserve CMake ExternalProject's complete third-party tree between builds.
# This deliberately lives beside run_build so a follow-up can replace or discard it
# without changing CUBRID's build.sh interface.
function set_thirdparty_build_layout ()
{
  local opt target=x86_64 mode=release source_dir=$PWD build_dir=
  local OPTIND=1

  while getopts ":t:m:g:is:b:p:o:aj:c:C:z:xvh" opt; do
    case "$opt" in
      t) target=$OPTARG ;;
      m) mode=$OPTARG ;;
      s) source_dir=$OPTARG ;;
      b) build_dir=$OPTARG ;;
      g|i|a|p|o|j|c|C|z|x|v|h) ;;
      \?|:)
        echo "[3rdparty-archive] error: cannot derive the build directory from option '-$OPTARG'" >&2
        return 1
        ;;
    esac
  done

  case "$target" in
    i386|x86|32|32bit) target=i386 ;;
    x86_64|x64|64|64bit) target=x86_64 ;;
  esac

  THIRDPARTY_SOURCE_DIR=$(readlink -m "$source_dir") || return 1
  if [ -n "$build_dir" ]; then
    THIRDPARTY_BUILD_DIR=$(readlink -m "$build_dir") || return 1
  else
    THIRDPARTY_BUILD_DIR="$THIRDPARTY_SOURCE_DIR/build_${target}_${mode}"
  fi
}

function thirdparty_archive_manifest ()
{
  local thirdparty_sha packages

  [ -f "$THIRDPARTY_SOURCE_DIR/3rdparty/CMakeLists.txt" ] \
    || { echo "[3rdparty-archive] error: cannot find 3rdparty/CMakeLists.txt under $THIRDPARTY_SOURCE_DIR" >&2; return 1; }

  thirdparty_sha=$(sha256sum "$THIRDPARTY_SOURCE_DIR/3rdparty/CMakeLists.txt" | awk '{print $1}') \
    || return 1
  packages=$(rpm -q gcc gcc-c++ glibc cmake zstd 2> /dev/null | sort | tr '\n' ' ') \
    || return 1

  echo "schema=cubrid-3rdparty-archive-poc-v1"
  echo "source_dir=$THIRDPARTY_SOURCE_DIR"
  echo "build_dir=$THIRDPARTY_BUILD_DIR"
  echo "thirdparty_cmake_sha256=$thirdparty_sha"
  echo "platform=$(uname -s)-$(uname -m)"
  echo "compiler_target=$(gcc -dumpmachine)"
  echo "compiler_version=$(gcc -dumpfullversion -dumpversion)"
  echo "cmake_version=$(cmake --version | sed -n '1p')"
  echo "packages=$packages"
  printf 'CC=%q\nCXX=%q\nCFLAGS=%q\nCXXFLAGS=%q\nLDFLAGS=%q\n' \
    "${CC:-}" "${CXX:-}" "${CFLAGS:-}" "${CXXFLAGS:-}" "${LDFLAGS:-}"
  printf 'build_args='
  printf '%q ' "$@"
  printf '\n'
}

function publish_thirdparty_archive ()
{
  local archive_root=$1 entry=$2 manifest=$3
  local stage
  stage="$archive_root/.tmp-$(basename "$entry")-$$-$RANDOM"

  if ! mkdir -p "$archive_root/v1" || ! mkdir "$stage"; then
    echo "[3rdparty-archive] warning: cannot create a publication staging directory" >&2
    return 0
  fi

  printf '%s\n' "$manifest" > "$stage/manifest.txt"
  if ! tar -C "$THIRDPARTY_BUILD_DIR" -cf - 3rdparty \
    | zstd -T0 -3 -q -o "$stage/thirdparty.tar.zst"
  then
    echo "[3rdparty-archive] warning: could not create the zstd archive" >&2
    rm -rf "$stage"
    return 0
  fi

  if ! (cd "$stage" \
    && sha256sum thirdparty.tar.zst > thirdparty.tar.zst.sha256 \
    && touch complete)
  then
    echo "[3rdparty-archive] warning: could not finish the staged entry" >&2
    rm -rf "$stage"
    return 0
  fi

  if mv -T "$stage" "$entry" 2> /dev/null; then
    echo "[3rdparty-archive] published $(basename "$entry")"
  else
    echo "[3rdparty-archive] another publisher already owns $(basename "$entry")"
    rm -rf "$stage"
  fi
}

function run_build_with_thirdparty_archive ()
{
  if [ -z "${CUBRID_3RDPARTY_ARCHIVE_DIR+x}" ]; then
    if [ "${CUBRID_3RDPARTY_ARCHIVE_PUBLISH:-false}" = true ]; then
      echo "[3rdparty-archive] error: PUBLISH=true requires CUBRID_3RDPARTY_ARCHIVE_DIR" >&2
      return 1
    fi
    ./build.sh -p "$CUBRID" "$@" clean build
    return
  fi

  local archive_root=$CUBRID_3RDPARTY_ARCHIVE_DIR
  [ -n "$archive_root" ] \
    || { echo "[3rdparty-archive] error: CUBRID_3RDPARTY_ARCHIVE_DIR is empty" >&2; return 1; }
  [ -d "$archive_root" ] && [ -r "$archive_root" ] \
    || { echo "[3rdparty-archive] error: archive directory is missing or unreadable: $archive_root" >&2; return 1; }
  command -v zstd > /dev/null \
    || { echo "[3rdparty-archive] error: zstd is required when archive reuse is enabled" >&2; return 1; }
  if [ "${CUBRID_3RDPARTY_ARCHIVE_PUBLISH:-false}" = true ] && [ ! -w "$archive_root" ]; then
    echo "[3rdparty-archive] error: publisher cannot write archive directory: $archive_root" >&2
    return 1
  fi

  set_thirdparty_build_layout "$@" || return 1

  local manifest key entry hit=false
  manifest=$(thirdparty_archive_manifest "$@") || return 1
  key=$(printf '%s\n' "$manifest" | sha256sum | awk '{print $1}') || return 1
  entry="$archive_root/v1/$key"

  echo "[3rdparty-archive] key=$key build_dir=$THIRDPARTY_BUILD_DIR"
  ./build.sh -p "$CUBRID" "$@" clean || return 1

  if [ -f "$entry/complete" ] \
    && (cd "$entry" && sha256sum -c thirdparty.tar.zst.sha256 > /dev/null 2>&1)
  then
    mkdir -p "$THIRDPARTY_BUILD_DIR"
    if zstd -dc "$entry/thirdparty.tar.zst" | tar -xf - -C "$THIRDPARTY_BUILD_DIR"; then
      hit=true
      echo "[3rdparty-archive] hit: restored $key"
    else
      echo "[3rdparty-archive] warning: extraction failed; rebuilding from scratch" >&2
      rm -rf "$THIRDPARTY_BUILD_DIR/3rdparty"
    fi
  elif [ -e "$entry" ]; then
    echo "[3rdparty-archive] warning: incomplete or corrupt entry; rebuilding from scratch" >&2
  else
    echo "[3rdparty-archive] miss: no entry for $key"
  fi

  ./build.sh -p "$CUBRID" "$@" build || return 1

  if [ "$hit" = false ] && [ "${CUBRID_3RDPARTY_ARCHIVE_PUBLISH:-false}" = true ]; then
    if [ -d "$THIRDPARTY_BUILD_DIR/3rdparty" ]; then
      publish_thirdparty_archive "$archive_root" "$entry" "$manifest"
    else
      echo "[3rdparty-archive] warning: build succeeded without a third-party tree to publish" >&2
    fi
  fi
}

function run_build ()
{
  if [ -f ./build.sh ]; then
    CUBRID_SRCDIR=.
  elif [ -f cubrid/build.sh ]; then
    CUBRID_SRCDIR=cubrid
  else
    echo "Cannot find CUBRID source directory!"
    echo "Run '/entrypoint.sh checkout [<ref>]' first, or mount the source here."
    return 1
  fi

  check_history $CUBRID_SRCDIR || return 1

  if ! (cd $CUBRID_SRCDIR \
    && run_build_with_thirdparty_archive "$@") 2>&1 | tee build.log \
      | { grep -e '^\[3rdparty-archive\]' -e '\[[ 0-9]\+%\]' -e ' error: ' -e '\[[0-9]\+\/[0-9]\+\]' || true; }
  then
    tail -500 build.log
    return 1
  fi
}

function run_dist ()
{
  if [ -f ./build.sh ]; then
    CUBRID_SRCDIR=.
  elif [ -f cubrid/build.sh ]; then
    CUBRID_SRCDIR=cubrid
  else
    echo "Cannot find CUBRID source directory!"
    echo "Run '/entrypoint.sh checkout [<ref>]' first, or mount the source here."
    return 1
  fi

  check_history $CUBRID_SRCDIR || return 1

  (cd $CUBRID_SRCDIR \
    && ./build.sh -p $CUBRID $@ dist) | tee dist.log
}

# Two plain tars, as in CTP's common/ext/run_coverage.sh; see the README for why `dist` cannot.
#
# The names are that script's. The layout is not: it tars the trees from the inside, with no
# top-level directory, and run_cubrid_install unpacks them into a cubrid-<build id> of its own
# making. Keeping the tree's real directory name instead is what lets the test node put it back
# at the path it was built at, which is what makes GCOV_PREFIX and lcov's
# geninfo_adjust_src_path unnecessary. The consumer here is the test image, not that installer.
function package_gcov ()
{
  local src version out=${GCOV_OUTPUT_DIR:-$PWD}
  # $CUBRID_SRCDIR is where run_build found build.sh; only run_coverage calls this.
  src=$(cd "$CUBRID_SRCDIR" && pwd) || return 1
  # A tree whose history cannot be walked stamps the version 11.5.0.-<hash> and build.sh still
  # exits 0. check_history refuses that before the build; this is the last stop before the name
  # goes onto an archive. (A print_fatal cannot reach here -- it exits 1, which the line above
  # catches.)
  version=$(cd "$src" && ./build.sh -v) || return 1
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "** ERROR: build.sh -v answered '$version', which is not a version" >&2; return 1 ;;
  esac

  # The mode is forced above, but this checks that it took effect rather than that it was
  # asked for. Without .gcno there is nothing for lcov to read, and the archives would still
  # go out under a name that says they carry coverage.
  [ -n "$(find "$src" -name '*.gcno' -print -quit)" ] \
    || { echo "** ERROR: no .gcno under $src; this is not a coverage build" >&2; return 1; }

  mkdir -p "$out" || return 1
  out=$(cd "$out" && pwd) || return 1
  # tar cannot archive a directory it is writing into: the directory's own mtime changes
  # while tar reads it and tar exits 1. Happens when the source is the working directory.
  case "$out/" in
    "$src"/*)    echo "** ERROR: GCOV_OUTPUT_DIR ($out) is inside the source tree ($src);" \
                      "point it somewhere else" >&2; return 1 ;;
    "$CUBRID"/*) echo "** ERROR: GCOV_OUTPUT_DIR ($out) is inside the install tree ($CUBRID);" \
                      "point it somewhere else" >&2; return 1 ;;
  esac

  local plat=Linux.$(uname -m)
  local build_tar=CUBRID-$version-gcov-$plat.tar.gz
  local src_tar=cubrid-$version-gcov-src-$plat.tar.gz

  # The same step that script takes right before its own binary tar (run_coverage.sh:145).
  mkdir -p "$CUBRID/databases"

  # .git is a third of the tree and no use to lcov; the build directory is, so it stays.
  # The .gcda are this build's own coverage - build.sh runs instrumented binaries of its own,
  # which left 375 of them here in the first real build - and a test run must not count them.
  tar czf "$out/$src_tar" --exclude=.git --exclude='*.gcda' \
      -C "$(dirname "$src")" "$(basename "$src")" || return 1
  tar czf "$out/$build_tar" -C "$(dirname $CUBRID)" "$(basename $CUBRID)" || return 1

  echo "[coverage] $version -> $out"
  local f
  for f in "$build_tar" "$src_tar"; do
    echo "  $(cd "$out" && du -h "$f")"
  done
  # The paths compiled into the .gcda have to exist on the test node, or lcov finds nothing.
  echo "  built in $src; on the test node extract the source archive with" \
       "'tar -C $(dirname "$src") -xzf $src_tar'"
}

function run_coverage ()
{
  # -m last so it wins over anything the caller passed.
  run_build "$@" -m coverage || return 1
  package_gcov
}

function run_default ()
{
  run_build
}

case "$1" in
  "")
    set -- run_default
    ;;
  checkout)
    shift
    set -- run_checkout "$@"
    ;;
  build)
    shift
    set -- run_build "$@"
    ;;
  dist)
    shift
    set -- run_dist "$@"
    ;;
  coverage)
    shift
    set -- run_coverage "$@"
    ;;
esac

if [ -n "$(type -t $1)" -a "$(type -t $1)" = function ]; then
  eval "$@"
else
  exec "$@"
fi
