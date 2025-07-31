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
  local feedback_file="$CTP_HOME/result/shell/current_runtime_logs/feedback.log"
  
  ( cd $CTP_HOME && HOME=$WORKDIR ./bin/ctp.sh shell -c $CTP_HOME/conf/shell_ci.conf )
  
  set +e
  report_test $TEST_REPORT $feedback_file
  ret=$?
  # set -e
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
  local summary_xml=$xml_output/summary.xml
  local junit_xml=$xml_output/test-${TEST_SUITE}.xml
  local feedback_file=$2

  # Validate input
  if [ ! -f "$feedback_file" ]; then
    debug "feedback.log not found in $CTP_HOME/result/shell/current_runtime_logs" "$LINENO"
    return 1
  fi

  # Initialize summary XML file with header
  mkdir -p "$xml_output"
  cat > "$summary_xml" << EOF
<results>
EOF
awk '
  # SKIP_BY_MACRO pattern
  /\[SKIP_BY_MACRO\].*cubrid-testcases-private-ex\/shell\/[^ ]+\.sh/ {
    match($0, /cubrid-testcases-private-ex\/shell\/[^ ]+\.sh/);
    test = substr($0, RSTART, RLENGTH);
    sub("cubrid-testcases-private-ex/", "", test);
    print "  <scenario>\n     <case>" test "</case>\n     <elapsetime>0</elapsetime>\n     <result>skip</result>\n  </scenario>";
    next;
  }
  
  # SKIP_BY_BUG pattern
  /\[SKIP_BY_BUG\].*cubrid-testcases-private-ex\/shell\/[^ ]+\.sh/ {
    match($0, /cubrid-testcases-private-ex\/shell\/[^ ]+\.sh/);
    test = substr($0, RSTART, RLENGTH);
    sub("cubrid-testcases-private-ex/", "", test);
    print "  <scenario>\n     <case>" test "</case>\n     <elapsetime>0</elapsetime>\n     <result>skip</result>\n  </scenario>";
    next;
  }
  
  # OK case start - store test name only
  /^\[OK\]:.*cubrid-testcases-private-ex\/shell\/[^ ]+\.sh/ {
    match($0, /cubrid-testcases-private-ex\/shell\/[^ ]+\.sh/);
    ok_test = substr($0, RSTART, RLENGTH);
    sub("cubrid-testcases-private-ex/", "", ok_test);
    ok_pending = 1;
    next;
  }
  
  # OK case completion - extract time
  ok_pending == 1 && /time=[0-9]+/ {
    match($0, /time=[0-9]+/);
    time = substr($0, RSTART+5, RLENGTH-5);
    print "  <scenario>\n     <case>" ok_test "</case>\n     <elapsetime>" time "</elapsetime>\n     <result>success</result>\n  </scenario>";
    ok_pending = 0;
    next;
  }
  
  # NOK case start - store test name and begin error collection
  /^\[NOK\]:.*cubrid-testcases-private-ex\/shell\/[^ ]+\.sh/ {
    match($0, /cubrid-testcases-private-ex\/shell\/[^ ]+\.sh/);
    nok_test = substr($0, RSTART, RLENGTH);
    sub("cubrid-testcases-private-ex/", "", nok_test);
    nok_pending = 1;
    error_text = $0 "\n";
    next;
  }
  
  # NOK intermediate content collection
  nok_pending == 1 && !/time=[0-9]+/ {
    error_text = error_text $0 "\n";
    next;
  }
  
  # NOK case completion - extract time and output XML
  nok_pending == 1 && /time=[0-9]+/ {
    match($0, /time=[0-9]+/);
    time = substr($0, RSTART+5, RLENGTH-5);
    error_text = error_text $0 "\n";
    print "  <scenario>\n     <case>" nok_test "</case>\n     <elapsetime>" time "</elapsetime>\n     <result>fail</result>\n     <failure_message>Test failed</failure_message>\n     <error_content><![CDATA[" error_text "]]></error_content>\n  </scenario>";
    nok_pending = 0;
    next;
  }
' "$feedback_file" >> "$summary_xml"
  cat >> "$summary_xml" << EOF
</results>
EOF

  # Convert summary.xml to JUnit format using xsltproc
  cat << "_EOL" | xsltproc -o "$junit_xml" --stringparam target "${TEST_SUITE}" - $summary_xml || true
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
 <xsl:output indent="yes" cdata-section-elements="failure"/>
 <xsl:template match="results">
   <testsuites>
     <testsuite name="{$target}" tests="{count(scenario)}" failures="{count(scenario/result[text()='fail'])}" skipped="{count(scenario/result[text()='skip'])}">
       <xsl:apply-templates select="scenario"/>
     </testsuite>
   </testsuites>
 </xsl:template>
 <xsl:template match="scenario">
   <testcase name="{case}" time="{elapsetime}">
     <xsl:if test="result='fail'">
       <failure message="{failure_message}">
         <xsl:value-of select="error_content"/>
       </failure>
     </xsl:if>
     <xsl:if test="result='skip'">
       <skipped/>
     </xsl:if>
   </testcase>
 </xsl:template>
</xsl:stylesheet>
_EOL

  rm -rf $summary_xml
  debug "JUnit XML generated: $(ls -la $(readlink -f $junit_xml))" "$LINENO"
  
  # Check if there are any failed test cases
  local total_fail_case_count=$(tail -n 10 "$feedback_file" | grep "Total Fail Case:" | awk -F':' '{print $2}')
  if [ $total_fail_case_count -gt 0 ]; then
    echo "** There are $total_fail_case_count failed Testcases on this test."
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
