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
| Size       | 786 MB on disk, 266 MiB to pull                                                        |
| Runtime    | JDK 8 (`java-1.8.0-openjdk-devel`), gcc/g++, make, gdb, git, valgrind                   |
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
/entrypoint.sh coverage [<category>]
/entrypoint.sh <command> [<args>...]
```

One category per run. The argument overrides `$TEST_SUITE`; give it either way.

| Verb       | What it does                                                                         |
| ---------- | ------------------------------------------------------------------------------------ |
| `checkout` | Clones `cubrid-testtools` and the category's test-cases repo into `/home`. Retries five times with a growing delay. `rqg` gets a third repo, narrowed to the one directory it needs. |
| `test`     | Runs the category through CTP, collects JUnit XML, and judges the result.              |
| `node`     | Prepares this container as a CTP node and waits. Needed on every host the controller does not run on. |
| `coverage` | Writes an lcov file for this container alone. `test` collects the controller itself and runs this on the other nodes, so it is only for collecting by hand. |

`test` never checks out on its own — run `checkout` first. `$GHI_TOKEN` lives inside `checkout`
only; the git credential is removed when `checkout` exits, so the test step never sees it.

### Categories

| Category      | Test cases repo               | `GHI_TOKEN` | Cases           | One container | JUnit XML |
| ------------- | ----------------------------- | ----------- | --------------- | ------------- | --------- |
| `sql`         | `cubrid-testcases`            | no          | 17,451          | about 30 min  | yes       |
| `medium`      | `cubrid-testcases`            | no          | 975             | about 3 min   | yes       |
| `shell`       | `cubrid-testcases-private-ex` | **yes**     | 3,468 case dirs | tens of hours | yes       |
| `shell_heavy` | `cubrid-testcases-private-ex` | **yes**     | 142             | hours         | yes       |
| `shell_long`  | `cubrid-testcases-private`    | **yes**     | 131             | days          | yes       |
| `cci`         | `cubrid-testcases-private`    | **yes**     | 322             | 90 min (est.) | yes       |
| `isolation`   | `cubrid-testcases`            | no          | 6,778           | 5 to 9 hours  | no        |
| `sql_by_cci`  | `cubrid-testcases`            | no          | 17,451          | about 41 min  | no        |
| `jdbc`        | `cubrid-testcases-private`    | **yes**     | 2,407           | about 3 min   | yes       |
| `ha_repl`     | `cubrid-testcases`            | no          | scenario-driven | see below     | no        |
| `ha_shell`    | `cubrid-testcases-private`    | **yes**     | 373 case dirs   | see below     | yes       |
| `rqg`         | `cubrid-testcases-private`    | **yes**     | 104             | hours (est.)  | yes       |

`shell`, `shell_heavy`, `shell_long`, `isolation`, `ha_shell` and `rqg` are too slow to run
whole in one run; split them by scenario directory. The other categories finish in one run.

`shell_heavy` and `shell_long` are the shell runner over other case trees — `shell_heavy` for
cases that need a lot of disk or memory, `shell_long` for cases that take an hour or more
each. CTP ships no conf for either, so `test` derives one from `conf/shell_ci.conf` and
overrides five keys: the scenario, its exclude list, the case timeout (7,200 s for
`shell_heavy`, 54,000 s for `shell_long`), the retry count (0) and the report label. Point
`$SHELL_SCENARIO` at a subdirectory to run part of a tree. Their results land under
`result/shell/`, like `shell`, but the JUnit XML is named after the category.

`cci` tests the CCI driver itself: every case compiles a small C program against
`$CUBRID/include` and `libcascci` and then runs it. It is not `sql_by_cci`, which runs the SQL
cases through cci instead of jdbc. It is another shell variant, so its conf is derived from
`conf/shell_ci.conf` like the others, with the nightly regression's case timeout of 7,200 s and
no retry. **It passes no exclude list.** There is no general one in the cases repo — not on any
of its 57 branches — and the only lists there belong to the driver-server compatibility test,
which are keyed by version and stop at 11.2.0. The nightly names a list that is not in the repo
at all and gets away with it because it does not run cci through CTP; CTP refuses to start when
that key points at a missing file, so the key is left empty instead. `$SHELL_SCENARIO` runs part of the tree. Results land under
`result/shell/`, and the report is `test-cci.xml`. A run over more than one case shares one
`ccidb` database, and that costs cases — see the known failures below.

`ha_repl` runs whatever `$HA_SCENARIO` points at, and CTP converts those SQL cases to their HA
form. The whole default scenario is large: `sql/_01_object` alone is 3,327 cases and took
2 hours 30 minutes on two containers.

`ha_shell` is the shell runner over `HA/shell`, so it is derived from `conf/shell_ci.conf` the
same way `shell_heavy` and `shell_long` are, with a 7,200 s case timeout — CTP's own
`conf/ha_shell.conf` holds nothing but comments and a scenario pointing at the public cases
repo. On top of the five shell keys it writes the master node as an env instance and the slave
as that instance's `relatedhosts`; the ports and the HA port come from the `default.*` keys it
inherits. Each case builds its own HA pair by calling `setup_ha_environment` from
`$init_path/make_ha.sh`, which reaches the slave over ssh. `$SHELL_SCENARIO` runs part of the
tree, and the report is `test-ha_shell.xml` under `result/shell/`.

`rqg` generates random queries against a database and checks that the server survives them.
It is the shell runner again — CTP routes `rqg` through it and only splits the result directory
apart — so its conf comes from `conf/shell_ci.conf` like the other shell variants, with the
nightly regression's case timeout of 36,000 s and its exclude list,
`random_query_generator/config/daily_regression_test_exclude_list_RQG.conf`, which is empty
upstream — so nothing is excluded, and the one known failure below is enough to make a
whole-tree run exit 1.
`$SHELL_SCENARIO` runs part of the tree. Results land under `result/rqg/`, and the report is
`test-rqg.xml`.

The generator itself is not in the test-cases repo. It is perl, it lives in
`cubrid-testtools-internal`, and `checkout rqg` fetches that repo too; `test rqg` points
`$RQG_HOME` at it. That repo is 1.1 GB and rqg needs 5.5 MB of it, so the clone is filtered
down to `random_query_generator` alone; `--depth 1` by itself still fetches every blob at that
depth.
The tool reaches CUBRID from perl through `DBI` and `DBD::cubrid`, both of which the image
carries. `checkout` also patches one line of the tool: `GenTest/Properties.pm` uses
`defined(@array)`, which perl 5.22 turned into a fatal error, so the tool cannot start
unpatched. If the patch ever finds nothing left to do because the tool was fixed upstream,
`checkout` still succeeds — it checks the file, not the edit.

**`rqg` needs a build with debug symbols**, the same as a memory-leak run. Its cases kill the
server in the middle of a run and then count the cores it left, and the `fault_injection` cases
hand those cores to CTP's `analyzer.sh`, which comes with the `cubrid-testtools` checkout and
is already on `$PATH`; a release build is `-O2 -DNDEBUG` with no `-g`, so nothing readable comes
out of them and the run passes anyway. `test` reads the build type out of
`cubrid_rel` and refuses anything that is not a `debug` or `optdebug` build. Inject what the CI
publishes as its debug artifact.

**Inject a fresh CUBRID for every rqg run.** The runner deletes
`$CUBRID/lib/libcubrid_all_locales.so` before each case, so a build whose
`conf/cubrid_locales.txt` still lists locales loses the library those entries need and
`createdb` fails — with a locale error, then a chain of connection failures that read like
something else entirely. A freshly installed build has that file empty, so this only bites when
one build is reused across runs. The image cannot prevent it: pre-building the library does not
help when the runner removes it, and `conf/` is restored from the runner's own snapshot.

`ha_repl` and `ha_shell` need two hosts. Every other category runs in a single container.

### Memory-leak runs

`MEMORY_LEAK=yes` runs `sql` or `medium` under valgrind. It is not a category of its own: CTP
reads `enable_memory_leak` from the `[sql]` section of the conf, and the SQL runner then starts
the server and the broker through valgrind's memcheck. No other category reads that key.

**It needs a build with debug symbols.** A release build is `-O2 -DNDEBUG` with no `-g`, so
memcheck can only report bare addresses — the run would still finish and pass, leaving reports
nothing can be read out of. `test` reads the build type out of `cubrid_rel` and refuses anything
that is not a `debug` or `optdebug` build. What the CI publishes as its debug artifact is an
`optdebug` build, and that is what to inject.

`test` derives `conf/memoryleak_<category>.conf` from the category's own conf and sets three
keys — `enable_memory_leak=yes`, and the two `cubrid.conf` parameters the nightly regression
raises for this run, `log_compress=false` and `shutdown_wait_time_in_secs=2147483647`. Under
valgrind a shutdown takes far longer than the default wait allows. Point `$MEMORY_SCENARIO` at
a subdirectory to run part of a tree; the whole of `sql` under valgrind is not practical.

The valgrind logs are collected into `$TEST_REPORT` as `memory_<category>_<build>_<timestamp>/`.
**Leaks do not decide the exit code** — the verdict is the same case-by-case SQL result as a
plain run. Memcheck reports reachable blocks for a healthy server too, and the image has no
baseline to judge them against, so read the reports yourself. A run that produced no report at
all does fail, because the SQL verdict alone would hide it.

```console
$ nerdctl run --rm -v /path/to/CUBRID:/home/CUBRID \
    -e TEST_SUITE=sql -e MEMORY_LEAK=yes \
    -e MEMORY_SCENARIO=/home/cubrid-testcases/sql/_01_object/_01_type/_004_integer \
    cubridci/cubridci:test_rl8.10 test
