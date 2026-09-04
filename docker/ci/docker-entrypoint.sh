#!/bin/bash -le
set -o pipefail

function usage ()
{
  cat >&2 <<'EOF'
Usage: /entrypoint.sh checkout [<category>]
       /entrypoint.sh test [<category>]
       /entrypoint.sh node
       /entrypoint.sh coverage [<category>]
       /entrypoint.sh <command> [<args>...]

<category> overrides $TEST_SUITE. One category per run.
Supported categories: sql, medium, shell, shell_heavy, shell_long, cci, isolation,
                      sql_by_cci, jdbc, ha_repl, ha_shell, rqg

'node' prepares this container as a CTP node and waits. Multi-node categories
need it on every host the controller does not run on. Required env:
  HA_NODE_PASSWORD  password of the node account ($NODE_USER)
'test ha_repl' and 'test ha_shell' also read:
  HA_SLAVE_HOST     hostname of the slave node
'test ha_repl' also reads:
  HA_SCENARIO       scenario path (default: $WORKDIR/cubrid-testcases/sql)
'test shell_heavy', 'test shell_long', 'test cci', 'test ha_shell' and
'test rqg' also read:
  SHELL_SCENARIO    scenario path (default: the whole category directory)

MEMORY_LEAK=yes runs 'test sql' and 'test medium' under valgrind. It also reads:
  MEMORY_SCENARIO   scenario path (default: the one the category's conf holds)

CODE_COVERAGE=yes collects gcov data after 'test', for any category. It needs a
coverage build injected at $CUBRID and that build's tree at the same path it was
built at. Every 'node' of a multi-node category needs it set too. It also reads:
  COVERAGE_SRC      that source tree (default: $WORKDIR/cubrid)

Both 'test' and 'coverage' stop CUBRID before reading the data: an instrumented
process writes its .gcda only when it exits.

'coverage' collects on this container alone. The controller runs it on every
node itself, so it is only for collecting by hand.
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
      CONF_WRITER=write_shell_conf
      SHELL_ROOT=$WORKDIR/$TC_REPO/shell_heavy
      SHELL_TIMEOUT=7200 ;;
    shell_long)
      TC_REPO=cubrid-testcases-private    CTP_CMD=shell
      CTP_CONF=conf/shell_long_ci.conf    REPORT_STYLE=status
      CONF_WRITER=write_shell_conf
      SHELL_ROOT=$WORKDIR/$TC_REPO/longcase/shell
      SHELL_TIMEOUT=54000 ;;
    cci)
      TC_REPO=cubrid-testcases-private    CTP_CMD=shell
      CTP_CONF=conf/cci_ci.conf           REPORT_STYLE=status
      CONF_WRITER=write_shell_conf
      SHELL_ROOT=$WORKDIR/$TC_REPO/interface/CCI/shell/_20_cci
      SHELL_EXCLUDE=
      SHELL_TIMEOUT=7200 ;;
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
      CONF_WRITER=write_ha_conf
      HA_TOPOLOGY=1                       COVERAGE_NODES=$HA_SLAVE_HOST ;;
    ha_shell)
      TC_REPO=cubrid-testcases-private    CTP_CMD=shell
      CTP_CONF=conf/ha_shell_ci.conf      REPORT_STYLE=status
      CONF_WRITER=write_shell_conf
      SHELL_ROOT=$WORKDIR/$TC_REPO/HA/shell
      SHELL_TIMEOUT=7200                  HA_TOPOLOGY=1
      COVERAGE_NODES=$HA_SLAVE_HOST ;;
    rqg)
      TC_REPO=cubrid-testcases-private    CTP_CMD=rqg
      CTP_CONF=conf/rqg_ci.conf           REPORT_STYLE=status
      CONF_WRITER=write_shell_conf
      SHELL_ROOT=$WORKDIR/$TC_REPO/random_query_generator
      SHELL_EXCLUDE=$SHELL_ROOT/config/daily_regression_test_exclude_list_RQG.conf
      SHELL_TIMEOUT=36000
      TOOL_REPO=cubrid-testtools-internal TOOL_PATH=random_query_generator
      TOOL_PATCHER=patch_rqg_tool
      RQG_HOME=$WORKDIR/$TOOL_REPO/$TOOL_PATH
      NEEDS_DEBUG=1 ;;
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

