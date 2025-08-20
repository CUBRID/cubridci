#!/bin/bash -le

DEBUG=true


# Function to print debug messages
debug() {
  [ "$DEBUG" = true ] && echo "[debug] $1 : $2"
}

# Function to set up environment variables
configure() {
  debug "configure user=$user" "$LINENO"

  sudo /usr/sbin/sshd

  debug "`env`" "$LINENO"
  debug "configure done. $ENV" "$LINENO"
}

# Function to clone Git repository
clone_repository() {
  local repo=$1
  local branch=$2
  local url="https://${GITHUB_TOKEN}@github.com/CUBRID/$repo.git"
  
  debug "clone_repository $repo $branch $url" "$LINENO"
  if [ ! -d "$WORKDIR/$repo" ]; then
    sudo -E -u "$USER" bash -c "git -c fetch.parallel=0 -c core.compression=9 clone -q --depth 1 --branch $branch --single-branch --no-tags $url $WORKDIR/$repo"
  elif [ -d "$WORKDIR/$repo" ]; then
    sudo -E -u "$USER" bash -c "cd $WORKDIR/$repo && git fetch --depth 1 origin $branch && git reset --hard origin/$branch && git clean -df"
  else
    debug "Cannot find .git from $WORKDIR/$repo directory!" "$LINENO"
    exit 1
  fi
  debug "`ls -la $WORKDIR/$repo`" "$LINENO"
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
  
  ( cd $CTP_HOME && HOME=$WORKDIR ./bin/ctp.sh shell -c $CTP_HOME/conf/shell_ci.conf )
  
  set +e
  report_test $TEST_REPORT
  ret=$?
  set -e
  # if [ $ret -gt 0 ]; then
  #   run_manual_test_result $TEST_REPORT $BASELINE
  # fi

  debug "run_test() exit $ret" "$LINENO"
  exit $ret
}

# Function to report test results
report_test() {
  debug "report_test()" "$LINENO"
  local xml_output=$1
  local junit_xml=$xml_output/test-${TEST_SUITE}.xml
  local runtime_logs="$CTP_HOME/result/shell/current_runtime_logs"
  local status_log="$runtime_logs/test_status.data"

  cp $runtime_logs/test-${TEST_SUITE}.xml $junit_xml
  
  debug "JUnit XML generated: $(ls -la $(readlink -f $junit_xml))" "$LINENO"
  
  # Check if there are any failed test cases
  local total_fail_case_count=$(awk -F'=' '/total_fail_case_count/ {print $2}' $status_log)
  if [ $total_fail_case_count -gt 0 ]; then
    echo "** $total_fail_case_count cases are failed."
    return $total_fail_case_count
  else
    echo "** All Tests are passed"
    return 0
  fi
}

run_manual_test_result() {
  debug "run_manual_test_result()" "$LINENO"
  local xml_output=$1
  local baseline=$2
  
  if [ "$baseline" != "none" ]; then
    # If baseline is provided, pass it to manual_test_result
    debug "Using provided baseline: $baseline" "$LINENO"
    java -cp $CUBRID/jdbc/cubrid_jdbc.jar:/manual_test_result.jar manual_test_result $baseline $xml_output/test-${TEST_SUITE}.xml
    mv -f $baseline*new.csv $xml_output 2>/dev/null || true
  else
    # If baseline is not provided, let manual_test_result find the latest version
    debug "No baseline provided, using latest from DB" "$LINENO"
    java -cp $CUBRID/jdbc/cubrid_jdbc.jar:/manual_test_result.jar manual_test_result $xml_output/test-${TEST_SUITE}.xml
    mv -f *new.csv $xml_output 2>/dev/null || true
  fi

  debug "csv file generated: $(ls -la $(readlink -f $xml_output))" "$LINENO"
}

# Main execution function
main() {
  debug "main" "$LINENO"
  case "$1" in
    checkout)
      set -- run_checkout
      ;;
    test)
      set -- run_test
      ;;
    *)
      echo "Unknown role: $1. Use 'checkout' or 'test'."
      exit 1
      ;;
  esac

  if [ -n "$(type -t $1)" -a "$(type -t $1)" = function ]; then
    eval "$@"
  else
    exec "$@"
  fi
}

main "$@"