```

### Code coverage runs

`CODE_COVERAGE=yes` collects gcov data after the run, for **any** category. Unlike a
memory-leak run it needs no conf key and is not a category of its own: the instrumented
binaries write their `.gcda` by themselves.

**It needs a coverage build, and that build's source tree.** Make both in the build image:

```console
$ nerdctl run --rm -v /shared:/out -e GCOV_OUTPUT_DIR=/out \
    cubridci/cubridci:build_rl8.10 bash -lc '/entrypoint.sh checkout develop && /entrypoint.sh coverage'
```

That leaves two archives, named as the code coverage guide names them:

| Archive                                     | Holds                                                  |
| ------------------------------------------- | ------------------------------------------------------ |
| `CUBRID-<version>-gcov-Linux.x86_64.tar.gz`     | the install tree — unpack it so it lands at `/home/CUBRID` |
| `cubrid-<version>-gcov-src-Linux.x86_64.tar.gz` | the source tree with the `.gcno` — unpack it so it lands at `/home/cubrid` |

**Unpack the source archive so its tree lands where it was built.** The `.gcda` paths are
compiled into the binaries, and both images build and test under `/home`, so a tree at
`/home/cubrid` needs no path rewriting at all — neither `GCOV_PREFIX` nor lcov's
`geninfo_adjust_src_path`, which is all the nightly regression's rewriting is for. The archive's
top-level directory is `cubrid`, so `tar -C /home -xzf <source archive>` is the whole of it.
Point `$COVERAGE_SRC` elsewhere only if the build used a different path.

**Unpack it, do not bind-mount a shared tree.** The run writes its `.gcda` into that tree, so
two containers sharing one would mix their results, and the tree would be left dirty for the
next run. Each container needs its own copy.

`test` refuses a build that is not a coverage build — it reads the type out of `cubrid_rel`,
which prints `coverage debug` for one. Every container also clears its own tree of `.gcda`,
because gcov merges into an existing one and the two runs would be mixed together: the
controller before the run starts, and each container again once it has collected — a `node`
container outlives the run that used it.

**CUBRID is stopped before the data is read.** An instrumented process writes its `.gcda` only
when it exits, and no runner reliably stops the server — the SQL runner skips its own cleanup
whenever the run produced a core, and the shell runner never stops anything, since starting and
stopping is the case's job. Anything still running when the container exits is killed with
SIGKILL and its coverage is gone.

**The build type is read again after collecting.** A handful of cases install a release build
over `$CUBRID` from ftp.cubrid.org and are in no exclude list — `shell` `cbrd_26350` and
`ha_shell` `cbrd_24700`, the latter on the slave too. Every case after one of those leaves no
`.gcda` at all, and the collected file would still look like a full run, so `test` fails and
says so. The lcov file is still written, holding what ran before the replacement.

One lcov file per node is collected into `$TEST_REPORT`, named
`cubrid_[<category>]_<user>-<host>_<timestamp>.lcov` — the name the nightly regression's own
collector builds, so the category stays legible. **Merging and publishing are outside this
image**; it stops at the lcov file. Note that cc4c cannot merge these as they are: its
`coverage_monitor.sh` picks files up by a `.info` sidecar naming them, and rewrites their `SF:`
paths against a `cubrid-<build id>` source directory this layout deliberately does not have.
Every node and category here reports the same `/home/cubrid/...` paths, so plain `lcov -a`
merges them with no rewriting at all.

For `ha_repl` and `ha_shell` the slave runs its own server, so it holds coverage the controller
never sees. Give **every** node the same source tree at the same path and `CODE_COVERAGE=yes`;
the controller then collects each node's file over ssh, with the same `qa` account and
`$HA_NODE_PASSWORD` CTP itself uses, and a node it cannot reach fails the run.

`MEMORY_LEAK=yes` and `CODE_COVERAGE=yes` cannot both be on. There is nothing to gain — a
coverage build is already 7.5 times slower and memcheck multiplies that again — and a shutdown
that slow overruns the stop above, which puts the run back into the failure it exists to
prevent.

A coverage build is `-O0 --coverage`, so expect a run to take considerably longer than the same
one on a release build — `medium` took 1,236 s against 164 s on a release build (measured).
The system headers are removed from the file afterwards, which on a real build takes it from
4,267 source files to 1,486 and halves the bytes. Nothing wants them, and cc4c strips the same
`/usr/*` at merge time. The rest of cc4c's remove patterns are publishing policy and stay out —
this file is the raw product coverage.

```console
$ nerdctl run --rm -v /shared:/shared -e TEST_SUITE=medium -e CODE_COVERAGE=yes \
    cubridci/cubridci:test_rl8.10 bash -lc '
      tar -C /home -xzf /shared/CUBRID-*-gcov-Linux.x86_64.tar.gz &&
      tar -C /home -xzf /shared/cubrid-*-gcov-src-Linux.x86_64.tar.gz &&
      /entrypoint.sh checkout && /entrypoint.sh test'
```

### Environment

| Variable            | Default                    | Used by                                     |
| ------------------- | -------------------------- | ------------------------------------------- |
| `TEST_SUITE`        | (empty)                    | `checkout`, `test` — the category           |
| `BRANCH_TESTTOOLS`  | `develop`                  | `checkout` — branch of `cubrid-testtools`, and of `cubrid-testtools-internal` for `rqg` |
| `BRANCH_TESTCASES`  | `develop`                  | `checkout` — test-cases branch              |
| `GHI_TOKEN`         | (unset)                    | `checkout` of a private repo; required for `shell`, `shell_heavy`, `shell_long`, `cci`, `jdbc`, `ha_shell` and `rqg` |
| `TEST_REPORT`       | `/tmp/tests`               | `test` — where JUnit XML, leak reports and lcov files are collected; `node` creates it for the node account |
| `HA_NODE_PASSWORD`  | (unset)                    | `node`, and `test ha_repl` / `test ha_shell` — password for the `qa` account |
| `HA_SLAVE_HOST`     | (unset)                    | `test ha_repl`, `test ha_shell` — hostname of the slave node |
| `HA_SCENARIO`       | `/home/cubrid-testcases/sql` | `test ha_repl` — scenario path             |
| `SHELL_SCENARIO`    | the whole category directory | `test shell_heavy`, `test shell_long`, `test cci`, `test ha_shell`, `test rqg` — scenario path |
| `MEMORY_LEAK`       | `no`                       | `test sql`, `test medium` — run under valgrind |
| `MEMORY_SCENARIO`   | the one the category's conf holds | `test` with `MEMORY_LEAK=yes` — scenario path |
| `CODE_COVERAGE`     | `no`                       | `test`, `node`, `coverage` — collect gcov data |
| `COVERAGE_SRC`      | `/home/cubrid`             | `test`, `node`, `coverage` with `CODE_COVERAGE=yes` — the coverage build's source tree |

Paths the image fixes: `$WORKDIR` = `/home`, `$CUBRID` = `/home/CUBRID`,
`$CTP_HOME` = `/home/cubrid-testtools/CTP`. `test rqg` also sets
`$RQG_HOME` = `/home/cubrid-testtools-internal/random_query_generator`.

### Result and exit code

`test` exits 0 when every case passed and 1 otherwise. It does not trust CTP's own exit code —
several runners return 0 even when cases fail, or when java died with an exception. The verdict
comes from the runner's own result file: `summary_info` for sql and medium, `summary.info` for
sql_by_cci, `test_status.data` for the five shell categories, isolation, jdbc, ha_repl and rqg.
A run in which no case started is a failure, not a pass.

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

`ha_repl` and `ha_shell` each need two containers, and **their hostnames must differ**. CTP
builds its `ha_node_list` by running `hostname` over ssh on each node, so a single container —
and a single pod with two containers, which shares the UTS namespace — cannot host both. One
host runs the controller and the master; the other runs the slave.

Both need the same `HA_NODE_PASSWORD`. CTP authenticates to nodes by password only, so the `qa`
account gets its password at run time from that variable; the image bakes in none.

**Give each container its own CUBRID.** Both nodes rewrite `$CUBRID/conf` and create databases
under it, and the shell runner keeps a copy of the whole tree in the node account's home, so two
containers cannot share one host directory.

**Start the slave first**, then the master:

```bash
# slave
docker run -d --name han2 --hostname han2 \
  -v "$PWD/CUBRID-slave:/home/CUBRID" \
  -e HA_NODE_PASSWORD \
  cubridci/cubridci:test_rl8.10 \
  bash -lc '/entrypoint.sh checkout ha_repl && /entrypoint.sh node'

# controller and master
docker run --rm --name han1 --hostname han1 \
  -v "$PWD/CUBRID-master:/home/CUBRID" \
  -e HA_NODE_PASSWORD \
  -e HA_SLAVE_HOST=han2 \
  -e HA_SCENARIO=/home/cubrid-testcases/sql/_01_object \
  cubridci/cubridci:test_rl8.10 \
  bash -lc '/entrypoint.sh checkout ha_repl && /entrypoint.sh test ha_repl'
```

`ha_shell` has the same shape. Its cases live in a private repo, so both containers also need
`GHI_TOKEN`, and the scenario comes from `$SHELL_SCENARIO`:

```bash
docker run --rm --name has1 --hostname has1 \
  -v "$PWD/CUBRID-master:/home/CUBRID" \
  -e HA_NODE_PASSWORD -e GHI_TOKEN \
  -e HA_SLAVE_HOST=has2 \
  -e SHELL_SCENARIO=/home/cubrid-testcases-private/HA/shell/_22_ha \
  cubridci/cubridci:test_rl8.10 \
  bash -lc '/entrypoint.sh checkout ha_shell && /entrypoint.sh test ha_shell'
```

The two containers must resolve each other by hostname. A docker or nerdctl bridge network
writes the peer into `/etc/hosts` for you. In Kubernetes, put the two pods behind a headless
Service and add `dnsConfig.searches`, or use `hostAliases`.

`test ha_repl` writes `conf/ha_repl_ci.conf` itself, because the master and slave hostnames are
only known at run time. It passes the nightly regression's exclude list —
`sql/config/daily_regression_test_exclude_list_ha_repl.conf`, 202 cases — so this image and the
nightly run agree on which cases are known to fail. `test ha_shell` writes
`conf/ha_shell_ci.conf` the same way and passes `HA/shell/config/daily_regression_test_excluded_list_linux.conf`,
which is empty upstream.

**The node account's environment lives in `/etc/environment`.** CTP opens a node session with a
non-login shell that inherits none of the image's `ENV`, so `test` writes the variables the
runners need into that file. `HOME` there is `/home`, whatever the controller's is, and `/home`
is also the `qa` account's home directory in `/etc/passwd` — ten ha_shell cases address the build
as `~/CUBRID`, and an ssh session starts in the account's home directory no matter what `HOME`
says, so the two have to agree. The shell runner and the cases write next to it: `$CUBRID` is
copied to `~/.CUBRID_SHELL_FM`, a failing case is saved under `~/ERROR_BACKUP`.

**The image turns ssh host-key checking off** (`/etc/ssh/ssh_config.d/99-cubridci.conf`). Eleven
ha_shell cases spawn `ssh` themselves and drive it with `expect`, and their patterns expect the
`(yes/no)?` prompt of an older OpenSSH — OpenSSH 8 asks `(yes/no/[fingerprint])?` instead, which
those patterns never match, so the case hangs until its own timeout. CTP already disables the
check for its own connections, and the nodes are containers created per run.

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
| `cci`        | `_01_simple`: `_10_stest10`, `_11_stest11`, `_14_stest14`, `_19_stest19`, `_20_stest20`, `_21_stest21`, `_23_stest23`, `_27_stest27`, `_29_stest29` | Only when an earlier case built the shared `ccidb` first. `create_ccidb` caches the database as `databases/ccidbbak`, so whichever case runs first fixes the table options for the rest. These nine set `create_table_reuseoid=no` themselves — CBRD-23708 made `REUSE_OID` the default, and such a class returns no instance OIDs — but `_01_stest1` builds the cache without it. Each passes alone once `ccidbbak` is gone, and the nightly's own `init.sh` caches the same way. |
| `ha_repl`    | 202 cases in the nightly exclude list                                | Excluded automatically. |
| `ha_shell`   | `_40_guava/cbrd_26062`                                               | Its answer file has no room for the connect error the master's `copylogdb` prints while the case keeps the slave stopped, and the case blanks JSON values only, so the message survives the diff. |
| `ha_shell`   | `_22_ha/bug_xdbms2760`                                               | The case waits 200 s and then counts rows, but its writer script ends by dropping the table; on hardware this fast the writer finishes first and the count finds no table. |
| `rqg`        | `_02_issues/bug_bts_16290`                                           | Its `checkdb_catalogs.txt` names catalog classes without an owner qualifier, which `cubrid checkdb -i` has rejected since owner-qualified names arrived. It is the only case that passes `-i`. Only 17 of the 104 cases have been run here, so this list is not exhaustive. |

**Two cases replace the injected build with a release one.** `shell` `cbrd_26350` and
`ha_shell` `cbrd_24700` both call `run_cubrid_install` on an `ftp.cubrid.org` release build and
install it over `$CUBRID`; the `ha_shell` one does the same on the slave. Neither is in an
exclude list. They restore the original on their normal path, but not on every branch, and they
need outbound network — `run_cubrid_install` does not stop when its download fails, and removes
`$CUBRID` anyway. On a coverage run this ends the collection for every case after it, which is
why `test` re-reads the build type before it finishes.

**`sql_by_cci` compares against a different answer file.** Where a case has an `.answer_cci`
next to it, the cci runner uses that instead of `.answer` — the cases whose cci output differs
from the jdbc output were split off that way. When reading a `sql_by_cci` failure, check which
answer file it was compared against first.

**A memory-leak run rewrites `$CUBRID/bin`.** CTP's `run_memory.sh` moves `cub_server` and
`cub_cas` aside as `server.exe` and `cas.exe`, and puts small valgrind shims under their old
names. It puts them back only if it reaches its last step, so a run killed part-way leaves the
injected build replaced by the shims. `test` refuses to start when it finds them; re-inject
CUBRID, or rename the two files back by hand.

**A JUnit XML absence is not an error.** isolation, sql_by_cci and ha_repl write none.

**There is no entry point for a case list yet.** `$HA_SCENARIO` becomes CTP's `scenario=`, which
is a single directory. Splitting a category across containers means splitting it by scenario
directory.
