FROM rockylinux/rockylinux:8.10

LABEL Description="This is a build environment image for CUBRID"

RUN dnf install -y dnf-plugins-core && \
    dnf config-manager --set-enabled powertools || \
    dnf config-manager --set-enabled crb

RUN set -x \
        && dnf install -y epel-release \
        && dnf install -y --setopt=tsflags=nodocs \
                gcc gcc-c++ make \
                python2-devel python3-devel \
                elfutils-libelf-devel systemtap-sdt-devel libstdc++-static \
                ncurses-devel ant flex git wget libxslt \
                rpm-build libtool libtool-ltdl autoconf automake \
                which ccache \
                glibc-locale-source glibc-langpack-en glibc-langpack-ko \
        && dnf clean all -y \
        && rm -rf /var/cache/dnf

# install Adoptium Temurin JDK 8
ENV JDK_URL="https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u442-b06/OpenJDK8U-jdk_x64_linux_hotspot_8u442b06.tar.gz"
RUN curl -L $JDK_URL | tar xzvf - -C /opt \
    && ln -s /opt/jdk8u442-b06 /opt/jdk8

# install bison 3 for PR #1125
ENV BISON_VERSION 3.0.5
RUN curl -L https://ftp.gnu.org/gnu/bison/bison-$BISON_VERSION.tar.gz | tar xzvf - \
    && cd bison-$BISON_VERSION && ./configure --prefix=/usr && make all install \
    && rm -rf bison-$BISON_VERSION && cd ..

# install cmake 3.26
ENV CMAKE_VERSION 3.26.3
RUN curl -L https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-linux-x86_64.tar.gz | tar xzvf - \
 && yes | cp -fR cmake-$CMAKE_VERSION-linux-x86_64/* /usr \
 && rm -rf cmake-$CMAKE_VERSION-linux-x86_64

# install ninja generator
ENV NINJA_VERSION 1.11.1
RUN curl -L https://github.com/ninja-build/ninja/archive/refs/tags/v$NINJA_VERSION.tar.gz | tar xzvf - \
    && cd ninja-$NINJA_VERSION && cmake -Bbuild-cmake && cmake --build build-cmake \
    && mv build-cmake/ninja /usr/bin/ninja && cd .. \
    && rm -rf ninja-$NINJA_VERSION

ENV WORKDIR /home
ENV JAVA_HOME /opt/jdk8

# CUBRID envronment variables
ENV CUBRID $WORKDIR/CUBRID
ENV CUBRID_DATABASES $CUBRID/databases
ENV PATH $JAVA_HOME/bin:$CUBRID/bin:$PATH
ENV LD_LIBRARY_PATH $CUBRID/lib:$CUBRID/cci/lib

# set timezone for test
ENV TZ Asia/Seoul
RUN ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime
RUN echo 'ZONE="Asia/Seoul"' > /etc/sysconfig/clock

# install multi-language locale for unicode test
RUN localedef -f UTF-8 -i ko_KR ko_KR.UTF-8 \
 && localedef -f EUC-KR -i ko_KR ko_KR.EUC-KR \
 && localedef -f UTF-8 -i en_US en_US.UTF-8
ENV LC_ALL=en_US

# ccache configuration
ENV CC="ccache gcc"
ENV CXX="ccache g++"

COPY docker-entrypoint.sh /entrypoint.sh

RUN chmod 775 /entrypoint.sh
RUN chmod 777 $WORKDIR
WORKDIR $WORKDIR

ENTRYPOINT ["/entrypoint.sh"]
