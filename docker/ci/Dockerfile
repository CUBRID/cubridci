FROM centos:6.10

LABEL Description="This is a build environment image for CUBRID"

# CentOS 6 is end of life: its packages are only on vault.centos.org.
RUN set -ex \
        && vault() { sed -i -e 's|^mirrorlist=|#mirrorlist=|' \
                -e 's|^# *baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|' "$@"; } \
        && vault /etc/yum.repos.d/CentOS-Base.repo \
        && yum install -y centos-release-scl \
        && vault /etc/yum.repos.d/CentOS-SCLo-scl.repo /etc/yum.repos.d/CentOS-SCLo-scl-rh.repo \
        && yum install -y --setopt=tsflags=nodocs \
                devtoolset-8-gcc devtoolset-8-gcc-c++ devtoolset-8-make \
                devtoolset-8-elfutils-libelf-devel devtoolset-8-systemtap-sdt-devel \
                ncurses-devel ant flex sclo-git212 \
                rpm-build libtool libtool-ltdl autoconf automake \
                which unzip \
                perl-core \
        && yum clean all -y \
        && rm -rf /var/cache/yum

# What `scl enable devtoolset-8 sclo-git212` sets. The develop image runs `scl enable` as its
# ENTRYPOINT, but gha-ci runs its steps in `bash --noprofile --norc` and calls /entrypoint.sh
# directly, so it has to be the environment.
ENV PATH /opt/rh/devtoolset-8/root/usr/bin:/opt/rh/sclo-git212/root/usr/bin:$PATH
ENV LD_LIBRARY_PATH /opt/rh/devtoolset-8/root/usr/lib64:/opt/rh/devtoolset-8/root/usr/lib:/opt/rh/devtoolset-8/root/usr/lib64/dyninst:/opt/rh/devtoolset-8/root/usr/lib/dyninst
ENV PKG_CONFIG_PATH /opt/rh/devtoolset-8/root/usr/lib64/pkgconfig

# base has only cmake 2.8
ARG CMAKE_VERSION=3.26.3
RUN set -ex \
        && curl -fsSL https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-linux-x86_64.tar.gz \
           | tar xzf - -C /usr --strip-components=1 \
        && cmake --version

# The engine's CMake looks here for the JDK and the 3rdparty tarballs before downloading them.
ENV CUBRID_DOWNLOAD_CACHE /opt/download-cache
ARG JDK_DIR=jdk8u442-b06
ARG JDK_URL="https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u442-b06/OpenJDK8U-jdk_x64_linux_hotspot_8u442b06.tar.gz"
ARG JDK_SHA256=5b0a0145e7790552a9c8767b4680074c4628ec276e5bb278b61d85cf90facafa
RUN set -ex \
        && curl -fsSL --create-dirs -o "$CUBRID_DOWNLOAD_CACHE/jdk/${JDK_URL##*/}" "$JDK_URL" \
        && echo "$JDK_SHA256  $CUBRID_DOWNLOAD_CACHE/jdk/${JDK_URL##*/}" | sha256sum -c - \
        && tar xzf $CUBRID_DOWNLOAD_CACHE/jdk/* -C /opt \
        && ln -s /opt/$JDK_DIR /opt/jdk8 \
        && rm -rf /opt/jdk8/src.zip /opt/jdk8/sample /opt/jdk8/man \
        && /opt/jdk8/bin/java -version

# ant pulls in java-1.7.0-openjdk as /usr/bin/java, and gradle 8 needs Java 8.
ENV JAVA_HOME /opt/jdk8

# bison 3 for PR #1125; base has only 2.4.1
ARG BISON_VERSION=3.0.5
RUN set -ex \
        && curl -fsSL https://ftp.gnu.org/gnu/bison/bison-$BISON_VERSION.tar.gz | tar xzf - \
        && cd bison-$BISON_VERSION \
        && ./configure --prefix=/usr --disable-nls \
        && make -j"$(nproc)" && make install-strip \
        && cd .. && rm -rf bison-$BISON_VERSION

# base has no ninja
ARG NINJA_VERSION=1.11.1
RUN set -ex \
        && curl -fsSL https://github.com/ninja-build/ninja/archive/refs/tags/v$NINJA_VERSION.tar.gz | tar xzf - \
        && cd ninja-$NINJA_VERSION \
        && cmake -Bbuild-cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
        && cmake --build build-cmake -j"$(nproc)" \
        && install -s -m 755 build-cmake/ninja /usr/bin/ninja \
        && cd .. && rm -rf ninja-$NINJA_VERSION

# EPEL 6 has only ccache 3.1.6, which compiles the preprocessed source: a /* fall through */
# comment is gone by then and -Werror=implicit-fallthrough fails the build. 3.7.7 is the
# version in build_rl8.10: gha-ci's build step counts cache hits and misses by its log wording.
ARG CCACHE_VERSION=3.7.7
RUN set -ex \
        && curl -fsSL https://github.com/ccache/ccache/releases/download/v$CCACHE_VERSION/ccache-$CCACHE_VERSION.tar.gz | tar xzf - \
        && cd ccache-$CCACHE_VERSION \
        && ./configure --prefix=/usr \
        && make -j"$(nproc)" && make install \
        && cd .. && rm -rf ccache-$CCACHE_VERSION \
        && ccache --version

