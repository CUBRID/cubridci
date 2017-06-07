#!/bin/bash -xe

if [ ! -d cubrid ]; then
  echo "Cannot find source directory!"
  exit 1
fi

if [ -d cubrid/build ]; then
  rm -rf cubrid/build
fi

mkdir -p cubrid/build && cd cubrid/build
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=$CUBRID ..
cmake --build . | tee build.log | grep -e '\[[ 0-9]\+%\]' -e ' error: ' && make install || tail -500 build.log
