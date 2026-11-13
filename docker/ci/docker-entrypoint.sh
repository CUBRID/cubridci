#!/bin/bash -le
# The log filter below would otherwise mask build.sh's exit code.
set -o pipefail

CUBRID_URL=https://github.com/CUBRID/cubrid.git
CUBRID_SRC=cubrid

# The subshell undoes a stage's `cd` before the next attempt. `set -e` is off
# inside it, so a command without its own && or || return fails unnoticed.
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

# Never shallow: build.sh takes the build serial from `git rev-list --count`.
function fetch_source ()
{
  local ref=$1

  if [ ! -d "$CUBRID_SRC/.git" ]; then
    if [ -n "$BUILD_MIRROR" ]; then
      # A container dying mid-fetch into the mirror leaves a .lock that stalls later runs.
      git clone -q --shared --no-checkout "$(mirror_of "$CUBRID_URL")" "$CUBRID_SRC" \
        || return 1
    else
      git -c fetch.parallel=0 clone -q --no-checkout "$CUBRID_URL" "$CUBRID_SRC" \
        || return 1
    fi
  fi

  # By name, so a commit SHA works too, not just a branch.
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
    # A submodule bumped after the mirror was seeded is not in it.
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

  # Build leftovers stop update from moving the submodules.
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

# Without the history build.sh still exits 0 and stamps the package 11.5.0.-<hash>.
function check_history ()
{
  local dir=$1 err
  [ -d "$dir/.git" ] || return 0
  # Only git's message tells which of the two causes it is.
  err=$(git -C "$dir" rev-list --count HEAD 2>&1 > /dev/null) && return 0
  echo "** ERROR: cannot walk the history of $dir; the build number would be empty." >&2
  echo "$err" | sed 's/^/   git: /' >&2
  echo "   A tree checked out with BUILD_MIRROR needs that mirror mounted here too." >&2
  echo "   A bind-mounted tree owned by another user needs safe.directory." >&2
  return 1
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
    && ./build.sh -p $CUBRID $@ clean build) 2>&1 | tee build.log | { grep -e '\[[ 0-9]\+%\]' -e ' error: ' -e '\[[0-9]\+\/[0-9]\+\]' || true; }
  then
    tail -500 build.log
    return 1
  fi
  grep -B2 'needs an update' build.log || true
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

# Not `dist`: see the README. The top-level directory lets the test node restore the build
# path, so neither GCOV_PREFIX nor geninfo_adjust_src_path is needed.
function package_gcov ()
{
  local src version out=${GCOV_OUTPUT_DIR:-$PWD}
  src=$(cd "$CUBRID_SRCDIR" && pwd) || return 1
  # build.sh exits 0 with version 11.5.0.-<hash>; that must not reach the archive names.
  version=$(cd "$src" && ./build.sh -v) || return 1
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "** ERROR: build.sh -v answered '$version', which is not a version" >&2; return 1 ;;
  esac

  # Without .gcno lcov has nothing to read, yet the archive names would say coverage.
  [ -n "$(find "$src" -name '*.gcno' -print -quit)" ] \
    || { echo "** ERROR: no .gcno under $src; this is not a coverage build" >&2; return 1; }

  mkdir -p "$out" || return 1
  out=$(cd "$out" && pwd) || return 1
  # tar exits 1 when it writes into the directory it archives.
  case "$out/" in
    "$src"/*)    echo "** ERROR: GCOV_OUTPUT_DIR ($out) is inside the source tree ($src);" \
                      "point it somewhere else" >&2; return 1 ;;
    "$CUBRID"/*) echo "** ERROR: GCOV_OUTPUT_DIR ($out) is inside the install tree ($CUBRID);" \
                      "point it somewhere else" >&2; return 1 ;;
  esac

  local plat=Linux.$(uname -m)
  local build_tar=CUBRID-$version-gcov-$plat.tar.gz
  local src_tar=cubrid-$version-gcov-src-$plat.tar.gz

  # As CTP's run_coverage.sh:145 does before its binary tar.
  mkdir -p "$CUBRID/databases"

  # lcov needs no .git. The .gcda are from build.sh's own runs; a test run must not count them.
  tar czf "$out/$src_tar" --exclude=.git --exclude='*.gcda' \
      -C "$(dirname "$src")" "$(basename "$src")" || return 1
  tar czf "$out/$build_tar" -C "$(dirname $CUBRID)" "$(basename $CUBRID)" || return 1

  echo "[coverage] $version -> $out"
  local f
  for f in "$build_tar" "$src_tar"; do
    echo "  $(cd "$out" && du -h "$f")"
  done
  # lcov needs the compiled-in source paths on the test node.
  echo "  built in $src; on the test node extract the source archive with" \
       "'tar -C $(dirname "$src") -xzf $src_tar'"
}

function run_coverage ()
{
  # -m last so it wins over anything the caller passed.
  run_build "$@" -m coverage || return 1
  package_gcov
}

function checkout_repo ()
{
  local repo=$1
  local branch=$2
  local url="https://github.com/CUBRID/$repo.git"
  local dir="$WORKDIR/$repo"
  local i ok=
  for i in 1 2 3 4 5; do
    if [ -d "$dir/.git" ]; then
      ( cd "$dir" \
        && git fetch -q --depth 1 origin "$branch" \
        && git reset --hard FETCH_HEAD \
        && git clean -df ) && { ok=1; break; }
    else
      git clone -q --depth 1 --branch "$branch" "$url" "$dir" && { ok=1; break; }
    fi
    echo "[warn] checkout of $repo ($branch) attempt $i/5 failed; retrying in $((i * 10))s" >&2
    sleep $((i * 10))
  done
  [ -n "$ok" ] || { echo "** ERROR: checkout of $repo ($branch) failed after retries" >&2; exit 1; }

  local head
  head=$(git -C "$dir" rev-parse --verify HEAD 2>/dev/null) \
    || { echo "** ERROR: $repo has no valid HEAD after checkout ($branch)" >&2; exit 1; }
  echo "[checkout] $repo @ $branch -> $head $(git -C "$dir" log -1 --pretty=format:'%s' 2>/dev/null)"
}

function run_test ()
{
  checkout_repo cubrid-testtools "$BRANCH_TESTTOOLS"
  checkout_repo cubrid-testcases "$BRANCH_TESTCASES"

  # CUBRIDQA-1093: too many cases fail with reuse_oid on; off until those cases are fixed.
  cd $WORKDIR/cubrid-testtools
  CTP/bin/ini.sh -s sql/cubrid.conf CTP/conf/medium.conf create_table_reuseoid no
  cd -

  RUN_STAMP=$(mktemp)
  trap 'rm -f "$RUN_STAMP"' EXIT

  local t ctp_ret=0
  for t in ${TEST_SUITE//:/ }; do
    (cd $WORKDIR/cubrid-testtools && HOME=$WORKDIR CTP/bin/ctp.sh $t) || { ctp_ret=$?; break; }
  done

  local verdict=
  if [[ ":$TEST_SUITE:" =~ :(medium|sql): ]]; then
    XML_SRC=$WORKDIR/cubrid-testtools/CTP/sql/result
    TC_REPO=cubrid-testcases
    collect_xml
    verdict=judge_sqlresult
  fi

  if [ "$ctp_ret" -ne 0 ]; then
    echo "** ERROR: CTP exited with $ctp_ret" >&2
    exit 1
  fi

  if [ -n "$verdict" ]; then
    if "$verdict"; then exit 0; else exit 1; fi
  fi
}

# Jenkins and gha-ci (test_rl8.10) must judge a result alike: change both together.
# $RUN_STAMP: results left by earlier runs must not count.
function collect_xml ()
{
  local dest=${1:-$TEST_REPORT}
  mkdir -p "$dest"

  local n=0 x
  while IFS= read -r x; do
    cp -f "$x" "$dest/" && n=$((n + 1))
  done < <(find -L "$XML_SRC" -type f -name '*.xml' ! -name 'summary.xml' ${RUN_STAMP:+-newer "$RUN_STAMP"} 2>/dev/null)

  if [ "$n" -eq 0 ]; then
    echo "[warn] no JUnit XML found under $XML_SRC" >&2
  else
    echo "[report] collected $n JUnit XML file(s) into $dest"
  fi
}

function judge_sqlresult ()
{
  local summary_infos
  summary_infos=$(find "$XML_SRC" -type f -name summary_info -newer "$RUN_STAMP" 2>/dev/null || true)
  if [ -z "$summary_infos" ]; then
    echo "** ERROR: no summary_info under $XML_SRC; nothing was tested" >&2
    return 1
  fi

  local failed_list nfailed
  failed_list=$(echo "$summary_infos" | xargs -n1 grep -hw nok | awk -F: '{print $1}' || true)
  if [ -z "$failed_list" ]; then
    nfailed=0
  else
    nfailed=$(echo "$failed_list" | wc -l)
  fi

  if [ "$nfailed" -gt 0 ]; then
    echo "** There are $nfailed failed Testcases on this test."
    echo "** All failed Testcases are listed below:"
    echo "$failed_list" | sed "s|.*$WORKDIR/$TC_REPO/| - |"
    echo "** See the JUnit report in $TEST_REPORT for per-case queries, diffs and source links."
    return 1
  fi

  echo "** All Tests are passed"
}

case "$1" in
  ""|-*)
    set -- run_build "$@"
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
  test)
    set -- run_test
    ;;
esac

if [ -n "$(type -t $1)" -a "$(type -t $1)" = function ]; then
  eval "$@"
else
  exec "$@"
fi
