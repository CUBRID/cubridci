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
    sudo -E -u "$USER" bash -c "git clone -q --depth 1 --branch $branch $url $WORKDIR/$repo"
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
  
  # clone_repository "cubrid-testtools" "$CTP_BRANCH_NAME"
  clone_repository "cubrid-testtools" "CUBRIDQA-1245"
  # clone_repository "cubrid-testcases" "develop"
  clone_repository "cubrid-testcases-private-ex" "develop"
  
}


# Function to run tests
run_test() {
  debug "run_test()" "$LINENO"
  local feedback_file="$CTP_HOME/result/shell/current_runtime_logs/feedback.log"
  
  ( cd $CTP_HOME && HOME=$WORKDIR ./bin/ctp.sh shell )
  
  set +e
  report_test $TEST_REPORT $feedback_file
  ret=$?
  set -e
  if [ $ret -gt 0 ]; then
    run_manual_test_result $TEST_REPORT $BASELINE
  fi

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

  # Test case tracking variables
  local test_name=""
  local test_time=""
  local test_result=""
  local is_timeout=false
  # Define test status constants
  local -r TEST_STATUS_OK="[OK]"
  local -r TEST_STATUS_NOK="[NOK]" 
  local -r TEST_STATUS_SKIP_MACRO="[SKIP_BY_MACRO]"
  local -r TEST_STATUS_SKIP_BUG="[SKIP_BY_BUG]"
  local -r TEST_STATUS_UNKNOWN="[UNKNOWN]"
  local test_status="$TEST_STATUS_UNKNOWN"
  
  # Process feedback.log line by line
  while IFS= read -r line; do
    case "$line" in
      "$TEST_STATUS_OK"*)
        test_name=$(echo "$line" | sed -n 's/.*\[OK\]:.*cubrid-testcases-private-ex\/\(shell\/.*\.sh\).*/\1/p')
        test_time=""
        test_result=""
        test_status="$TEST_STATUS_OK"
        ;;
      "$TEST_STATUS_SKIP_BUG"*)
        test_name=$(echo "$line" | sed -n 's/.*\[SKIP_BY_BUG\].*cubrid-testcases-private-ex\/\(shell\/.*\.sh\).*/\1/p')
        test_time="0"
        test_result=""
        test_status="$TEST_STATUS_SKIP_BUG"
        cat >> "$summary_xml" << EOF
  <scenario>
     <case>$test_name</case>
     <elapsetime>$test_time</elapsetime>
     <result>skip</result>
     <skip_reason>$test_status</skip_reason>
  </scenario>
EOF
         # Reset variables for next test
          test_name=""
          test_time=""
          test_result=""
          test_status="$TEST_STATUS_UNKNOWN"
        ;;
      "$TEST_STATUS_NOK":*)
        test_name=$(echo "$line" | sed -n 's/.*\[NOK\]:.*cubrid-testcases-private-ex\/\(shell\/.*\.sh\).*/\1/p')
        test_time=""
        test_result=""
        is_timeout=false
        test_status="$TEST_STATUS_NOK"
        ;;
      *": NOK timeout"*)
        is_timeout=true
        test_result+="$line"$'\n'
        ;;        
      [0-9][0-9]:[0-9][0-9]:[0-9][0-9]*"time="*)
          [ -n "$test_name" ] && test_time=$(echo "$line" | sed -n 's/.*time=\([0-9]*\).*/\1/p')

          if [ "$test_status" == "$TEST_STATUS_OK" ]; then
              cat >> "$summary_xml" << EOF
  <scenario>
     <case>$test_name</case>
     <elapsetime>$test_time</elapsetime>
     <result>success</result>
  </scenario>
EOF
         # Reset variables for next test
          test_name=""
          test_time=""
          test_result=""
          test_status="$TEST_STATUS_UNKNOWN"
          fi
          ;;            
      "[INFO] TEST STOP"*)
        if [ -n "$test_name" ] && [ -n "$test_time" ]; then
          local failure_msg="Test failed"
          [ "$is_timeout" = true ] && failure_msg="Test failed (timeout)"
          cat >> "$summary_xml" << EOF
  <scenario>
     <case>$test_name</case>
     <elapsetime>$test_time</elapsetime>
     <result>fail</result>
     <failure_message>$failure_msg</failure_message>
     <error_content><![CDATA[$test_result]]></error_content>
  </scenario>
EOF
          # Reset variables for next test
          test_name=""
          test_time=""
          test_result=""
        fi
        ;;      
      "[TEST STOP]"*)
        # Close XML file and exit loop
        cat >> "$summary_xml" << EOF
</results>
EOF
        break
        ;;
      *)
        # Collect console output only if we're processing a test case
        [ -n "$test_name" ] && test_result+="$line"$'\n'
        ;;
    esac
  done < "$feedback_file"

  # Convert summary.xml to JUnit format using xsltproc
  cat << "_EOL" | xsltproc -o "$junit_xml" --stringparam target "${TEST_SUITE}" - $summary_xml || true
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
 <xsl:output indent="yes" cdata-section-elements="failure"/>
 <xsl:template match="results">
   <testsuites>
     <testsuite name="{$target}" tests="{count(scenario)}" failures="{count(scenario/result[text()='fail'])}">
       <xsl:apply-templates select="scenario"/>
     </testsuite>
   </testsuites>
 </xsl:template>
 <xsl:template match="scenario">
   <testcase name="{case}" time="{elapsetime div 1000}">
     <xsl:if test="result='fail'">
       <failure message="{failure_message}">
         <xsl:value-of select="error_content"/>
       </failure>
     </xsl:if>
     <xsl:if test="result='skip'">
       <skipped message="{skip_reason}"/>
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
  
  if [ -n "$baseline" ]; then
    # If baseline is provided, pass it to manual_test_result
    debug "Using provided baseline: $baseline" "$LINENO"
    java -cp $CUBRID/jdbc/cubrid_jdbc.jar:/manual_test_result.jar manual_test_result $baseline $xml_output/test-${TEST_SUITE}.xml
    mv -f $baseline*.csv $xml_output
  else
    # If baseline is not provided, let manual_test_result find the latest version
    debug "No baseline provided, using latest from DB" "$LINENO"
    java -cp $CUBRID/jdbc/cubrid_jdbc.jar:/manual_test_result.jar manual_test_result $xml_output/test-${TEST_SUITE}.xml
    # Move all CSV files that were generated
    mv -f *.csv $xml_output 2>/dev/null || true
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
