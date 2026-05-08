#!/bin/bash -le

function run_checkout ()
{
  if [ ! -d $WORKDIR/cubrid-testtools ]; then
    git clone -q --depth 1 --branch $BRANCH_TESTTOOLS https://github.com/CUBRID/cubrid-testtools $WORKDIR/cubrid-testtools
  elif [ -d $WORKDIR/cubrid-testtools/.git ]; then
    (cd $WORKDIR/cubrid-testtools && \
     git fetch -q --depth 1 origin $BRANCH_TESTTOOLS && \
     git reset --hard FETCH_HEAD && \
     git clean -df)
  else
    echo "Cannot find .git from $WORKDIR/cubrid-testtools directory!"
    return 1
  fi
  if [ ! -d $WORKDIR/cubrid-testcases ]; then
    git clone -q --depth 1 --branch $BRANCH_TESTCASES https://github.com/CUBRID/cubrid-testcases $WORKDIR/cubrid-testcases
  elif [ -d $WORKDIR/cubrid-testcases/.git ]; then
    (cd $WORKDIR/cubrid-testcases && \
     git fetch -q --depth 1 origin $BRANCH_TESTCASES && \
     git reset --hard FETCH_HEAD && \
     git clean -df)
  else
    echo "Cannot find .git from $WORKDIR/cubrid-testcases directory!"
    return 1
  fi
}

function run_test ()
{
  if [ -z "$CIRCLECI" ]; then
    run_checkout
  else
    echo "[info] Skipping run_checkout in run_test on CircleCI"
  fi

  if [ ! -x "$CUBRID/bin/cubrid_rel" ]; then
    echo "[error] CUBRID is not installed at $CUBRID. Install before invoking 'test'."
    exit 1
  fi

  for t in ${TEST_SUITE//:/ }; do
    case "$t" in
      medium)
        # CUBRIDQA-1093/CUBRID 11.x: medium_dev.conf has create_table_reuseoid=no baked in.
        (cd $WORKDIR/cubrid-testtools && HOME=$WORKDIR CTP/bin/ctp.sh medium -c $CTP_HOME/conf/medium_dev.conf)
        ;;
      *)
        (cd $WORKDIR/cubrid-testtools && HOME=$WORKDIR CTP/bin/ctp.sh $t)
        ;;
    esac
  done

  if [[ ":$TEST_SUITE:" =~ :(medium|sql): ]]; then
    report_test -x $TEST_REPORT $WORKDIR/cubrid-testtools/CTP/sql/result
  fi
}

