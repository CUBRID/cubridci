FROM rockylinux/rockylinux:8.10

LABEL Description="CUBRID SQL/Medium test runtime image (rocky8). Build is provided externally; this image only runs CTP sql/medium suites."

# Test-runtime dependencies only. No build toolchain.
RUN dnf install -y epel-release && \
    dnf install -y --setopt=install_weak_deps=False \
        gcc-c++ gdb git \
        vim-minimal lsof procps-ng file diffutils which csh \
        glibc-locale-source glibc-langpack-en glibc-langpack-ko \
        net-tools telnet wget \
        sudo openssh-server openssh-clients \
        java-1.8.0-openjdk-devel \
        libxslt dos2unix lcov bc jq expect && \
    dnf clean all && \
    rm -rf /var/cache/dnf/* /var/tmp/* /tmp/*

# SSH + bookkeeping dirs (CTP/test infra expectations)
RUN ssh-keygen -A && \
    sed -i 's/^account.*pam_nologin.so/#&/' /etc/pam.d/sshd && \
    mkdir -p /var/run/sshd /home/do_not_delete_core /home/ERROR_BACKUP && \
    ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime && \
    echo "Asia/Seoul" > /etc/timezone

RUN localedef -f UTF-8 -i ko_KR ko_KR.UTF-8 && \
    localedef -f EUC-KR -i ko_KR ko_KR.EUC-KR && \
    localedef -f UTF-8 -i en_US en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV TZ=Asia/Seoul

# CircleCI / runtime env
ENV WORKDIR=/home
ENV USER=root
ENV TEST_REPORT=/tmp/tests
ENV TEST_SUITE=medium:sql
ENV BRANCH_TESTTOOLS=develop
ENV BRANCH_TESTCASES=develop

# CTP env
ENV JAVA_HOME=/usr/lib/jvm/java-1.8.0
ENV CTP_BRANCH_NAME=$BRANCH_TESTTOOLS
ENV CTP_SKIP_UPDATE=0
ENV CTP_HOME=$WORKDIR/cubrid-testtools/CTP
ENV init_path=$CTP_HOME/shell/init_path
ENV PATH=$CTP_HOME/bin:$CTP_HOME/common/script:$PATH

# CUBRID env (cubrid_rel etc. resolve only after run_install or pre-mounted /home/CUBRID)
ENV CUBRID=$WORKDIR/CUBRID
ENV CUBRID_DATABASES=$CUBRID/databases
ENV LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib:$LD_LIBRARY_PATH
ENV SHLIB_PATH=$LD_LIBRARY_PATH
ENV LIBPATH=$LD_LIBRARY_PATH
ENV PATH=$CUBRID/bin:/usr/sbin:$PATH

COPY docker-entrypoint.sh /entrypoint.sh

RUN chmod 777 $WORKDIR && chmod 755 /entrypoint.sh

WORKDIR $WORKDIR

ENTRYPOINT ["/entrypoint.sh"]
