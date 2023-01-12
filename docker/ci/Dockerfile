FROM ubuntu:focal

LABEL Description="This is a build and test environment image for CUBRID on ubuntu image"

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update  \
    && apt-get install openjdk-8-jdk locales git vim -y \
    && apt-get install gcc-9 g++-9 libncurses5 -y
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 110 --slave /usr/bin/g++ g++ /usr/bin/g++-9

ENV WORKDIR /home
ENV JAVA_HOME /usr/lib/jvm/java-8-openjdk-amd64

# CUBRID envronment variables
ENV CUBRID $WORKDIR/CUBRID
ENV CUBRID_DATABASES $CUBRID/databases
ENV PATH $CUBRID/bin:$PATH
ENV LD_LIBRARY_PATH $CUBRID/lib:$CUBRID/cci/lib
ENV TEST_SUITE medium:sql
ENV TEST_REPORT /tmp/tests
ENV BRANCH_TESTTOOLS develop
ENV BRANCH_TESTCASES develop


#bash
RUN ln -sf /bin/bash /bin/sh

# set timezone for test
RUN ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime

# install multi-language locale for unicode test
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
RUN locale-gen

COPY docker-entrypoint.sh /entrypoint.sh

RUN chmod 775 /entrypoint.sh
RUN chmod 777 $WORKDIR
WORKDIR $WORKDIR
