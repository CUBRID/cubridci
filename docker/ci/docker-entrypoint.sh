#!/bin/bash -le
set -o pipefail

function usage ()
{
  cat >&2 <<'EOF'
Usage: /entrypoint.sh checkout [<category>]
       /entrypoint.sh test [<category>]
       /entrypoint.sh <command> [<args>...]

<category> overrides $TEST_SUITE. One category per run.
Supported categories: sql, medium, shell, isolation
EOF
}

# Every category attribute lives here; other functions only read these variables.
function resolve_category ()
{
  case "$TEST_SUITE" in
    sql)
      TC_REPO=cubrid-testcases            CTP_CMD=sql
      CTP_CONF=conf/sql.conf              REPORT_STYLE=sqlresult ;;
    medium)
      TC_REPO=cubrid-testcases            CTP_CMD=medium
      CTP_CONF=conf/medium_dev.conf       REPORT_STYLE=sqlresult ;;
    shell)
      TC_REPO=cubrid-testcases-private-ex CTP_CMD=shell
      CTP_CONF=conf/shell_ci.conf         REPORT_STYLE=status ;;
    isolation)
      TC_REPO=cubrid-testcases            CTP_CMD=isolation
      CTP_CONF=conf/isolation.conf        REPORT_STYLE=status ;;
    "")
      echo "** ERROR: no category given (\$TEST_SUITE is empty)" >&2; usage; exit 1 ;;
    *)
      echo "** ERROR: unknown category '$TEST_SUITE'" >&2; usage; exit 1 ;;
  esac

  case "$REPORT_STYLE" in
    sqlresult) XML_SRC="$CTP_HOME/sql/result" ;;
    status)    XML_SRC="$CTP_HOME/result/$CTP_CMD/current_runtime_logs" ;;
  esac
}

# Drop the token on exit so the test step never sees a git credential.
function setup_token ()
{
  case "$TC_REPO" in
    *-private|*-private-ex) ;;
    *) return 0 ;;
  esac

  [ -n "$GHI_TOKEN" ] \
    || { echo "** ERROR: GHI_TOKEN is required to check out $TC_REPO" >&2; exit 1; }

  TOKEN_CONFIG_KEY="url.https://x-access-token:${GHI_TOKEN}@github.com/.insteadof"
  git config --global "$TOKEN_CONFIG_KEY" https://github.com/
  trap 'git config --global --unset-all "$TOKEN_CONFIG_KEY" 2>/dev/null || true' EXIT
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
      # Single-branch clone: a later fetch updates only FETCH_HEAD, never origin/$branch.
      ( cd "$dir" \
        && git -c fetch.parallel=0 fetch --depth 1 --no-tags origin "$branch" \
        && git reset --hard FETCH_HEAD \
        && git clean -df ) && { ok=1; break; }
    else
      git -c fetch.parallel=0 -c core.compression=9 clone -q --depth 1 --branch "$branch" \
          --single-branch --no-tags "$url" "$dir" && { ok=1; break; }
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

function run_checkout ()
{
  setup_token
  checkout_repo cubrid-testtools "$BRANCH_TESTTOOLS"
  checkout_repo "$TC_REPO" "$BRANCH_TESTCASES"
}

# $RUN_STAMP keeps reporting and judging off results left by earlier runs.
function collect_xml ()
{
  mkdir -p "$TEST_REPORT"

  local n=0 x
  while IFS= read -r x; do
    cp -f "$x" "$TEST_REPORT/" && n=$((n + 1))
  done < <(find -L "$XML_SRC" -type f -name '*.xml' ! -name 'summary.xml' -newer "$RUN_STAMP" 2>/dev/null)

  if [ "$n" -eq 0 ]; then
    echo "[warn] no JUnit XML found under $XML_SRC" >&2
  else
    echo "[report] collected $n JUnit XML file(s) into $TEST_REPORT"
  fi
}

# CTP swallows JUnit-XML writer failures, so the XML must not judge results.
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

function judge_status ()
{
  local status_log="$XML_SRC/test_status.data"
  [ -f "$status_log" ] \
    || { echo "** ERROR: test status file not found: $status_log" >&2; return 1; }
  [ "$status_log" -nt "$RUN_STAMP" ] \
    || { echo "** ERROR: test status file is from an earlier run: $status_log" >&2; return 1; }

  # Without this guard a garbage count errors in [ -gt ] and falls through to "passed".
  local nfailed
  nfailed=$(awk -F'=' '/^total_fail_case_count/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$status_log")
  case "$nfailed" in
    ''|*[!0-9]*)
      echo "** ERROR: no readable total_fail_case_count in $status_log" >&2
      return 1 ;;
  esac

  if [ "$nfailed" -gt 0 ]; then
    echo "** $nfailed cases are failed."
    return 1
  fi

  echo "** All Tests are passed"
}

function run_test ()
{
  [ -x "$CUBRID/bin/cubrid_rel" ] \
    || { echo "** ERROR: no CUBRID at $CUBRID; inject a build before running 'test'" >&2; exit 1; }
  [ -d "$CTP_HOME" ] \
    || { echo "** ERROR: no CTP at $CTP_HOME; run 'checkout' first" >&2; exit 1; }
  [ -d "$WORKDIR/$TC_REPO" ] \
    || { echo "** ERROR: no testcases at $WORKDIR/$TC_REPO; run 'checkout' first" >&2; exit 1; }

  RUN_STAMP=$(mktemp)
  trap 'rm -f "$RUN_STAMP"' EXIT

  # shell cases reach the server over ssh (shell_utils.sh builds "ssh -p ...").
  pgrep -x sshd >/dev/null || sudo /usr/sbin/sshd
  ulimit -c 10485760

  local ctp_ret=0
  ( cd "$WORKDIR" && HOME="$WORKDIR" "$CTP_HOME/bin/ctp.sh" "$CTP_CMD" -c "$CTP_HOME/$CTP_CONF" ) \
    || ctp_ret=$?

  collect_xml

  if [ "$ctp_ret" -ne 0 ]; then
    echo "** ERROR: CTP exited with $ctp_ret" >&2
    exit 1
  fi

  if "judge_${REPORT_STYLE}"; then exit 0; else exit 1; fi
}

case "$1" in
  checkout)
    shift; if [ -n "$1" ]; then TEST_SUITE=$1; fi
    resolve_category
    run_checkout
    ;;
  test)
    shift; if [ -n "$1" ]; then TEST_SUITE=$1; fi
    resolve_category
    run_test
    ;;
  "")
    usage; exit 1
    ;;
  *)
    exec "$@"
    ;;
esac