# Unlike a memory-leak run this needs no conf key and no category of its own: an instrumented
# binary writes its .gcda by itself. So it lives outside resolve_category, and 'node' and
# 'coverage' read it too.
function resolve_coverage ()
{
  case "${CODE_COVERAGE,,}" in
    ""|0|no|false|off) CODE_COVERAGE= ;;
    1|yes|true|on)     CODE_COVERAGE=1 ;;
    *) echo "** ERROR: CODE_COVERAGE must be yes or no, not '$CODE_COVERAGE'" >&2; exit 1 ;;
  esac
  COVERAGE_SRC=${COVERAGE_SRC:-$WORKDIR/cubrid}
}

# Drop the token on exit so the test step never sees a git credential.
function setup_token ()
{
  local repo private=
  for repo in "$TC_REPO" "$TOOL_REPO"; do
    case "$repo" in
      *-private|*-private-ex|*-internal) private="$private $repo" ;;
    esac
  done
  [ -n "$private" ] || return 0

  [ -n "$GHI_TOKEN" ] \
    || { echo "** ERROR: GHI_TOKEN is required to check out$private" >&2; exit 1; }

  TOKEN_CONFIG_KEY="url.https://x-access-token:${GHI_TOKEN}@github.com/.insteadof"
  git config --global "$TOKEN_CONFIG_KEY" https://github.com/
  trap 'git config --global --unset-all "$TOKEN_CONFIG_KEY" 2>/dev/null || true' EXIT
}

# A third argument narrows the checkout to one path. --depth 1 alone does not help there:
# cubrid-testtools-internal is 1.1GB at that depth and rqg needs 5.5MB of it, so the blobs
# outside the path have to be filtered out as well, not just left out of the working tree.
function checkout_repo ()
{
  local repo=$1
  local branch=$2
  local sparse=$3
  local url="https://github.com/CUBRID/$repo.git"
  local dir="$WORKDIR/$repo"
  local narrow=
  [ -z "$sparse" ] || narrow="--filter=blob:none --sparse"
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
          --single-branch --no-tags $narrow "$url" "$dir" \
        && { [ -z "$sparse" ] || git -C "$dir" sparse-checkout set "$sparse"; } \
        && { ok=1; break; }
    fi
    echo "[warn] checkout of $repo ($branch) attempt $i/5 failed; retrying in $((i * 10))s" >&2
    sleep $((i * 10))
  done
  [ -n "$ok" ] || { echo "** ERROR: checkout of $repo ($branch) failed after retries" >&2; exit 1; }

  [ -z "$sparse" ] || [ -d "$dir/$sparse" ] \
    || { echo "** ERROR: $repo has no $sparse after checkout ($branch)" >&2; exit 1; }

  local head
  head=$(git -C "$dir" rev-parse --verify HEAD 2>/dev/null) \
    || { echo "** ERROR: $repo has no valid HEAD after checkout ($branch)" >&2; exit 1; }
  echo "[checkout] $repo @ $branch -> $head $(git -C "$dir" log -1 --pretty=format:'%s' 2>/dev/null)"
}

