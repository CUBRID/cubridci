#!/bin/bash -xe

if [ ! -d cubrid-testtools ]; then
  git clone --depth 1 --branch $BRANCH_TESTTOOLS https://github.com/CUBRID/cubrid-testtools
fi
if [ ! -d cubrid-testcases ]; then
  git clone --depth 1 --branch $BRANCH_TESTCASES https://github.com/CUBRID/cubrid-testcases
fi

if [ ! -d cubrid-testtools -o ! -d cubrid-testcases ]; then
  echo "Cannot find test tool or cases directory!"
  exit 1
fi

for t in ${TEST_SUITE//:/ }; do
  cubrid-testtools/CTP/bin/ctp.sh $t
done

print_failed.sh cubrid-testtools/CTP/sql/result
