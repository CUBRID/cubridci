FROM centos:7

RUN set -x \
	&& yum -y install which git java-1.7.0-devel file gcc \
	&& yum clean all

ENV HOME /home/cubrid
ENV JAVA_HOME /usr/lib/jvm/java

LABEL Description="This is a test environment image for CUBRID"

# set timezone
ENV TZ Asia/Seoul
RUN ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime
RUN echo 'ZONE="Asia/Seoul' > /etc/sysconfig/clock

# CUBRID envronment variables
ENV CUBRID /home/CUBRID
ENV CUBRID_DATABASES $CUBRID/databases
ENV PATH $CUBRID/bin:$PATH
ENV LD_LIBRARY_PATH $CUBRID/lib
ENV TEST_SUITE medium:sql
ENV BRANCH_TESTTOOLS master
ENV BRANCH_TESTCASES develop

VOLUME $HOME
VOLUME $CUBRID

WORKDIR $HOME

COPY print_failed.sh /usr/local/bin/print_failed.sh
COPY docker-entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
