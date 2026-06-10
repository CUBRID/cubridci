#!/bin/bash -le

function run_checkout ()
{
  if [ ! -d $WORKDIR/cubrid-testtools ]; then
    git clone -q --depth 1 --branch $BRANCH_TESTTOOLS https://github.com/CUBRID/cubrid-testtools $WORKDIR/cubrid-testtools
  elif [ -d $WORKDIR/cubrid-testtools/.git ]; then
    (cd $WORKDIR/cubrid-testtools && git clean -df)
  else
    echo "Cannot find .git from $WORKDIR/cubrid-testtools directory!"
    return 1
  fi
  if [ ! -d $WORKDIR/cubrid-testcases ]; then
    git clone -q --depth 1 --branch $BRANCH_TESTCASES https://github.com/CUBRID/cubrid-testcases $WORKDIR/cubrid-testcases
  elif [ -d $WORKDIR/cubrid-testcases/.git ]; then
    cd $WORKDIR/cubrid-testcases && \
    git fetch -q --depth 1 origin $BRANCH_TESTCASES && \
    git reset --hard FETCH_HEAD && \
    git clean -df
  else
    echo "Cannot find .git from $WORKDIR/cubrid-testcases directory!"
    return 1
  fi

}

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

  (cd $CUBRID_SRCDIR \
    && ./build.sh -p $CUBRID $@ clean build) | tee build.log | grep -e '\[[ 0-9]\+%\]' -e ' error: ' -e '\[[0-9]\+\/[0-9]\+\]' || { tail -500 build.log; false; }

  grep "Building failed" $CUBRID_SRCDIR/build.log && exit 1 || { true; }  
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

function run_test ()
{
  if [ -z "$CIRCLECI" ]; then
    run_checkout
  else
    echo "[info] Skipping run_checkout in run_test on CircleCI"
  fi

  #CUBRIDQA-1093. disable reuse_oid 
  cd $WORKDIR/cubrid-testtools
  CTP/bin/ini.sh -s sql/cubrid.conf CTP/conf/medium.conf create_table_reuseoid no
  cd -

  for t in ${TEST_SUITE//:/ }; do
    (cd $WORKDIR/cubrid-testtools && HOME=$WORKDIR CTP/bin/ctp.sh $t)
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

    ncount=$((ncount+1))
    printf "%115s\n" "($ncount/$nfailed)" | tr ' ' '-'
    testcases_case_url="$testcases_base_url/${casefile##*$testcases_root_dir/}"
    testcases_answer_url="$testcases_base_url/${answerfile##*$testcases_root_dir/}"
    echo "** Testcase : ${casefile##*$testcases_root_dir/} - $testcases_case_url"
    echo "** Expected : ${answerfile##*$testcases_root_dir/} - $testcases_answer_url"
    echo "** Difference between Expected(-) and Actual(+) results:"
    diff -ut $answerfile $resultfile || true

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
    # CTP writes its own JUnit report (<os>_<type>_<bits>.xml, e.g. linux_sql_64bit.xml)
    # next to summary.xml since cubrid-testtools#769; collect it for store_test_results.
    ncopied=0
    for f in $(find $result_path -name summary.xml); do
      for x in "$(dirname $f)"/*.xml; do
        [ -f "$x" ] || continue
        [ "$(basename $x)" = "summary.xml" ] && continue
        cp -f "$x" "$xml_output/" || true
        ncopied=$((ncopied+1))
      done
    done
    if [ $ncopied -eq 0 ]; then
      echo "[warn] no CTP JUnit XML found under $result_path (requires cubrid-testtools#769)"
    fi
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
    shift
    set -- run_build "$@"
    ;;
  dist)
    shift
    set -- run_dist "$@"
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