# defined(@array) became a fatal error in perl 5.22 and the tool still uses it, so it dies on
# every RL8.10 perl. The guard reads the end state, not the sed, so it also passes once the
# tool is fixed upstream. Those two lines are the only 'defined @' in the whole tool.
function patch_rqg_tool ()
{
  local f="$RQG_HOME/lib/GenTest/Properties.pm"
  [ -f "$f" ] \
    || { echo "** ERROR: $f not found; check $TOOL_REPO upstream" >&2; exit 1; }

  sed -i 's/if defined @illegal;/if @illegal;/; s/if defined @missing;/if @missing;/' "$f"
  ! grep -q 'defined @' "$f" \
    || { echo "** ERROR: $f still has defined(@array); check $TOOL_REPO upstream" >&2; exit 1; }
  echo "[patch] $f -> defined(@array) removed"
}

function run_checkout ()
{
  setup_token
  checkout_repo cubrid-testtools "$BRANCH_TESTTOOLS"
  checkout_repo "$TC_REPO" "$BRANCH_TESTCASES"
  if [ -n "$TOOL_REPO" ]; then
    checkout_repo "$TOOL_REPO" "$BRANCH_TESTTOOLS" "$TOOL_PATH"
    if [ -n "$TOOL_PATCHER" ]; then
      "$TOOL_PATCHER"
    fi
  fi
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

  # The shell runner works inside the case's own directory and saves a failing case under
  # ~/ERROR_BACKUP, so those have to belong to the node account too, not just CUBRID and CTP.
  # And the node account runs the server, so on a coverage run the build tree it writes its
  # .gcda into has to belong to it as well.
  local d
  for d in "$CUBRID" "$WORKDIR"/cubrid-test* "$WORKDIR/ERROR_BACKUP" "$WORKDIR/do_not_delete_core" \
           ${CODE_COVERAGE:+"$COVERAGE_SRC"}; do
    [ -d "$d" ] || continue
    chown -R "$NODE_USER" "$d"
  done

  # HOME has to be $WORKDIR, whatever the controller's is: ha_shell cases address the build as
  # ~/CUBRID, and both CTP and the cases put their own copies and logs next to it.
  local v
  { echo "HOME=$WORKDIR"
    for v in CUBRID CUBRID_DATABASES CTP_HOME init_path JAVA_HOME \
             LD_LIBRARY_PATH SHLIB_PATH LIBPATH PATH LANG TZ; do
      echo "$v=${!v}"
    done
  } > /etc/environment

  if [ -n "$CODE_COVERAGE" ]; then
    mkdir -p "$TEST_REPORT" && chown "$NODE_USER" "$TEST_REPORT"
  fi

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

# CTP ships no usable conf for the shell variants. They run the shell runner over different cases,
# so only the scenario, its exclude list, the time a case may take and the label on the report
# differ; the rest has to stay in step with shell_ci.conf, which is why this derives from it.
# ha_shell is a shell variant too, and conf/ha_shell.conf is no better a source: every key it
# holds is commented out except a scenario pointing at the public cases repo.
function write_shell_conf ()
{
  local src="$CTP_HOME/conf/shell_ci.conf"
  [ -f "$src" ] \
    || { echo "** ERROR: $src not found; cannot derive $CTP_CONF" >&2; exit 1; }

  local scenario=${SHELL_SCENARIO:-$SHELL_ROOT}
  # An empty SHELL_EXCLUDE is how a category says it has no exclude list, so only an unset one
  # falls back to the usual path. CTP skips the file when the key is empty and fails on a
  # missing one, so a category without a list has to leave the key empty, not point at nothing.
  local exclude=${SHELL_EXCLUDE-$SHELL_ROOT/config/daily_regression_test_excluded_list_linux.conf}
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

  # The shell runner reaches a second node through the master instance's relatedhosts, and it
  # takes the ports and the HA port from the default.* keys already inherited above.
  local where=$scenario
  if [ -n "$HA_TOPOLOGY" ]; then
    [ -n "$HA_SLAVE_HOST" ] \
      || { echo "** ERROR: HA_SLAVE_HOST is required for $TEST_SUITE" >&2; exit 1; }
    cat >> "$CTP_HOME/$CTP_CONF" <<EOF
default.ssh.pwd=$HA_NODE_PASSWORD
default.ssh.port=22
env.ha1.ssh.host=$(hostname)
env.ha1.ssh.user=$NODE_USER
env.ha1.ssh.relatedhosts=$HA_SLAVE_HOST
EOF
    where="$scenario, master $(hostname), slave $HA_SLAVE_HOST"
  fi
  echo "[conf] $CTP_HOME/$CTP_CONF -> $where"
}

# <type> is one of release, debug, optdebug, coverage debug, profile debug or unknown
# (CMakeLists.txt BUILD_TYPE).
function build_type_of ()
{
  "$CUBRID/bin/cubrid_rel" | sed -n 's/.*[0-9]\+bit \(.*\) build for.*/\1/p'
}

# A release build is -O2 -DNDEBUG with no -g, so whatever reads the run afterwards - a leak
# report, a core - gets bare addresses out of it, and the run still finishes and passes.
function require_debug_build ()
{
  local what=$1
  local build_type
  build_type=$(build_type_of)
  case "$build_type" in
    *debug*) ;;
    *) echo "** ERROR: $what needs a build with debug symbols;" \
            "$CUBRID is a '${build_type:-unreadable}' build" >&2; exit 1 ;;
  esac
}