# pl_engine's gradle wrapper downloads this every build, with a 10s network timeout.
# The hash directory name is the wrapper's own base36(md5(distributionUrl)).
ARG GRADLE_VERSION=8.1.1
ARG GRADLE_DIST_HASH=9wiye5v2saajue4irfo8ybqfp
ENV GRADLE_USER_HOME /opt/gradle-home
RUN set -ex \
        && dist=$GRADLE_USER_HOME/wrapper/dists/gradle-$GRADLE_VERSION-bin/$GRADLE_DIST_HASH \
        && mkdir -p "$dist" \
        && curl -fsSL -o /tmp/gradle.zip \
             https://services.gradle.org/distributions/gradle-$GRADLE_VERSION-bin.zip \
        && unzip -q /tmp/gradle.zip -d "$dist" \
        && rm -f /tmp/gradle.zip \
        && "$dist/gradle-$GRADLE_VERSION/bin/gradle" --version > /dev/null \
        && touch "$dist/gradle-$GRADLE_VERSION-bin.zip.ok" \
        && chmod -R a+rwX $GRADLE_USER_HOME

# 3rdparty.list and gradle-deps copy what CUBRID/cubrid's 3rdparty/CMakeLists.txt and pl_engine
# download; update them when the engine bumps a version. --write-verification-metadata is what
# makes gradle download the jars; help alone fetches only the settings plugin. The scratch gradle
# home keeps gradle's own caches (154MB) out of the image; only caches/modules-2 moves in.
COPY 3rdparty.list /tmp/
COPY gradle-deps /tmp/gradle-deps/
RUN set -ex \
        && while read -r var url sha256; do \
             file="$CUBRID_DOWNLOAD_CACHE/$var/${url##*/}" \
             && curl -fsSL --create-dirs -o "$file" "$url" \
             && echo "$sha256  $file" | sha256sum -c - || exit; \
           done < /tmp/3rdparty.list \
        && $GRADLE_USER_HOME/wrapper/dists/gradle-$GRADLE_VERSION-bin/$GRADLE_DIST_HASH/gradle-$GRADLE_VERSION/bin/gradle \
             --gradle-user-home /tmp/gradle-home --no-daemon --write-verification-metadata sha256 \
             -p /tmp/gradle-deps help \
        && mkdir -p $GRADLE_USER_HOME/caches \
        && mv /tmp/gradle-home/caches/modules-2 $GRADLE_USER_HOME/caches/ \
        && rm -rf /tmp/3rdparty.list /tmp/gradle-deps /tmp/gradle-home

# Gradle downloads a dependency the image lacks without a word; warn as the engine's 3rdparty
# fetch does.
COPY warn-downloads.gradle $GRADLE_USER_HOME/init.d/

ENV WORKDIR /home

ENV CUBRID $WORKDIR/CUBRID
ENV CUBRID_DATABASES $CUBRID/databases
ENV PATH $JAVA_HOME/bin:$CUBRID/bin:$PATH
ENV LD_LIBRARY_PATH $CUBRID/lib:$CUBRID/cci/lib:$LD_LIBRARY_PATH

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
