#!/bin/bash -le

DEBUG=true


# Function to print debug messages
debug() {
  [ "$DEBUG" = true ] && echo "[debug] $1 : $2"
  return 0
}

# Function to set up environment variables
configure() {
  debug "configure user=$user" "$LINENO"

  sudo /usr/sbin/sshd

  ulimit -c 10485760
  debug "core file size (10mb): `ulimit -c`" "$LINENO"

  git config --global url."https://x-access-token:${GHI_TOKEN}@github.com/".insteadof https://github.com/

  debug "configure done." "$LINENO"
}

# Function to clone Git repository
clone_repository() {
  local repo=$1
  local branch=$2
  local url="https://github.com/CUBRID/$repo.git"
  local dir="$WORKDIR/$repo"

  debug "clone_repository $repo $branch $url" "$LINENO"

  # Bring the pre-seeded checkout (a blob:none partial + sparse clone that the pod
  # overlay-mounts) to $branch. reset --hard lazily fetches the missing blobs from
  # the promisor remote; under the 50-way shell fan-out GitHub can transiently
  # throttle that fetch (seen as "Empty reply from server" / "Authentication
  # failed" on a few nodes). Retry with backoff, and if it still fails, exit
  # non-zero so we never run tests on an incomplete working tree.
  local i ok=
  for i in 1 2 3 4 5; do
    if [ -d "$dir/.git" ]; then
      ( cd "$dir" \
        && git -c fetch.parallel=0 fetch --depth 1 --no-tags origin "$branch" \
        && git reset --hard "origin/$branch" \
        && git clean -df ) && { ok=1; break; }
    else
      git -c fetch.parallel=0 -c core.compression=9 clone -q --depth 1 --branch "$branch" \
          --single-branch --no-tags "$url" "$dir" && { ok=1; break; }
    fi
    echo "[warn] checkout of $repo ($branch) attempt $i/5 failed; retrying in $((i * 10))s" >&2
    sleep $((i * 10))
  done
  [ -n "$ok" ] || { echo "** ERROR: checkout of $repo ($branch) failed after retries" >&2; exit 1; }

  # Sanity check: a completed clone/reset leaves HEAD at the branch tip.
  local head
  head=$(git -C "$dir" rev-parse --verify HEAD 2>/dev/null) \
    || { echo "** ERROR: $repo has no valid HEAD after checkout ($branch)" >&2; exit 1; }

  # Always report what was actually checked out (branch + commit + subject).
  echo "[checkout] $repo @ $branch -> $head $(git -C "$dir" log -1 --pretty=format:'%s' 2>/dev/null)"

  if [ "$DEBUG" = true ]; then debug "$(ls -la "$dir")" "$LINENO"; fi
  return 0
}

# Git configuration and repository cloning
run_checkout() {
  debug "run_checkout user=$USER" "$LINENO"

  configure
  
  clone_repository "cubrid-testtools" "$BRANCH_TESTTOOLS"
  clone_repository "cubrid-testcases-private-ex" "$BRANCH_TESTCASES"
  
}


# Function to run tests
run_test() {
  debug "run_test()" "$LINENO"
  
  set +e
  ( cd $CTP_HOME && HOME=$WORKDIR ./bin/ctp.sh shell -c $CTP_HOME/conf/shell_ci.conf )
  ctp_ret=$?

  git config --global --unset-all url."https://x-access-token:${GHI_TOKEN}@github.com/".insteadof || true

  # Check if CTP execution failed and exit immediately
  if [ $ctp_ret -ne 0 ]; then
    debug "CTP execution failed with exit code: $ctp_ret" "$LINENO"
    exit $ctp_ret
  fi
  
  report_test $TEST_REPORT
  ret=$?
  set -e

  debug "run_test() exit $ret" "$LINENO"
  exit $ret
}

# Function to report test results
report_test() {
  debug "report_test()" "$LINENO"
  local xml_output=$1
  local runtime_logs="$CTP_HOME/result/shell/current_runtime_logs"
  local xml_log="$runtime_logs/test-${TEST_SUITE}.xml"
  local status_log="$runtime_logs/test_status.data"

  if [ "$DEBUG" = true ]; then debug "CTP log generated: $(ls -la $(readlink -f $runtime_logs))" "$LINENO"; fi
  mkdir -p "$xml_output"
  cp -f $xml_log $xml_output/test-${TEST_SUITE}.xml
  
  if [ "$DEBUG" = true ]; then debug "JUnit XML generated: $(ls -la $(readlink -f $xml_output))" "$LINENO"; fi
  
  # Check if there are any failed test cases
  if [ ! -f "$status_log" ]; then
    echo "** ERROR: test status file not found: $status_log"
    return 1
  fi
  local total_fail_case_count
  total_fail_case_count=$(awk -F'=' '/total_fail_case_count/ {print $2}' "$status_log")
  total_fail_case_count=${total_fail_case_count:-0}
  if [ "$total_fail_case_count" -gt 0 ]; then
    echo "** $total_fail_case_count cases are failed."
    return 1
  else
    echo "** All Tests are passed"
    return 0
  fi
}

# Main execution function
main() {
  debug "main" "$LINENO"
  case "$1" in
    checkout)
      run_checkout
      ;;
    test)
      run_test
      ;;
    *)
      echo "Unknown role: $1. Use 'checkout' or 'test'." >&2
      exit 1
      ;;
  esac
}

main "$@"
