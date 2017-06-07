FROM centos:7

RUN set -x \
	&& yum -y groupinstall 'Development Tools' \
	&& yum -y install which git cmake systemtap-sdt-devel ncurses-devel java-1.7.0-devel ant elfutils-libelf-devel \
	&& yum clean all

ENV HOME /home/cubrid
ENV CUBRID /home/CUBRID

ENV JAVA_HOME /usr/lib/jvm/java

LABEL Description="This is a build environment image for CUBRID"

VOLUME $HOME
VOLUME $CUBRID

WORKDIR $HOME

COPY docker-entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