# run_memory.sh moves cub_server and cub_cas aside and puts valgrind shims under their names,
# restoring them only if it reaches its last step. A leftover shim means $CUBRID is no longer
# the injected build, and the run after it would measure the shim.
function check_memory_env ()
{
  command -v valgrind >/dev/null \
    || { echo "** ERROR: valgrind is not on PATH; a memory-leak run needs it" >&2; exit 1; }

  require_debug_build "a memory-leak run"

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

# The .gcda paths are compiled into the binaries, so the tree has to sit where it was built.
function check_coverage_env ()
{
  command -v lcov >/dev/null \
    || { echo "** ERROR: lcov is not on PATH; a coverage run needs it" >&2; exit 1; }

  [ -d "$COVERAGE_SRC" ] \
    || { echo "** ERROR: no coverage source tree at $COVERAGE_SRC; unpack the gcov source" \
              "archive so its tree lands there" >&2; exit 1; }
  [ -n "$(find "$COVERAGE_SRC" -name '*.gcno' -print -quit)" ] \
    || { echo "** ERROR: no .gcno under $COVERAGE_SRC; that tree is not from a coverage build" >&2; exit 1; }

  # Before the build-type probe below, which runs an instrumented binary of its own.
  COVERAGE_STALE_COUNT=$(find "$COVERAGE_SRC" -name '*.gcda' -printf . | wc -c)

  local build_type
  build_type=$(build_type_of)
  case "$build_type" in
    *coverage*) ;;
    *) echo "** ERROR: a coverage run needs a build made with 'build.sh -m coverage';" \
            "$CUBRID is a '${build_type:-unreadable}' build" >&2; exit 1 ;;
  esac

  # Two archives from different builds put .gcno and binaries out of step, and geninfo answers by
  # skipping each mismatched file - a small but valid lcov, and a clean exit. Only the generated
  # version.h carries the serial. Take the first match: $(echo ...) would join two into a string.
  local vh src_version
  set -- "$COVERAGE_SRC"/build_*_coverage/version.h
  vh=$1
  [ -f "$vh" ] \
    || { echo "** ERROR: no build_*_coverage/version.h under $COVERAGE_SRC;" \
              "the two gcov archives cannot be checked against each other" >&2; exit 1; }
  src_version=$(awk '/^#define (MAJOR|MINOR|PATCH|EXTRA)_VERSION /{v[$2]=$3}
                     END{print v["MAJOR_VERSION"]"."v["MINOR_VERSION"]"."v["PATCH_VERSION"]"."v["EXTRA_VERSION"]}' "$vh")
  case "$("$CUBRID/bin/cubrid_rel")" in
    *"$src_version"*) ;;
    *) echo "** ERROR: $COVERAGE_SRC is build $src_version but $CUBRID is not;" \
            "the two gcov archives are from different builds" >&2; exit 1 ;;
  esac

  # HA_TOPOLOGY only means "nodes need preparing", so the hosts to collect from are their own
  # attribute rather than inferred from it. Without it a multi-node run reports the controller's alone.
  [ -z "$HA_TOPOLOGY" ] || [ -n "$COVERAGE_NODES" ] \
    || { echo "** ERROR: $TEST_SUITE prepares nodes but names none to collect from;" \
              "set HA_SLAVE_HOST" >&2; exit 1; }

  echo "[coverage] $COVERAGE_SRC, build type '$build_type'"
}

