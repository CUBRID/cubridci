#!/bin/bash -le
# The log filter below would otherwise mask build.sh's exit code.
set -o pipefail

function run_build ()
{
  if [ -f ./build.sh ]; then
    CUBRID_SRCDIR=.
  elif [ -f cubrid/build.sh ]; then
    CUBRID_SRCDIR=cubrid
  else
    echo "Cannot find CUBRID source directory!"
    return 1
  fi

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
    return 1
  fi

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
