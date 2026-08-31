#!/bin/bash -le
set -o pipefail

function usage ()
{
  cat >&2 <<'EOF'
Usage: /entrypoint.sh checkout [<category>]
       /entrypoint.sh test [<category>]
       /entrypoint.sh node
       /entrypoint.sh <command> [<args>...]

<category> overrides $TEST_SUITE. One category per run.
Supported categories: sql, medium, shell, shell_heavy, shell_long, isolation,
                      sql_by_cci, jdbc, ha_repl

'node' prepares this container as a CTP node and waits. Multi-node categories
need it on every host the controller does not run on. Required env:
  HA_NODE_PASSWORD  password of the node account ($NODE_USER)
'test ha_repl' also reads:
  HA_SLAVE_HOST     hostname of the slave node
  HA_SCENARIO       scenario path (default: $WORKDIR/cubrid-testcases/sql)
'test shell_heavy' and 'test shell_long' also read:
  SHELL_SCENARIO    scenario path (default: the whole category directory)

MEMORY_LEAK=yes runs 'test sql' and 'test medium' under valgrind. It also reads:
  MEMORY_SCENARIO   scenario path (default: the one the category's conf holds)
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
    shell_heavy)
      TC_REPO=cubrid-testcases-private-ex CTP_CMD=shell
      CTP_CONF=conf/shell_heavy_ci.conf   REPORT_STYLE=status
      SHELL_ROOT=$WORKDIR/$TC_REPO/shell_heavy
      SHELL_TIMEOUT=7200 ;;
    shell_long)
      TC_REPO=cubrid-testcases-private    CTP_CMD=shell
      CTP_CONF=conf/shell_long_ci.conf    REPORT_STYLE=status
      SHELL_ROOT=$WORKDIR/$TC_REPO/longcase/shell
      SHELL_TIMEOUT=54000 ;;
    isolation)
      TC_REPO=cubrid-testcases            CTP_CMD=isolation
      CTP_CONF=conf/isolation.conf        REPORT_STYLE=status ;;
    sql_by_cci)
      TC_REPO=cubrid-testcases            CTP_CMD=sql_by_cci
      CTP_CONF=conf/sql_by_cci.conf       REPORT_STYLE=cciresult ;;
    jdbc)
      TC_REPO=cubrid-testcases-private    CTP_CMD=jdbc
      CTP_CONF=conf/jdbc.conf             REPORT_STYLE=status ;;
    ha_repl)
      TC_REPO=cubrid-testcases            CTP_CMD=ha_repl
      CTP_CONF=conf/ha_repl_ci.conf       REPORT_STYLE=status
      HA_TOPOLOGY=1 ;;
    "")
      echo "** ERROR: no category given (\$TEST_SUITE is empty)" >&2; usage; exit 1 ;;
    *)
      echo "** ERROR: unknown category '$TEST_SUITE'" >&2; usage; exit 1 ;;
  esac

  case "${MEMORY_LEAK,,}" in
    ""|0|no|false|off) MEMORY_LEAK= ;;
    1|yes|true|on)     MEMORY_LEAK=1 ;;
    *) echo "** ERROR: MEMORY_LEAK must be yes or no, not '$MEMORY_LEAK'" >&2; exit 1 ;;
  esac

  # enable_memory_leak lives in the conf's [sql] section, which only the SQL runner reads
  # (CTP.java executeSQL). Any other category would take the flag and silently ignore it.
  if [ -n "$MEMORY_LEAK" ]; then
    case "$TEST_SUITE" in
      sql|medium) ;;
      *) echo "** ERROR: MEMORY_LEAK does not apply to '$TEST_SUITE'; only sql and medium" >&2; exit 1 ;;
    esac
    MEMORY_SRC_CONF=$CTP_CONF
    CTP_CONF=conf/memoryleak_$TEST_SUITE.conf
  fi

  case "$REPORT_STYLE" in
    sqlresult) XML_SRC="$CTP_HOME/sql/result" ;;
    cciresult) XML_SRC="$CTP_HOME/result/$CTP_CMD" ;;
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

