FROM centos:6

LABEL Description="This is a build and test environment image for CUBRID"

RUN set -x \
	&& yum install -y centos-release-scl \
	&& yum install -y --setopt=tsflags=nodocs gcc gcc-c++ autoconf automake libtool rpm-build flex bison cmake sclo-git212 \
	&& yum install -y --setopt=tsflags=nodocs systemtap-sdt-devel ncurses-devel java-1.7.0-devel ant elfutils-libelf-devel wget libxslt \
	&& yum clean all

ENV WORKDIR /home
ENV JAVA_HOME /usr/lib/jvm/java

# CUBRID envronment variables
ENV CUBRID $WORKDIR/CUBRID
ENV CUBRID_DATABASES $CUBRID/databases
ENV PATH $CUBRID/bin:/opt/rh/sclo-git212/root/usr/bin:$PATH
ENV LD_LIBRARY_PATH $CUBRID/lib
ENV TEST_SUITE medium:sql
ENV TEST_REPORT /tmp/tests
ENV BRANCH_TESTTOOLS release/10.2
ENV BRANCH_TESTCASES release/10.1

# set timezone for test
ENV TZ Asia/Seoul
RUN ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime
RUN echo 'ZONE="Asia/Seoul' > /etc/sysconfig/clock

RUN chmod 777 $WORKDIR
WORKDIR $WORKDIR

COPY docker-entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