# What matters is not how find reported the delete but whether anything is left: a leftover .gcda
# is counted by the next run on this tree, and the measured failures are partial deletes anyway.
function delete_gcda ()
{
  find "$COVERAGE_SRC" -name '*.gcda' -delete || true
  # Checked apart from the delete, because a find that could not read the tree also returns nothing.
  local left
  left=$(find "$COVERAGE_SRC" -name '*.gcda' -print -quit) \
    || { echo "** ERROR: cannot read $COVERAGE_SRC to confirm the .gcda are gone" >&2; return 1; }
  [ -z "$left" ] \
    || { echo "** ERROR: .gcda are still under $COVERAGE_SRC; a run on this tree would count" \
              "data it did not produce" >&2; return 1; }
}

# gcov merges into an existing .gcda, so anything left behind is counted in this run. Last step
# before CTP starts: the guards above run cubrid_rel, and one instrumented binary writes a .gcda
# per translation unit linked into it - enough to satisfy run_lcov's "nothing was executed" check.
function clear_gcda ()
{
  delete_gcda || return 1
  if [ "${COVERAGE_STALE_COUNT:-0}" -gt 0 ]; then
    echo "[coverage] cleared $COVERAGE_STALE_COUNT .gcda that were already in the tree"
  fi
}

# The same name the nightly's collector builds, for the category in it. Only the name: cc4c picks
# files up by a ".info" sidecar and rewrites their SF paths against a directory this layout has not.
function lcov_name ()
{
  # %s (epoch), not %S: the nightly collector's own format, and cc4c never reads the stamp.
  echo "cubrid_[${TEST_SUITE}]_${USER:-$(id -un)}-$(hostname -s)_$(date '+%Y%m%d%H%M%s').lcov"
}

# An instrumented process writes its .gcda when it exits, and no runner reliably stops the server:
# the SQL runner skips its cleanup after a core, the shell runner leaves stopping to the case. What
# still runs at the container's exit dies on SIGKILL. A zombie stalls the stop, hence the timeout.
function stop_for_coverage ()
{
  timeout 300 "$CUBRID/bin/cubrid" service stop > /dev/null 2>&1 || true
  # The stop can fail or hit the timeout, and then the very thing this function exists to
  # prevent has happened. One other process's .gcda would be enough for the check below.
  local p
  for p in cub_server cub_master cub_broker cub_cas; do
    ! pgrep -x "$p" > /dev/null \
      || { echo "** ERROR: $p is still running after 'cubrid service stop';" \
                "it never wrote its .gcda" >&2; return 1; }
  done
}

