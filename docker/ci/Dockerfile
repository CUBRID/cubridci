FROM rockylinux/rockylinux:8.10

LABEL Description="This is a test environment image for CUBRID (rocky8, CTP runtime). CUBRID must be injected from outside."

# rqg drives CUBRID from perl through DBI, and DBD::cubrid has no distribution package. Its
# tarball carries its own CCI source, so it links statically and needs no $CUBRID at build time.
ARG DBD_CUBRID_VER=10.1.0.0001
ARG DBD_CUBRID_SHA256=1552e9b2bb93d8a32010f2bb77dc4f0c152971aed019ce42e494e86f24dce261

# lcov needs EPEL; glibc-locale-source only feeds localedef, so drop it in the same layer.
# perl-devel and ncurses-devel only build DBD::cubrid (the bundled CCI includes curses.h), and
# Makefile.PL ignores a failed CCI build, so the static library is checked before make.
# glibc-gconv-extra comes in with perl-devel and is not in the base image, so it goes back out.
RUN set -ex \
        && dnf install -y epel-release \
        && dnf install -y --setopt=tsflags=nodocs --setopt=install_weak_deps=False \
                gcc-c++ gdb git make valgrind \
                vim-minimal lsof procps-ng file diffutils which csh \
                glibc-locale-source glibc-langpack-en glibc-langpack-ko \
                net-tools telnet wget \
                sudo openssh-server openssh-clients \
                java-1.8.0-openjdk-devel \
                dos2unix lcov bc jq expect \
                perl-DBI perl-Time-HiRes perl-Test-Simple \
        && localedef -f UTF-8 -i ko_KR ko_KR.UTF-8 \
        && localedef -f EUC-KR -i ko_KR ko_KR.EUC-KR \
        && localedef -f UTF-8 -i en_US en_US.UTF-8 \
        && dnf remove -y glibc-locale-source \
        && dnf install -y --setopt=tsflags=nodocs --setopt=install_weak_deps=False \
                perl-devel ncurses-devel \
        && cd /tmp \
        && wget -q https://cpan.metacpan.org/authors/id/C/CU/CUBRID/DBD-cubrid-$DBD_CUBRID_VER.tar.gz \
        && echo "$DBD_CUBRID_SHA256  DBD-cubrid-$DBD_CUBRID_VER.tar.gz" | sha256sum -c - \
        && tar xzf DBD-cubrid-$DBD_CUBRID_VER.tar.gz \
        && cd DBD-cubrid-$DBD_CUBRID_VER \
        && perl Makefile.PL \
        && test -f cci-src/cci/.libs/libcascci.a \
        && make \
        && make install \
        && cd / \
        && rm -rf /tmp/DBD-cubrid-$DBD_CUBRID_VER* /usr/lib64/perl5/perllocal.pod \
        && dnf remove -y perl-devel ncurses-devel glibc-gconv-extra \
        && dnf clean all -y \
        && rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Test cases spawn ssh themselves and drive it with expect, and their patterns predate the
# host-key prompt OpenSSH 8 prints; CTP turns the check off for its own connections the same way.
RUN set -ex \
        && ssh-keygen -A \
        && sed -i 's/^account.*pam_nologin.so/#&/' /etc/pam.d/sshd \
        && printf 'Host *\n    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null\n    LogLevel ERROR\n' \
                > /etc/ssh/ssh_config.d/99-cubridci.conf \
        && mkdir -p /var/run/sshd /home/do_not_delete_core /home/ERROR_BACKUP \
        && ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime \
        && echo "Asia/Seoul" > /etc/timezone

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV TZ=Asia/Seoul

ENV WORKDIR=/home
ENV USER=root
ENV NODE_USER=qa
ENV TEST_REPORT=/tmp/tests
ENV TEST_SUITE=
ENV BRANCH_TESTTOOLS=develop
ENV BRANCH_TESTCASES=develop

ENV JAVA_HOME=/usr/lib/jvm/java-1.8.0
ENV CTP_BRANCH_NAME=$BRANCH_TESTTOOLS
ENV CTP_SKIP_UPDATE=0
ENV CTP_HOME=$WORKDIR/cubrid-testtools/CTP
ENV init_path=$CTP_HOME/shell/init_path
ENV PATH=$CTP_HOME/bin:$CTP_HOME/common/script:$PATH

ENV CUBRID=$WORKDIR/CUBRID
ENV CUBRID_DATABASES=$CUBRID/databases
ENV LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib:$LD_LIBRARY_PATH
ENV SHLIB_PATH=$LD_LIBRARY_PATH
ENV LIBPATH=$LD_LIBRARY_PATH
ENV PATH=$CUBRID/bin:/usr/sbin:$PATH

# CTP kills every process owned by the node account, so it must differ from the controller's.
# Its home is $WORKDIR, where CUBRID and CTP live: cases address the build as ~/CUBRID, and an
# ssh session lands in the account's home whatever HOME says.
RUN useradd -M -d $WORKDIR $NODE_USER

COPY docker-entrypoint.sh /entrypoint.sh

RUN chmod 777 $WORKDIR && chmod 755 /entrypoint.sh

WORKDIR $WORKDIR

ENTRYPOINT ["/entrypoint.sh"]
