FROM rockylinux:9.3

LABEL Description="This is a build image for CUBRID manual"

RUN dnf install -y epel-release openssl-devel glibc-locale-source glibc-langpack-ko \
    gcc make openssl-devel bzip2-devel libffi-devel zlib-devel unzip pango cairo \
    git gdk-pixbuf2 python3.12 python3.12-pip vim

RUN dnf update -y

RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 1 && \
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 2 && \
    update-alternatives --set python3 /usr/bin/python3.12

RUN pip3.12 install 'urllib3<2.0' Sphinx==8.2.3 \
    sphinx_design sphinxext-rediraffe sphinxawesome-theme==6.0.0b3 \
    weasyprint==64.1 sphinx-simplepdf==1.7 sphinx-rtd-theme sphinx-autobuild

RUN dnf clean all
RUN localedef -f UTF-8 -i ko_KR ko_KR.utf8

# Add Shell command option
RUN echo 'alias ll="ls -al"' >> /etc/bashrc && \
    echo 'alias ls="ls --color=auto"' >> /etc/bashrc && \
    echo 'alias grep="grep --color=auto"' >> /etc/bashrc && \
    echo 'alias diff="diff --color=auto"' >> /etc/bashrc && \
    ln -sf /usr/bin/vim /usr/bin/vi