function capture_lcov ()
{
  local out=$1
  stop_for_coverage || return 1

  [ -n "$(find "$COVERAGE_SRC" -name '*.gcda' -print -quit)" ] \
    || { echo "** ERROR: no .gcda under $COVERAGE_SRC; nothing was executed under gcov" >&2; return 1; }
  # No --gcov-tool: the system gcov matches the compiler both images carry, unlike CTP's bundled
  # one. The system headers come out afterwards rather than through --no-external, which judges
  # "external" against the base directory and drops any file whose .gcno holds a relative name.
  lcov -q -d "$COVERAGE_SRC" -c -t cubrid -o "$out.all" || return 1
  [ -s "$out.all" ] \
    || { echo "** ERROR: lcov wrote nothing to $out.all" >&2; rm -f "$out.all"; return 1; }
  lcov -q -r "$out.all" '/usr/*' -o "$out" || { rm -f "$out.all" "$out"; return 1; }
  rm -f "$out.all"
  [ -s "$out" ] || { echo "** ERROR: lcov wrote nothing to $out" >&2; return 1; }
  # The rate is the only figure that shows a run which collected far less than it should have. A
  # newer lcov could word its summary differently and leave the sed matching nothing, which is no
  # reason to fail a run whose file is sound.
  local rate
  rate=$(lcov --summary "$out" 2>&1 | sed -n 's/^  \(lines\|functions\)/[coverage]   \1/p') \
    || { echo "** ERROR: lcov --summary failed on $out" >&2; return 1; }
  if [ -n "$rate" ]; then
    echo "$rate"
  else
    echo "** WARNING: could not read a coverage rate out of 'lcov --summary $out';" \
         "the file itself is written" >&2
  fi

  # Read after lcov, so the probe's own .gcda stays out of the file. Two cases install a release
  # build over $CUBRID and are in no exclude list (shell cbrd_26350, ha_shell cbrd_24700, that one
  # on the slave too); every case after them leaves no .gcda, yet the data still reads as a full run.
  local build_type
  build_type=$(build_type_of)
  case "$build_type" in
    *coverage*) ;;
    *) echo "** ERROR: $CUBRID is a '${build_type:-unreadable}' build now, so a case replaced" \
            "it during the run; $out holds only what ran before that" >&2; return 1 ;;
  esac
}

# The tree is left clean whatever the outcome. A failed collection still leaves .gcda behind, and
# a node container outlives its run and clears the tree only at startup, so the next run there
# would count them. Not being able to collect by hand after a failure is the price.
function run_lcov ()
{
  [ -d "$COVERAGE_SRC" ] \
    || { echo "** ERROR: no coverage source tree at $COVERAGE_SRC" >&2; return 1; }
  local rc=0
  capture_lcov "$1" || rc=1
  delete_gcda || rc=1
  return $rc
}

# Each node runs its own server, so the slave holds coverage the controller never sees. CTP
# reaches its nodes by ssh with a password because jsch cannot do public keys, and this uses
# the same account and password rather than adding a second way in.
function collect_coverage_from_node ()
{
  local host=$1 remote
  # Same non-login shell as CTP's own sessions, so the remote side is told what it needs here.
  remote=$(SSHPASS=$HA_NODE_PASSWORD sshpass -e ssh -n "$NODE_USER@$host" \
             "CODE_COVERAGE=yes TEST_SUITE='$TEST_SUITE' TEST_REPORT='$TEST_REPORT'" \
             "COVERAGE_SRC='$COVERAGE_SRC' /entrypoint.sh coverage") || return 1
  remote=$(echo "$remote" | sed -n 's/^\[coverage\] wrote //p')
  [ -n "$remote" ] \
    || { echo "** ERROR: $host reported no lcov file" >&2; return 1; }

  # Not scp: the name carries the category in square brackets, and OpenSSH 8's scp globs the remote
  # path, so [ha_shell] becomes a character class and the name comes back changed ("protocol error").
  SSHPASS=$HA_NODE_PASSWORD sshpass -e ssh -n "$NODE_USER@$host" "cat '$remote'" \
    > "$TEST_REPORT/$(basename "$remote")" || return 1
  [ -s "$TEST_REPORT/$(basename "$remote")" ] \
    || { echo "** ERROR: the lcov file copied from $host is empty" >&2; return 1; }
  echo "[coverage] collected $(basename "$remote") from $host"
}

