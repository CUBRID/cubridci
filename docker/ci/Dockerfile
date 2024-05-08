FROM centos:7.9.2009

LABEL Description="This is a build image for CUBRID manual"

RUN yum install -y git gcc make openssl-devel bzip2-devel libffi-devel zlib-devel \
   && yum clean all -y

ENV PYTHON_VERSION 3.9.6
RUN curl -L https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz | tar xzf - \
    && cd "./Python-$PYTHON_VERSION/" \
    && ./configure --enable-optimizations \
    && make altinstall \
    && cd .. && rm -rf "./Python-$PYTHON_VERSION/"


RUN yum install -y epel-release
RUN yum install -y openssl11
RUN ln -nsf /usr/bin/openssl11 /usr/bin/openssl

RUN pip3.9 install 'urllib3<2.0' Sphinx==7.2.6 pydata-sphinx-theme==0.15.2 \
    sphinx_design sphinx_copybutton myst_parser ablog sphinxcontrib.youtube \
    nbsphinx numpydoc sphinx_togglebutton sphinx_favicon sphinx_sitemap
