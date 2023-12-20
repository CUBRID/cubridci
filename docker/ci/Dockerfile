FROM centos:6

LABEL Description="This is a build and test environment image for CUBRID"

RUN sed -i -e "s/^mirrorlist=http:\/\/mirrorlist.centos.org/#mirrorlist=http:\/\/mirrorlist.centos.org/g" /etc/yum.repos.d/CentOS-Base.repo
RUN sed -i -e "s/^#baseurl=http:\/\/mirror.centos.org/baseurl=https:\/\/vault.centos.org/g" /etc/yum.repos.d/CentOS-Base.repo

RUN yum install -y centos-release-scl

RUN sed -i -e "s/^mirrorlist=http:\/\/mirrorlist.centos.org/#mirrorlist=http:\/\/mirrorlist.centos.org/g" /etc/yum.repos.d/CentOS-SCLo-scl.repo
RUN sed -i -e "s/^# baseurl=http:\/\/mirror.centos.org/baseurl=https:\/\/vault.centos.org/g" /etc/yum.repos.d/CentOS-SCLo-scl.repo
RUN sed -i -e "s/^mirrorlist=http:\/\/mirrorlist.centos.org/#mirrorlist=http:\/\/mirrorlist.centos.org/g" /etc/yum.repos.d/CentOS-SCLo-scl-rh.repo
RUN sed -i -e "s/^#baseurl=http:\/\/mirror.centos.org/baseurl=https:\/\/vault.centos.org/g" /etc/yum.repos.d/CentOS-SCLo-scl-rh.repo

RUN set -x \
        && yum install -y --setopt=tsflags=nodocs devtoolset-8-gcc devtoolset-8-gcc-c++ devtoolset-8-make \
                devtoolset-8-elfutils-libelf-devel devtoolset-8-systemtap-sdt-devel \
                ncurses-devel java-1.8.0-openjdk-devel ant flex sclo-git212 wget libxslt \
                rpm-build libtool libtool-ltdl autoconf automake \
        && yum clean all -y

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
RUN source scl_source enable devtoolset-8 \
	&& curl -L https://github.com/ninja-build/ninja/archive/refs/tags/v$NINJA_VERSION.tar.gz | tar xzvf - \
    && cd ninja-$NINJA_VERSION && cmake -Bbuild-cmake && cmake --build build-cmake \
    && mv build-cmake/ninja /usr/bin/ninja && cd .. \
    && rm -rf ninja-$NINJA_VERSION

ENV WORKDIR /home
ENV JAVA_HOME /usr/lib/jvm/java

# CUBRID envronment variables
ENV CUBRID $WORKDIR/CUBRID
ENV CUBRID_DATABASES $CUBRID/databases
ENV PATH $CUBRID/bin:/opt/rh/sclo-git212/root/usr/bin:/usr/cmake-$CMAKE_VERSION-Linux-x86_64/bin:$PATH
ENV LD_LIBRARY_PATH $CUBRID/lib:$CUBRID/cci/lib
ENV TEST_SUITE medium:sql
ENV TEST_REPORT /tmp/tests
ENV BRANCH_TESTTOOLS develop
ENV BRANCH_TESTCASES release/12.0

# set timezone for test
ENV TZ Asia/Seoul
RUN ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime
RUN echo 'ZONE="Asia/Seoul' > /etc/sysconfig/clock

# install multi-language locale for unicode test
RUN localedef -f UTF-8 -i ko_KR ko_KR.utf8
RUN localedef -f EUC-KR -i ko_KR ko_KR.euckr

COPY docker-entrypoint.sh /entrypoint.sh

RUN chmod 775 /entrypoint.sh
RUN chmod 777 $WORKDIR
WORKDIR $WORKDIR

ENTRYPOINT ["scl", "enable", "devtoolset-8", "--", "/entrypoint.sh"]