# CTP reaches nodes with jsch ChannelExec, a non-login shell that inherits none of
# Docker's ENV, and it authenticates by password only.
function prepare_node ()
{
  [ -x "$CUBRID/bin/cubrid_rel" ] \
    || { echo "** ERROR: no CUBRID at $CUBRID; inject a build before 'node'" >&2; exit 1; }
  [ -d "$CTP_HOME" ] \
    || { echo "** ERROR: no CTP at $CTP_HOME; run 'checkout' first" >&2; exit 1; }
  [ -n "$HA_NODE_PASSWORD" ] \
    || { echo "** ERROR: HA_NODE_PASSWORD is required to set up the node account" >&2; exit 1; }

  echo "$NODE_USER:$HA_NODE_PASSWORD" | chpasswd
  chown -R "$NODE_USER" "$CUBRID" "$WORKDIR/cubrid-testtools"

  local v
  for v in HOME CUBRID CUBRID_DATABASES CTP_HOME init_path JAVA_HOME \
           LD_LIBRARY_PATH SHLIB_PATH LIBPATH PATH LANG TZ; do
    echo "$v=${!v}"
  done > /etc/environment

  pgrep -x sshd >/dev/null || /usr/sbin/sshd
  echo "[node] $NODE_USER@$(hostname) ready"
}

# Without at least one env.<id>.{cubrid,ha,broker*} key CTP skips its whole node
# configuration step, leaving cubrid_ha.conf empty and ha_mode off. The exclude list is
# the one the nightly regression uses, so both agree on which cases are known to fail.
function write_ha_conf ()
{
  [ -n "$HA_SLAVE_HOST" ] \
    || { echo "** ERROR: HA_SLAVE_HOST is required for $TEST_SUITE" >&2; exit 1; }

  cat > "$CTP_HOME/$CTP_CONF" <<EOF
default.testdb=xdb
default.ssh.pwd=$HA_NODE_PASSWORD
default.ssh.port=22
env.ha1.master.ssh.host=$(hostname)
env.ha1.master.ssh.user=$NODE_USER
env.ha1.slave.ssh.host=$HA_SLAVE_HOST
env.ha1.slave.ssh.user=$NODE_USER
env.ha1.cubrid.cubrid_port_id=1727
env.ha1.ha.ha_port_id=58091
env.ha1.broker1.SERVICE=OFF
env.ha1.broker2.APPL_SERVER_SHM_ID=31091
env.ha1.broker2.BROKER_PORT=31091
scenario=${HA_SCENARIO:-$WORKDIR/$TC_REPO/sql}
testcase_exclude_from_file=$WORKDIR/$TC_REPO/sql/config/daily_regression_test_exclude_list_ha_repl.conf
EOF
  echo "[conf] $CTP_HOME/$CTP_CONF -> master $(hostname), slave $HA_SLAVE_HOST"
}

