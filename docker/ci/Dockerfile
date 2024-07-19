FROM centos:7.9.2009

LABEL Description="This is a build image for CUBRID manual"
RUN sed -i -e "s/^mirrorlist=http:\/\/mirrorlist.centos.org/#mirrorlist=http:\/\/mirrorlist.centos.org/g" /etc/yum.repos.d/CentOS-Base.repo
RUN sed -i -e "s/^#baseurl=http:\/\/mirror.centos.org/baseurl=https:\/\/vault.centos.org/g" /etc/yum.repos.d/CentOS-Base.repo

RUN yum install -y gcc make openssl-devel bzip2-devel libffi-devel zlib-devel unzip \
   pango cairo gdk-pixbuf2 \
   http://opensource.wandisco.com/centos/7/git/x86_64/wandisco-git-release-7-1.noarch.rpm \
   && yum clean all -y

RUN yum install -y fontconfig \
    && curl -o nanumfont.zip http://cdn.naver.com/naver/NanumFont/fontfiles/NanumFont_TTF_ALL.zip \
    && mkdir -p /usr/share/fonts/nanum \
    && unzip -d /usr/share/fonts/nanum nanumfont.zip \
    && rm nanumfont.zip

RUN yum install -y epel-release
RUN yum install -y openssl11 openssl11-devel

ENV PYTHON_VERSION 3.10.0
ENV CFLAGS -I/usr/include/openssl11
ENV LDFLAGS "-L/usr/lib64/openssl11 -lssl -lcrypto"
RUN curl -L https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz | tar xzf - \
    && cd "./Python-$PYTHON_VERSION/" \
    && ./configure \
    && make altinstall \
    && cd .. && rm -rf "./Python-$PYTHON_VERSION/"

RUN python3.10 -m pip install --upgrade pip

RUN pip3.10 install 'urllib3<2.0' Sphinx==7.3.7 pydata-sphinx-theme==0.15.4 \
    sphinx_design sphinx_copybutton myst_parser ablog sphinxcontrib.youtube \
    nbsphinx numpydoc sphinx_togglebutton sphinx_favicon sphinx_sitemap \
    weasyprint==52.5 sphinx-simplepdf

RUN localedef -f UTF-8 -i ko_KR ko_KR.utf8
