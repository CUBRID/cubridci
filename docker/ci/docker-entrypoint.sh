#!/bin/bash -e

function run_checkout ()
{
  if [ ! -d cubrid-testtools ]; then
    git clone -q --depth 1 --branch $BRANCH_TESTTOOLS https://github.com/CUBRID/cubrid-testtools $WORKDIR/cubrid-testtools
  fi
  if [ ! -d cubrid-testcases ]; then
    git clone -q --depth 1 --branch $BRANCH_TESTCASES https://github.com/CUBRID/cubrid-testcases $WORKDIR/cubrid-testcases
  fi

}

function run_build ()
{
  if [ ! -d cubrid ]; then
    echo "Cannot find source directory!"
    return 1
  fi

  if [ -d cubrid/build ]; then
    rm -rf cubrid/build
  fi

  cmake -E make_directory cubrid/build
  cmake -E chdir cubrid/build cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=$CUBRID ..
  cmake --build cubrid/build --target install | tee build.log | grep -e '\[[ 0-9]\+%\]' -e ' error: ' || { tail -500 build.log; false; }
}

function run_test ()
{
  if [ ! -d $WORKDIR/cubrid-testtools -o ! -d $WORKDIR/cubrid-testcases ]; then
    run_checkout
  fi

  for t in ${TEST_SUITE//:/ }; do
    (cd $WORKDIR/cubrid-testtools && HOME=$WORKDIR CTP/bin/ctp.sh $t)
  done

  if [[ ":$TEST_SUITE:" =~ :(medium|sql): ]]; then
    report_test -x $TEST_REPORT cubrid-testtools/CTP/sql/result
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

  for f in $failed_list; do
    casefile=$f
    answerfile=${f/\/cases\//\/answers\/}
    answerfile=${answerfile/%.sql/.answer}
    resultfile=${f/%.sql/.result}

    diffdir=$(mktemp -d)
    #egrep -v '^--|^$' $casefile | csplit -n0 -sz -f $diffdir/testcase - '/;/' '{*}'
    egrep -v $'^--|^\s*$|^autocommit|^\r' $casefile | awk -v outdir="$diffdir" '{printf "%s;\n", $0 > outdir"/testcase"NR-1}' RS=';[ \t\r]*\n'
    nq=$(ls $diffdir/testcase* | wc -l)
    csplit -n0 -sz -f $diffdir/answer $answerfile '/===================================================/' '{*}'
    na=$(ls $diffdir/answer* | wc -l)
    csplit -n0 -sz -f $diffdir/result $resultfile '/===================================================/' '{*}'
    nr=$(ls $diffdir/result* | wc -l)

    ncount=$((ncount+1))
    printf "%115s\n" "($ncount/$nfailed)" | tr ' ' '-'
    echo "** Testcase : ${casefile##*$WORKDIR/} (has $nq queries)"
    echo "** Expected : ${answerfile##*$WORKDIR/}"
    #echo "** Actual   : ${resultfile##*$WORKDIR/}"
    [ $nq -eq $na -a $nq -eq $nr ] || { echo "Parse error ($nq != $na != $nr)"; return 1; }
    for i in $(awk "BEGIN { for (i=0; i<$nq; i++) printf(\"%d \", i) }"); do
      if $(cmp -s $diffdir/answer$i $diffdir/result$i) ; then
        continue
      else
        echo "** Failed query #$((i+1)) (in $(basename $casefile)):"
        cat $diffdir/testcase$i
        echo "** Difference between Expected(-) and Actual(+) results:"
        diff -u $diffdir/answer$i $diffdir/result$i | tail -n+3
      fi
    done
    rm -rf $diffdir

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
      target=${target%_*}
      cat << "_EOL" | xsltproc -o "$xml_output/${target}.xml" --stringparam target "${target}" - $f || true
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
 <xsl:output indent="yes"/>
 <xsl:template match="results">
   <testsuites>
     <testsuite name="{$target}" tests="{count(scenario)}" failures="{count(scenario/result[contains(.,'fail')])}">
       <xsl:apply-templates select="scenario"/>
     </testsuite>
   </testsuites>
 </xsl:template>
 <xsl:template match="scenario">
   <testcase classname="{$target}" name="{case}" time="{elapsetime div 1000}">
      <xsl:if test="result='fail'">
        <failure message="failed"/>
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
      echo " - ${f##*$WORKDIR/}"
    done
    echo "** $nfailed cases are failed."
    exit $nfailed
  else
    echo "** All Tests are passed"
  fi
}

function get_jenkins ()
{
  if [ -z "$JENKINS_URL" ]; then
    while [ $# -gt 0 ]; do
      case "$1" in
        -url)
          JENKINS_URL="$2"; break ;;
      esac
      shift
    done
  fi
  if [ -z "$JENKINS_URL" ]; then
    echo "Cannot find jenkins url from arguments"
    return 1
  fi
  curl --create-dirs -sSLo jenkins/slave.jar $JENKINS_URL/jnlpJars/slave.jar
}

function run_default ()
{
  run_build && run_test
}

case "$1" in
  "")
    set -- run_default
    ;;
  checkout)
    set -- run_checkout
    ;;
  build)
    set -- run_build
    ;;
  test)
    set -- run_test
    ;;
  jenkins-slave)
    shift
    get_jenkins "$@"
    set -- java $JAVA_OPTS -cp jenkins/slave.jar hudson.remoting.jnlp.Main -headless "$@"
    ;;
esac

if [ -n "$(type -t $1)" -a "$(type -t $1)" = function ]; then
  eval "$@"
else
  exec "$@"
fi
