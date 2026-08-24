FROM rockylinux/rockylinux:8.10

LABEL Description="This is a build environment image for CUBRID"

RUN set -ex \
        && dnf install -y dnf-plugins-core \
        && { dnf config-manager --set-enabled powertools \
             || dnf config-manager --set-enabled crb; } \
        && dnf clean all -y \
        && rm -rf /var/cache/dnf

# java-devel: find_package(JNI) looks under /usr/lib/jvm, not at the Temurin JDK
RUN set -ex \
        && dnf install -y epel-release \
        && dnf install -y --setopt=tsflags=nodocs --setopt=install_weak_deps=False \
                gcc gcc-c++ make cmake \
                python2-devel python3-devel \
                elfutils-libelf-devel systemtap-sdt-devel libstdc++-static \
                ncurses-devel ant flex git \
                rpm-build libtool libtool-ltdl autoconf automake \
                which ccache \
                java-1.8.0-openjdk-devel \
                glibc-langpack-en \
        && dnf clean all -y \
        && rm -rf /var/cache/dnf

ARG JDK_DIR=jdk8u442-b06
ARG JDK_URL="https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u442-b06/OpenJDK8U-jdk_x64_linux_hotspot_8u442b06.tar.gz"
RUN set -ex \
        && curl -fsSL "$JDK_URL" | tar xzf - -C /opt \
        && ln -s /opt/$JDK_DIR /opt/jdk8 \
        && rm -rf /opt/jdk8/src.zip /opt/jdk8/sample /opt/jdk8/man

# bison 3 for PR #1125; appstream has only 3.0.4
ARG BISON_VERSION=3.0.5
RUN set -ex \
        && curl -fsSL https://ftp.gnu.org/gnu/bison/bison-$BISON_VERSION.tar.gz | tar xzf - \
        && cd bison-$BISON_VERSION \
        && ./configure --prefix=/usr --disable-nls \
        && make -j"$(nproc)" && make install-strip \
        && cd .. && rm -rf bison-$BISON_VERSION

# powertools has only ninja 1.8.2
ARG NINJA_VERSION=1.11.1
RUN set -ex \
        && curl -fsSL https://github.com/ninja-build/ninja/archive/refs/tags/v$NINJA_VERSION.tar.gz | tar xzf - \
        && cd ninja-$NINJA_VERSION \
        && cmake -Bbuild-cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
        && cmake --build build-cmake -j"$(nproc)" \
        && install -s -m 755 build-cmake/ninja /usr/bin/ninja \
        && cd .. && rm -rf ninja-$NINJA_VERSION

ENV WORKDIR /home
ENV JAVA_HOME /opt/jdk8

ENV CUBRID $WORKDIR/CUBRID
ENV CUBRID_DATABASES $CUBRID/databases
ENV PATH $JAVA_HOME/bin:$CUBRID/bin:$PATH
ENV LD_LIBRARY_PATH $CUBRID/lib:$CUBRID/cci/lib

ENV TZ Asia/Seoul
ENV LC_ALL=en_US

ENV CC="ccache gcc"
ENV CXX="ccache g++"

RUN set -ex \
        && ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime \
        && echo 'ZONE="Asia/Seoul"' > /etc/sysconfig/clock \
        && chmod 777 $WORKDIR

COPY docker-entrypoint.sh /entrypoint.sh

RUN chmod 775 /entrypoint.sh
WORKDIR $WORKDIR

ENTRYPOINT ["/entrypoint.sh"]
