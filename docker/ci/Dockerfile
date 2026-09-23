FROM rockylinux/rockylinux:8.10 AS build-environment

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
                which ccache unzip \
                perl-core \
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

# POC for CUBRIDQA-1613. The normal Jenkins build leaves this argument empty, so
# the current build_rl8.10 image remains usable until the matching CUBRID changes
# land. A POC image supplies the full commit SHA that owns all three interfaces:
#
#   * 3rdparty/manifest.json
#   * the cubrid_thirdparty_prefix producer target
#   * CUBRID_3RDPARTY_MODE=CI_PREBUILT consumption
#
# Only the normalized prefix crosses into the final image. The source, downloads,
# build tree and ExternalProject stamps stay in this throw-away builder stage.
FROM build-environment AS thirdparty-prefix-builder

ARG CUBRID_REPOSITORY=https://github.com/CUBRID/cubrid.git
ARG CUBRID_3RDPARTY_REVISION=

RUN set -eux; \
        mkdir -p /opt/cubrid-thirdparty; \
        if [ -z "$CUBRID_3RDPARTY_REVISION" ]; then \
          echo '[thirdparty-prefix] disabled: CUBRID_3RDPARTY_REVISION is empty'; \
          exit 0; \
        fi; \
        if [ "${#CUBRID_3RDPARTY_REVISION}" -ne 40 ]; then \
          echo 'CUBRID_3RDPARTY_REVISION must be a full 40-character lowercase commit SHA' >&2; \
          exit 1; \
        fi; \
        case "$CUBRID_3RDPARTY_REVISION" in \
          *[!0-9a-f]*) \
            echo 'CUBRID_3RDPARTY_REVISION must be a full 40-character lowercase commit SHA' >&2; \
            exit 1 \
            ;; \
        esac; \
        git init -q /tmp/cubrid-src; \
        cd /tmp/cubrid-src; \
        git remote add origin "$CUBRID_REPOSITORY"; \
        git -c fetch.parallel=0 fetch -q --depth=1 origin "$CUBRID_3RDPARTY_REVISION"; \
        git checkout -q --detach FETCH_HEAD; \
        git submodule update -q --init --depth=1; \
        CC=gcc CXX=g++ cmake -S /tmp/cubrid-src -B /tmp/cubrid-build -G Ninja \
          -DCMAKE_BUILD_TYPE=RelWithDebInfo \
          -DCUBRID_3RDPARTY_PREFIX_OUTPUT=/opt/cubrid-thirdparty; \
        cmake --build /tmp/cubrid-build --target cubrid_thirdparty_prefix; \
        test -d /opt/cubrid-thirdparty/include; \
        test -d /opt/cubrid-thirdparty/lib; \
        test -d /opt/cubrid-thirdparty/licenses; \
        for library in libexpat.a libedit.a liblz4.a libssl.a libcrypto.a libodbc.so libre2.a libtbb.a; do \
          test -e "/opt/cubrid-thirdparty/lib/$library"; \
        done; \
        test -e /opt/cubrid-thirdparty/include/rapidjson/document.h; \
        test -s /opt/cubrid-thirdparty/share/cubrid-thirdparty/manifest.json; \
        test -s /opt/cubrid-thirdparty/share/cubrid-thirdparty/provenance.json

FROM build-environment AS final

ARG CUBRID_3RDPARTY_REVISION=

COPY --from=thirdparty-prefix-builder /opt/cubrid-thirdparty/ /opt/cubrid-thirdparty/

# An empty value keeps the current image behavior. For an enabled POC image the
# entrypoint validates the baked prefix, then exports CUBRID_3RDPARTY_MODE and
# CUBRID_3RDPARTY_ROOT for the matching CUBRID CMake implementation.
ENV CUBRID_CI_3RDPARTY_REVISION=$CUBRID_3RDPARTY_REVISION

COPY docker-entrypoint.sh /entrypoint.sh

RUN chmod 775 /entrypoint.sh
WORKDIR $WORKDIR

ENTRYPOINT ["/entrypoint.sh"]
