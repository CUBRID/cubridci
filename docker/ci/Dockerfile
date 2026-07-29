FROM rockylinux/rockylinux:8.10

LABEL Description="This is a [shell] test environment image for CUBRID"

# Install only necessary packages and clean up in the same layer to reduce image size
RUN dnf install -y epel-release && \
    dnf install -y --setopt=install_weak_deps=False \
    # Build and Development tools
    gcc-c++ gdb git \
    # System utilities
    vim-minimal lsof procps-ng file diffutils which csh glibc-locale-source glibc-langpack-en glibc-langpack-ko \
    # Network tools
    net-tools telnet wget \
    # System access and security
    sudo openssh-server openssh-clients \
    # Java runtime
    java-1.8.0-openjdk-devel \
    # Test utilities
    libxslt dos2unix lcov bc jq \
    expect && \
    dnf clean all && \
    rm -rf /var/cache/dnf/* && \
    rm -rf /var/tmp/* && \
    rm -rf /tmp/*

# SSH setup and user configuration in a single layer
RUN ssh-keygen -A && \
    sed -i 's/^account.*pam_nologin.so/#&/' /etc/pam.d/sshd && \
    mkdir -p /var/run/sshd && \
    mkdir -p /home/do_not_delete_core /home/ERROR_BACKUP && \
    ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime && \
    echo "Asia/Seoul" > /etc/timezone

# install multi-language locale for unicode test
RUN localedef -f UTF-8 -i ko_KR ko_KR.UTF-8 \
 && localedef -f EUC-KR -i ko_KR ko_KR.EUC-KR \
 && localedef -f UTF-8 -i en_US en_US.UTF-8
ENV LANG=en_US.UTF-8

# Pre-install the CircleCI tests plugin at the exact path the task agent expects,
# so `circleci tests run` reuses it instead of downloading it from S3 during the
# job (that download times out under 50-way fan-out on a slow WAN and fails the
# split step). If CircleCI bumps the plugin version, the agent ignores this stale
# cache and falls back to downloading, i.e. the behavior before this change.
ARG TESTS_PLUGIN_VERSION=1.0.13141-073b78b
RUN mkdir -p /tmp/circleci-tests-plugin-cli/${TESTS_PLUGIN_VERSION}/linux/amd64 && \
    wget -q -O /tmp/circleci-tests-plugin-cli/${TESTS_PLUGIN_VERSION}/linux/amd64/circleci-tests-plugin-cli \
        "https://circleci-binary-releases.s3.amazonaws.com/circleci-tests-plugin-cli/${TESTS_PLUGIN_VERSION}/linux/amd64/circleci-tests-plugin-cli" && \
    chmod 755 /tmp/circleci-tests-plugin-cli/${TESTS_PLUGIN_VERSION}/linux/amd64/circleci-tests-plugin-cli

#circleci env
ENV TEST_REPORT=/tmp/tests
ENV BASELINE none
ENV BRANCH_TESTTOOLS develop
ENV BRANCH_TESTCASES develop
ENV WORKDIR=/home
ENV USER=root
# testtools env
ENV JAVA_HOME=/usr/lib/jvm/java-1.8.0
ENV CTP_BRANCH_NAME=$BRANCH_TESTTOOLS
ENV CTP_SKIP_UPDATE=0 
ENV CTP_HOME=$WORKDIR/cubrid-testtools/CTP
ENV init_path=$CTP_HOME/shell/init_path
ENV PATH=$CTP_HOME/bin:$CTP_HOME/common/script:$PATH
# cubrid env
ENV CUBRID=$WORKDIR/CUBRID
ENV CUBRID_DATABASES=$CUBRID/databases
ENV LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib:$LD_LIBRARY_PATH
ENV SHLIB_PATH=$LD_LIBRARY_PATH
ENV LIBPATH=$LD_LIBRARY_PATH
ENV PATH=$CUBRID/bin:/usr/sbin:$PATH

COPY docker-entrypoint.sh /entrypoint.sh

RUN chmod 777 $WORKDIR && \
    chmod 777 /entrypoint.sh

WORKDIR $WORKDIR

ENTRYPOINT ["/entrypoint.sh"]