function report_test ()
{
  local ncount=0
  local max_print_failed=50

  while getopts "x:n:" opt; do
    case $opt in
      x)
        xml_output="$OPTARG"
        [ ! -d "$xml_output" ] && mkdir -p "$xml_output"
        ;;
      n)
        max_print_failed=$OPTARG
        ;;
      *)
        ;;
    esac
  done
  shift $(($OPTIND - 1))

  if [ $# -lt 1 ]; then
    return 1
  fi
  result_path=$1
  if [ ! -d $result_path ]; then
    echo "Result path '$result_path' does not exist."
    return 1
  fi

  #In case of testing nothing due to an error like failure to load a library.
  if [ `find $result_path -type f -name summary_info | wc -l` -eq 0 ]; then
     echo "Nothing is tested because of an error."
     exit 1
  fi


  failed_list=$(find $result_path -name summary_info | xargs -n1 grep -hw nok | awk -F: '{print $1}')
  if [ -z "$failed_list" ]; then
    nfailed=0
  else
    nfailed=$(echo "$failed_list" | wc -l)
  fi
  echo ""
  if [ $max_print_failed -ne 0 -a $nfailed -gt $max_print_failed ]; then
    echo "** There are too many failed ($nfailed) Testcases on this test."
    echo "** It will print details of only $max_print_failed failed Testcases."
  elif [ $nfailed -gt 0 ]; then
    echo "** There are $nfailed failed Testcases on this test."
    echo "** It will print details of $nfailed failed Testcases."
  fi
  echo ""

  testcases_root_dir="$WORKDIR/cubrid-testcases"
  testcases_remote_url=$(cd $testcases_root_dir && git config --get remote.origin.url)
  testcases_hash=$(cd $testcases_root_dir && git rev-parse HEAD)
  testcases_base_url="${testcases_remote_url%.git}/blob/$testcases_hash"

  for f in $failed_list; do
    casefile=$f
    answerfile=${f/\/cases\//\/answers\/}
    answerfile=${answerfile/%.sql/.answer}
    resultfile=${f/%.sql/.result}
    reportfile=${f/%.sql/.report} && echo "<failure message='unexpected result'><![CDATA[" > $reportfile

    ncount=$((ncount+1))
    printf "%115s\n" "($ncount/$nfailed)" | tr ' ' '-'
    testcases_case_url="$testcases_base_url/${casefile##*$testcases_root_dir/}"
    testcases_answer_url="$testcases_base_url/${answerfile##*$testcases_root_dir/}"
    echo "** Testcase : ${casefile##*$testcases_root_dir/} - $testcases_case_url" | tee -a $reportfile
    echo "** Expected : ${answerfile##*$testcases_root_dir/} - $testcases_answer_url" | tee -a $reportfile
    echo "** Difference between Expected(-) and Actual(+) results:"
    diff -ut $answerfile $resultfile | tee -a $reportfile
    echo "]]></failure>" >> $reportfile

    if [ $max_print_failed -ne 0 -a $ncount -ge $max_print_failed ]; then
      break
    fi
  done

  if [ $max_print_failed -ne 0 -a $nfailed -gt $max_print_failed ]; then
    printf "%115s\n" | tr ' ' '-'
    echo "** More than $max_print_failed failed Testcases are omitted. (There are $nfailed failed Testcases on this test)"
  fi
  echo ""

  if [ -n "$xml_output" ]; then
    summary_xml_list=$(find $result_path -name summary.xml)
    for f in $summary_xml_list; do
      target=$(dirname ${f##*schedule_})
      target=${target%_[0-9]*_*}
      build_mode=$(cubrid_rel | grep -oe 'release\|debug')
      cat << "_EOL" | xsltproc -o "$xml_output/${target}.xml" --stringparam target "${target}_${build_mode}" --stringparam casedir "${testcases_root_dir}/" - $f || true
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
 <xsl:output indent="yes" cdata-section-elements="failure"/>
 <xsl:template match="results">
   <testsuites>
     <testsuite name="{$target}" tests="{count(scenario)}" failures="{count(scenario/result[contains(.,'fail')])}">
       <xsl:apply-templates select="scenario"/>
     </testsuite>
   </testsuites>
 </xsl:template>
 <xsl:template match="scenario">
   <testcase classname="{$target}" name="{case}" file="cubrid-testcases/{case}" time="{elapsetime div 1000}">
      <xsl:if test="result='fail'">
        <xsl:variable name="testcase" select="case"/>
        <xsl:variable name="report" select="concat($casedir, substring-before($testcase, '.sql'), '.report')"/>
        <xsl:copy-of select="document($report)"/>
      </xsl:if>
   </testcase>
 </xsl:template>
</xsl:stylesheet>
_EOL
    done
  fi

  if [ $nfailed -gt 0 ]; then
    echo "** There are $nfailed failed Testcases on this test."
    echo "** All failed Testcases are listed below:"
    for f in $failed_list ; do
      echo " - ${f##*$testcases_root_dir/}"
    done
    echo "** $nfailed cases are failed."
    exit $nfailed
  else
    echo "** All Tests are passed"
  fi
}

case "$1" in
  "")
    echo "Usage: /entrypoint.sh {checkout|test} | <command>"
    exit 1
    ;;
  checkout)
    set -- run_checkout
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
