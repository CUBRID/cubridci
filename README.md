[![image size](https://img.shields.io/docker/image-size/cubridci/cubridci/test_rl8.10?label=image%20size)](https://hub.docker.com/r/cubridci/cubridci/tags?name=test_rl8.10)

# CUBRID test image — Rocky Linux 8.10

This branch defines `cubridci/cubridci:test_rl8.10`, the image that runs the CUBRID QA
categories through CTP. It unifies the two older test images, `test_shell` and
`test_sqlmedium`, into one image that covers every category below.

**CUBRID is not baked in.** The image carries the CTP runtime and its OS dependencies only.
Inject a build into `$CUBRID` before running a test. To produce that build, use the
[`build_rl8.10`](https://github.com/CUBRID/cubridci/tree/build_rl8.10) branch and its image.

The image definition is `docker/ci/` — `Dockerfile` and `docker-entrypoint.sh`.

## The tag

Jenkins multibranch on `ci.cubrid.org` builds `docker/ci` on every push to this branch and
pushes the result as `cubridci/cubridci:test_rl8.10`. The tag appears on Docker Hub about a
minute after the push. A new branch needs no job registration — Jenkins picks it up on its own.
Jenkins itself is reachable only from the internal network.

|            |                                                                                       |
| ---------- | ------------------------------------------------------------------------------------- |
| Base       | `rockylinux/rockylinux:8.10`                                                           |
| Size       | 751 MB on disk, 254 MiB to pull                                                        |
| Runtime    | JDK 8 (`java-1.8.0-openjdk-devel`), gcc/g++, make, gdb, git                             |
| Tools      | csh, expect, dos2unix, lcov, bc, jq, lsof, file, diffutils, net-tools, telnet, wget    |
| ssh        | `openssh-server` with host keys generated; CTP reaches nodes and shell cases over ssh   |
| Locales    | `en_US.UTF-8`, `ko_KR.UTF-8`, `ko_KR.EUC-KR`                                            |
| TZ         | `Asia/Seoul`                                                                           |
| Node acct  | `qa` (`$NODE_USER`), no password baked in — see [Multi-node categories](#multi-node-categories) |

The toolchain stays in the image on purpose: several categories compile at run time. isolation
builds ctltool with make and gcc, ha_repl and cdc_repl build their helpers with gcc, and the
jdbc category compiles cases with javac.

## Usage

```
/entrypoint.sh checkout [<category>]
/entrypoint.sh test [<category>]
/entrypoint.sh node
/entrypoint.sh <command> [<args>...]
```

One category per run. The argument overrides `$TEST_SUITE`; give it either way.

| Verb       | What it does                                                                         |
| ---------- | ------------------------------------------------------------------------------------ |
| `checkout` | Clones `cubrid-testtools` and the category's test-cases repo into `/home`. Retries five times with a growing delay. |
| `test`     | Runs the category through CTP, collects JUnit XML, and judges the result.              |
| `node`     | Prepares this container as a CTP node and waits. Needed on every host the controller does not run on. |

`test` never checks out on its own — run `checkout` first. `$GHI_TOKEN` lives inside `checkout`
only; the git credential is removed when `checkout` exits, so the test step never sees it.

### Categories

| Category     | Test cases repo               | `GHI_TOKEN` | Cases            | One container  | JUnit XML |
| ------------ | ----------------------------- | ----------- | ---------------- | -------------- | --------- |
| `sql`        | `cubrid-testcases`            | no          | 17,451           | about 30 min   | yes       |
| `medium`     | `cubrid-testcases`            | no          | 975              | about 3 min    | yes       |
| `shell`      | `cubrid-testcases-private-ex` | **yes**     | 3,468 case dirs  | tens of hours  | yes       |
| `isolation`  | `cubrid-testcases`            | no          | 6,778            | 5 to 9 hours   | no        |
| `sql_by_cci` | `cubrid-testcases`            | no          | 17,451           | about 41 min   | no        |
| `jdbc`       | `cubrid-testcases-private`    | **yes**     | 2,407            | about 3 min    | yes       |
| `ha_repl`    | `cubrid-testcases`            | no          | scenario-driven  | see below      | no        |

`shell` and `isolation` are too slow to run whole in one container; split them across
containers by scenario directory. The other categories finish in one run.

`ha_repl` runs whatever `$HA_SCENARIO` points at, and CTP converts those SQL cases to their HA
form. The whole default scenario is large: `sql/_01_object` alone is 3,327 cases and took
2 hours 30 minutes on two containers.

`ha_repl` needs two hosts. Every other category runs in a single container.

### Environment

| Variable            | Default                    | Used by                                     |
| ------------------- | -------------------------- | ------------------------------------------- |
| `TEST_SUITE`        | (empty)                    | `checkout`, `test` — the category           |
| `BRANCH_TESTTOOLS`  | `develop`                  | `checkout` — `cubrid-testtools` branch      |
| `BRANCH_TESTCASES`  | `develop`                  | `checkout` — test-cases branch              |
| `GHI_TOKEN`         | (unset)                    | `checkout` of a private repo; required for `shell` and `jdbc` |
| `TEST_REPORT`       | `/tmp/tests`               | `test` — where JUnit XML is collected       |
| `HA_NODE_PASSWORD`  | (unset)                    | `node`, and `test ha_repl` — password for the `qa` account |
| `HA_SLAVE_HOST`     | (unset)                    | `test ha_repl` — hostname of the slave node |
| `HA_SCENARIO`       | `/home/cubrid-testcases/sql` | `test ha_repl` — scenario path             |

Paths the image fixes: `$WORKDIR` = `/home`, `$CUBRID` = `/home/CUBRID`,
`$CTP_HOME` = `/home/cubrid-testtools/CTP`.

### Result and exit code

`test` exits 0 when every case passed and 1 otherwise. It does not trust CTP's own exit code —
several runners return 0 even when cases fail, or when java died with an exception. The verdict
comes from the runner's own result file: `summary_info` for sql and medium, `summary.info` for
sql_by_cci, `test_status.data` for shell, isolation, jdbc and ha_repl. A run in which no case
started is a failure, not a pass.

JUnit XML from the run is copied into `$TEST_REPORT`. Three categories write no XML —
isolation, sql_by_cci and ha_repl — and for those `test` prints one warning line and judges the
run from the result file as usual.

### Run a container

`sql`, a public repo, so no token:

```bash
docker run --rm \
  -v "$PWD/CUBRID:/home/CUBRID" \
  -v "$PWD/reports:/tmp/tests" \
  cubridci/cubridci:test_rl8.10 \
  bash -lc '/entrypoint.sh checkout sql && /entrypoint.sh test sql'
```

`jdbc`, a private repo, so a token:

```bash
docker run --rm \
  -v "$PWD/CUBRID:/home/CUBRID" \
  -v "$PWD/reports:/tmp/tests" \
  -e GHI_TOKEN \
  cubridci/cubridci:test_rl8.10 \
  bash -lc '/entrypoint.sh checkout jdbc && /entrypoint.sh test jdbc'
```

`/home/CUBRID` must hold an installed CUBRID tree — `bin/cubrid_rel` has to be executable, and
`test` refuses to start without it.

To keep the container up and run several categories by hand, give it a PID 1 that reaps
zombies:

```bash
docker run -d --name cubrid-test \
  -v "$PWD/CUBRID:/home/CUBRID" \
  cubridci/cubridci:test_rl8.10 \
  bash -c 'while :; do sleep 3600 & wait $!; done'

docker exec cubrid-test /entrypoint.sh checkout medium
docker exec cubrid-test /entrypoint.sh test medium
```

`sleep` alone as PID 1 does not reap. Without a reaper, the `cub_server` of the first run stays
a zombie and the second run hangs in `cubrid server stop`, waiting on it forever.

### Multi-node categories

`ha_repl` needs two containers, and **their hostnames must differ**. CTP builds its
`ha_node_list` by running `hostname` over ssh on each node, so a single container — and a single
pod with two containers, which shares the UTS namespace — cannot host both. One host runs the
controller and the master; the other runs the slave.

Both need the same `HA_NODE_PASSWORD`. CTP authenticates to nodes by password only, so the `qa`
account gets its password at run time from that variable; the image bakes in none.

**Start the slave first**, then the master:

```bash
# slave
docker run -d --name han2 --hostname han2 \
  -v "$PWD/CUBRID:/home/CUBRID" \
  -e HA_NODE_PASSWORD \
  cubridci/cubridci:test_rl8.10 \
  bash -lc '/entrypoint.sh checkout ha_repl && /entrypoint.sh node'

# controller and master
docker run --rm --name han1 --hostname han1 \
  -v "$PWD/CUBRID:/home/CUBRID" \
  -e HA_NODE_PASSWORD \
  -e HA_SLAVE_HOST=han2 \
  -e HA_SCENARIO=/home/cubrid-testcases/sql/_01_object \
  cubridci/cubridci:test_rl8.10 \
  bash -lc '/entrypoint.sh checkout ha_repl && /entrypoint.sh test ha_repl'
```

The two containers must resolve each other by hostname. A docker or nerdctl bridge network
writes the peer into `/etc/hosts` for you. In Kubernetes, put the two pods behind a headless
Service and add `dnsConfig.searches`, or use `hostAliases`.

`test ha_repl` writes `conf/ha_repl_ci.conf` itself, because the master and slave hostnames are
only known at run time. It passes the nightly regression's exclude list —
`sql/config/daily_regression_test_exclude_list_ha_repl.conf`, 202 cases — so this image and the
nightly run agree on which cases are known to fail.

The node account is deliberately not `root`. CTP's cleanup kills every process owned by the node
account except its own ancestors, so a node running as the same user as the controller kills the
controller.

## Known limits

**Give the containers a cgroup without tight limits.** One CUBRID server uses about 219
threads. Two servers under a single systemd slice capped at 8 GiB and 1000 pids run out of
both, and the server that starts second aborts on `pthread_create`. With `nerdctl` or `docker`
on a Kubernetes node, pass `--cgroup-parent=qatest.slice` to leave `/system.slice`; the systemd
cgroup driver wants the name without a leading slash. In Kubernetes, set pod limits with room
to spare.

**Known failures, by category.** These are product or test-data matters, not image matters:

| Category     | Cases                                                                | Why |
| ------------ | -------------------------------------------------------------------- | --- |
| `sql`        | `_35_fig_cake/grant_revoke_redefine`: `cbrd_25486_05`, `cbrd_25596`  | Flaky only in a whole-suite run — every case shares one `basic` database. A partial run passes. |
| `isolation`  | `_01_ReadCommitted/dml_ddl`: `altertable_update_02`, `droptable_update_01`; `_02_RepeatableRead/dml_ddl/altertable_update_02` | Product issue CBRD-26983, already in the nightly regression. |
| `isolation`  | 13 cases whose `.answer` holds only an issue key                     | No expected output exists, so they cannot pass. They also dominate the wall clock: each burns the 300-second case timeout five times over. |
| `sql_by_cci` | 13 cases that have an `.answer_cci`                                  | NUMERIC precision and a `%TYPE` return error. |
| `jdbc`       | `TestAPIS833.test1()`, `TestAPIS833.test3()`, `TestCUBRIDDataSource.test2()` | Known failures. |
| `jdbc`       | `testsuite/simple/StatementsTest.testCancelStatement`                | Never finishes. `Statement.cancel()` does not take effect and the runner has no per-case timeout. Exclude it, or the run hangs forever. |
| `ha_repl`    | 202 cases in the nightly exclude list                                | Excluded automatically. |

**`sql_by_cci` compares against a different answer file.** Where a case has an `.answer_cci`
next to it, the cci runner uses that instead of `.answer` — the cases whose cci output differs
from the jdbc output were split off that way. When reading a `sql_by_cci` failure, check which
answer file it was compared against first.

**A JUnit XML absence is not an error.** isolation, sql_by_cci and ha_repl write none.

**There is no entry point for a case list yet.** `$HA_SCENARIO` becomes CTP's `scenario=`, which
is a single directory. Splitting a category across containers means splitting it by scenario
directory.