# CTP ships no conf for the shell variants. They run the shell runner over different cases,
# so only the scenario, its exclude list, the time a case may take and the label on the report
# differ; the rest has to stay in step with shell_ci.conf, which is why this derives from it.
function write_shell_conf ()
{
  local src="$CTP_HOME/conf/shell_ci.conf"
  [ -f "$src" ] \
    || { echo "** ERROR: $src not found; cannot derive $CTP_CONF" >&2; exit 1; }

  local scenario=${SHELL_SCENARIO:-$SHELL_ROOT}
  local exclude="$SHELL_ROOT/config/daily_regression_test_excluded_list_linux.conf"
  sed -e "s|^scenario=.*|scenario=$scenario|" \
      -e "s|^testcase_exclude_from_file=.*|testcase_exclude_from_file=$exclude|" \
      -e "s|^testcase_timeout_in_secs=.*|testcase_timeout_in_secs=$SHELL_TIMEOUT|" \
      -e "s|^testcase_retry_num=.*|testcase_retry_num=0|" \
      -e "s|^test_category=.*|test_category=$TEST_SUITE|" \
      "$src" > "$CTP_HOME/$CTP_CONF"

  # A key renamed upstream makes its sed a no-op, which would silently run the shell scenario.
  local key
  for key in "scenario=$scenario" "testcase_exclude_from_file=$exclude" \
             "testcase_timeout_in_secs=$SHELL_TIMEOUT" "testcase_retry_num=0" \
             "test_category=$TEST_SUITE"; do
    grep -qxF "$key" "$CTP_HOME/$CTP_CONF" \
      || { echo "** ERROR: $CTP_CONF lacks '$key'; check conf/shell_ci.conf upstream" >&2; exit 1; }
  done
  echo "[conf] $CTP_HOME/$CTP_CONF -> $scenario"
}

# run_memory.sh moves cub_server and cub_cas aside and puts valgrind shims under their names,
# restoring them only if it reaches its last step. A leftover shim means $CUBRID is no longer
# the injected build, and the run after it would measure the shim.
function check_memory_env ()
{
  command -v valgrind >/dev/null \
    || { echo "** ERROR: valgrind is not on PATH; a memory-leak run needs it" >&2; exit 1; }

  # A release build is -O2 -DNDEBUG with no -g, so memcheck can only report bare addresses.
  # The run would still finish and pass, leaving reports nothing can be read out of.
  local build_type
  build_type=$("$CUBRID/bin/cubrid_rel" | sed -n 's/.*[0-9]\+bit \(.*\) build for.*/\1/p')
  case "$build_type" in
    *debug*) ;;
    *) echo "** ERROR: a memory-leak run needs a build with debug symbols;" \
            "$CUBRID is a '${build_type:-unreadable}' build" >&2; exit 1 ;;
  esac

  local f
  for f in server.exe cas.exe; do
    [ ! -e "$CUBRID/bin/$f" ] \
      || { echo "** ERROR: $CUBRID/bin/$f is left over from an aborted memory-leak run;" \
                "re-inject CUBRID before running again" >&2; exit 1; }
  done
}

