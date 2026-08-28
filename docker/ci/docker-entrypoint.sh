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
esac

if [ -n "$(type -t $1)" -a "$(type -t $1)" = function ]; then
  eval "$@"
else
  exec "$@"
fi
