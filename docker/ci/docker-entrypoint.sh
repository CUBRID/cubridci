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
  if [ "$1" = "-x" ]; then
    xml_output="$2"
    mkdir -p "$xml_output"
    shift 2
  fi

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

  if [ -n "$xml_output" ]; then
    # CTP writes its own JUnit report (<os>_<type>_<bits>.xml, e.g. linux_sql_64bit.xml)
    # next to summary.xml since cubrid-testtools#769. Collect it for store_test_results;
    # per-case failure details (query, diff, source links) live in its <failure> CDATA
    # and are shown in the CircleCI 'Tests' tab, so they are no longer printed here.
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
      echo " - ${f##*$WORKDIR/cubrid-testcases/}"
    done
    echo "** See the CircleCI 'Tests' tab for per-case queries, diffs and source links."
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