# The "wrote" line is how a node hands its path back to the controller, so it has to be printed
# on every success, not only when this is reached through the verb.
function run_coverage ()
{
  [ -n "$CODE_COVERAGE" ] \
    || { echo "** ERROR: 'coverage' needs CODE_COVERAGE=yes" >&2; return 1; }
  # The category goes in the file name, and an empty one would name the file after no category.
  [ -n "$TEST_SUITE" ] \
    || { echo "** ERROR: 'coverage' needs a category (argument or \$TEST_SUITE)" >&2; return 1; }
  mkdir -p "$TEST_REPORT" \
    || { echo "** ERROR: cannot create $TEST_REPORT" >&2; return 1; }
  local out="$TEST_REPORT/$(lcov_name)"
  run_lcov "$out" || return 1
  echo "[coverage] $(cd "$TEST_REPORT" && du -h "$(basename "$out")")"
  echo "[coverage] wrote $out"
}

function collect_coverage ()
{
  run_coverage || return 1
  # Unquoted on purpose: COVERAGE_NODES is a space-separated list of hosts.
  local host
  for host in $COVERAGE_NODES; do
    collect_coverage_from_node "$host" || return 1
  done
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
  # Here and not in resolve_coverage: MEMORY_LEAK is normalised by resolve_category, which 'node'
  # and 'coverage' do not call, and a plain MEMORY_LEAK=no would read as on there. The pair is
  # refused for cost, not data: memcheck can overrun stop_for_coverage's timeout on a slower run.
  [ -z "$CODE_COVERAGE" ] || [ -z "$MEMORY_LEAK" ] \
    || { echo "** ERROR: CODE_COVERAGE and MEMORY_LEAK cannot both be on; run them separately" >&2; exit 1; }

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

  # Before prepare_node, so a run that cannot be collected fails before it sets up any node.
  if [ -n "$CODE_COVERAGE" ]; then
    check_coverage_env
  fi

  # This host is the controller and one of the nodes; the others run 'node'.
  if [ -n "$HA_TOPOLOGY" ]; then
    prepare_node
  fi

  if [ -n "$CONF_WRITER" ]; then
    "$CONF_WRITER"
  fi

  if [ -n "$MEMORY_LEAK" ]; then
    check_memory_env
    write_memory_conf
  fi

  # rqg cases kill the server mid-run and then read the cores it left.
  if [ -n "$NEEDS_DEBUG" ]; then
    require_debug_build "test $TEST_SUITE"
  fi

  # The tool is in a repo of its own, so checkout can succeed without it being there.
  if [ -n "$RQG_HOME" ]; then
    [ -f "$RQG_HOME/gentest.pl" ] \
      || { echo "** ERROR: no RQG tool at $RQG_HOME; run 'checkout' first" >&2; exit 1; }
    export RQG_HOME
  fi

  if [ -n "$CODE_COVERAGE" ]; then
    clear_gcda
  fi

  local ctp_ret=0
  ( cd "$WORKDIR" && HOME="$WORKDIR" "$CTP_HOME/bin/ctp.sh" "$CTP_CMD" -c "$CTP_HOME/$CTP_CONF" ) \
    || ctp_ret=$?

  collect_xml

  if [ -n "$MEMORY_LEAK" ]; then
    collect_memory || exit 1
  fi

  if [ -n "$CODE_COVERAGE" ]; then
    collect_coverage || exit 1
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
    resolve_coverage
    run_test
    ;;
  coverage)
    shift; if [ -n "$1" ]; then TEST_SUITE=$1; fi
    resolve_coverage
    run_coverage
    ;;
  node)
    resolve_coverage
    # The same guards the controller runs, so a node that cannot be collected from fails now
    # and not hours later when the controller comes asking.
    if [ -n "$CODE_COVERAGE" ]; then
      check_coverage_env
    fi
    prepare_node
    if [ -n "$CODE_COVERAGE" ]; then
      clear_gcda
    fi
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
