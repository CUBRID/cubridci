FROM rockylinux:8

LABEL Description="This is a [shell] test environment image for CUBRID"

# Install only necessary packages and clean up in the same layer to reduce image size
RUN dnf install -y epel-release && \
    dnf install -y --setopt=install_weak_deps=False \
    # Build and Development tools
    gcc-c++ \
    git \
    # System utilities
    vim-minimal \
    lsof \
    procps-ng \
    file \
    diffutils \
    which \
    csh \
    # Network tools
    net-tools \
    telnet \
    wget \
    # System access and security
    sudo \
    openssh-server \
    openssh-clients \
    # Java runtime
    java-1.8.0-openjdk-devel \
    # Test utilities
    libxslt \
    dos2unix \
    lcov \
    bc \
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

#circleci env
ENV TEST_REPORT=/tmp/tests
ENV WORKDIR=/home
ENV USER=root
# testtools env
ENV JAVA_HOME=/usr/lib/jvm/java-1.8.0
ENV CTP_BRANCH_NAME=develop 
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
COPY manual_test_result.jar /manual_test_result.jar

RUN chmod 777 $WORKDIR && \
    chmod 777 /entrypoint.sh && \
    chmod 777 /manual_test_result.jar

WORKDIR $WORKDIR

ENTRYPOINT ["/entrypoint.sh"]
