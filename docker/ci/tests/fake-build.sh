#!/bin/bash
set -eu

printf '[ci-prebuilt-3rdparty] fake-build mode=%s root=%s args=' \
  "${CUBRID_3RDPARTY_MODE:-unset}" "${CUBRID_3RDPARTY_ROOT:-unset}"
printf '<%s>' "$@"
printf '\n'