# CTP reads enable_memory_leak from the conf, so the flag has to be written into one. The two
# cubrid.conf parameters are the ones the nightly raises for this run: under valgrind a shutdown
# takes far longer than the default wait allows.
function write_memory_conf ()
{
  local src="$CTP_HOME/$MEMORY_SRC_CONF" dst="$CTP_HOME/$CTP_CONF"
  [ -f "$src" ] \
    || { echo "** ERROR: $src not found; cannot derive $CTP_CONF" >&2; exit 1; }
  cp -f "$src" "$dst"

  # ini.sh inserts a key that is missing, so a rename upstream would leave the live key at 'no'
  # beside a dead one at 'yes' and the run would quietly skip valgrind. Only the source shows it.
  [ -n "$(ini.sh -s sql "$src" enable_memory_leak)" ] \
    || { echo "** ERROR: $MEMORY_SRC_CONF has no enable_memory_leak key; check the CTP conf upstream" >&2; exit 1; }

  local sql_keys="enable_memory_leak=yes"
  if [ -n "$MEMORY_SCENARIO" ]; then
    sql_keys="$sql_keys||scenario=$MEMORY_SCENARIO"
  fi
  ini.sh -s sql -u "$sql_keys" "$dst"
  ini.sh -s sql/cubrid.conf -u "log_compress=false||shutdown_wait_time_in_secs=2147483647" "$dst"

  local got
  got=$(ini.sh -s sql "$dst" enable_memory_leak)
  [ "$got" = "yes" ] \
    || { echo "** ERROR: $CTP_CONF has enable_memory_leak='$got'; ini.sh did not write it" >&2; exit 1; }

  echo "[conf] $dst -> valgrind on, scenario $(ini.sh -s sql "$dst" scenario)"
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

# The leak reports are the point of the run, and the SQL verdict passes without them, so a run
# that produced none has to fail. Leaks themselves are not folded into the exit code: memcheck
# reports reachable blocks for a healthy server too, and there is no baseline to judge against.
function collect_memory ()
{
  local dir
  dir=$(find "$CTP_HOME/result" -maxdepth 1 -type d -name 'memory_*' -newer "$RUN_STAMP" 2>/dev/null | sort | tail -1)
  if [ -z "$dir" ]; then
    echo "** ERROR: no memory_* result under $CTP_HOME/result; valgrind produced nothing" >&2
    return 1
  fi

  mkdir -p "$TEST_REPORT"
  cp -rf "$dir" "$TEST_REPORT/" \
    || { echo "** ERROR: could not copy $dir into $TEST_REPORT" >&2; return 1; }
  echo "[report] collected $(basename "$dir") ($(ls -1 "$dir" | wc -l) files) into $TEST_REPORT"
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

# cci marks failures ":NOK:" in summary.info; its summary_info has only Num_fail, so judge_sqlresult() sees nothing.
function judge_cciresult ()
{
  local summaries
  summaries=$(find "$XML_SRC" -type f -name summary.info -newer "$RUN_STAMP" 2>/dev/null || true)
  if [ -z "$summaries" ]; then
    echo "** ERROR: no summary.info under $XML_SRC; nothing was tested" >&2
    return 1
  fi

  local failed_list nfailed
  failed_list=$(echo "$summaries" | xargs -n1 grep -h ':NOK:' \
                  | sed 's/^TestCase:[[:space:]]*//; s/[[:space:]]*:NOK:.*//' || true)
  if [ -z "$failed_list" ]; then
    nfailed=0
  else
    nfailed=$(echo "$failed_list" | wc -l)
  fi

  if [ "$nfailed" -gt 0 ]; then
    echo "** There are $nfailed failed Testcases on this test."
    echo "** All failed Testcases are listed below:"
    echo "$failed_list" | sed 's|^| - |'
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
  local nfailed nexec
  nfailed=$(awk -F'=' '/^total_fail_case_count/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$status_log")
  case "$nfailed" in
    ''|*[!0-9]*)
      echo "** ERROR: no readable total_fail_case_count in $status_log" >&2
      return 1 ;;
  esac

  # A run that never got a case started leaves every counter at 0, which reads as a pass.
  nexec=$(awk -F'=' '/^total_executed_case_count/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$status_log")
  case "$nexec" in
    ''|*[!0-9]*)
      echo "** ERROR: no readable total_executed_case_count in $status_log" >&2
      return 1 ;;
  esac
  if [ "$nexec" -eq 0 ]; then
    echo "** ERROR: no testcase was executed" >&2
    return 1
  fi

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

  # This host is the controller and one of the nodes; the others run 'node'.
  if [ -n "$HA_TOPOLOGY" ]; then
    prepare_node
    write_ha_conf
  fi

  if [ -n "$SHELL_ROOT" ]; then
    write_shell_conf
  fi

  if [ -n "$MEMORY_LEAK" ]; then
    check_memory_env
    write_memory_conf
  fi

  local ctp_ret=0
  ( cd "$WORKDIR" && HOME="$WORKDIR" "$CTP_HOME/bin/ctp.sh" "$CTP_CMD" -c "$CTP_HOME/$CTP_CONF" ) \
    || ctp_ret=$?

  collect_xml

  if [ -n "$MEMORY_LEAK" ]; then
    collect_memory || exit 1
  fi

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
  node)
    prepare_node
    # Reaping zombies is PID 1's job; a shell in wait does it, 'sleep' alone does not.
    while :; do sleep 3600 & wait $!; done
    ;;
  "")
    usage; exit 1
    ;;
  *)
    exec "$@"
    ;;
esac
