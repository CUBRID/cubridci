FROM rockylinux/rockylinux:8.10

LABEL Description="This is a test environment image for CUBRID (rocky8, CTP runtime). CUBRID must be injected from outside."

# lcov needs EPEL; glibc-locale-source only feeds localedef, so drop it in the same layer.
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
        && localedef -f UTF-8 -i ko_KR ko_KR.UTF-8 \
        && localedef -f EUC-KR -i ko_KR ko_KR.EUC-KR \
        && localedef -f UTF-8 -i en_US en_US.UTF-8 \
        && dnf remove -y glibc-locale-source \
        && dnf clean all -y \
        && rm -rf /var/cache/dnf /var/tmp/* /tmp/*

RUN set -ex \
        && ssh-keygen -A \
        && sed -i 's/^account.*pam_nologin.so/#&/' /etc/pam.d/sshd \
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
RUN useradd -m -d $WORKDIR/$NODE_USER $NODE_USER

COPY docker-entrypoint.sh /entrypoint.sh

RUN chmod 777 $WORKDIR && chmod 755 /entrypoint.sh

WORKDIR $WORKDIR

ENTRYPOINT ["/entrypoint.sh"]
