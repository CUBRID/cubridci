#ARG BUILD_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2016
#ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:1809
#FROM $BUILD_IMAGE as installer-env

FROM mcr.microsoft.com/windows/servercore:ltsc2019 AS installer
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ARG CUBRID_VERSION="11.2-latest"
ARG CUBRID_PATH="C:\cubrid"
ARG INSTALL_PATH="C:\install"
ARG VS_INSTALL_PATH="C:\install\vs_community.exe"

ENV WORKDIR "C:\"
ENV INSTALLDIR ${INSTALL_PATH}

ENV CUBRID_VERSION ${CUBRID_VERSION}
ENV CUBRID ${CUBRID_PATH}
ENV CUBRID_DATABASES ${CUBRID}\databases
ENV PATH ${CUBRID}\bin:$PATH
ENV LD_LIBRARY_PATH ${CUBRID}\lib
ENV TEST_SUITE medium:sql
ENV TEST_REPORT /tmp/tests
ENV BRANCH_TESTTOOLS develop
ENV BRANCH_TESTCASES release/11.2

# Install Chocolatey
RUN Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1')); \
    [System.Environment]::SetEnvironmentVariable('PATH', "\"${env:PATH};%ALLUSERSPROFILE%\chocolatey\bin\"", 'Machine'); \

# Install tools with chocolatey
RUN choco feature enable -n allowGlobalConfirmation;
RUN choco install git git-lfs git-credential-manager-for-windows --no-progress -y
RUN choco install jdk8 --force --no-progress -y \
RUN choco install cmake --version=3.26.3 --no-progress -y \
RUN choco install winflexbison wixtoolset --no-progress -y \
RUN choco install ant --ignore-dependencies --no-progress -y

RUN $env:ANT="C:\ProgramData\chocolatey\bin\ant.exe"

# Install VS 2017 community
SHELL ["cmd", "/S", "/C"]
ADD "https://aka.ms/vs/15/release/vs_community.exe" "${VS_INSTALL_PATH}"

# please refer module ids of Visual Studio 2017 :
# https://learn.microsoft.com/en-us/previous-versions/visualstudio/visual-studio-2017/install/workload-component-id-vs-build-tools?view=vs-2017
RUN ${VS_INSTALL_PATH} --includeRecommended --includeOptional --quiet --nocache --norestart --wait \
	--add Microsoft.Component.MSBuild \
	--add Microsoft.VisualStudio.Component.TextTemplating \
	--add Component.Linux.CMake \
	--add Component.MDD.Linux \
	--add Microsoft.VisualStudio.Component.VC.CoreIde \
	--add Microsoft.VisualStudio.Component.CoreEditor \
	--add Microsoft.VisualStudio.Component.VC.140 \
	--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
	--add Microsoft.Component.VC.Runtime.UCRTSDK \
	--add Microsoft.VisualStudio.Component.VC.ATLMFC \
	--add Microsoft.VisualStudio.Component.VC.CLI.Support \
    || IF "%ERRORLEVEL%"=="3010" EXIT 0

RUN Copy-Item "C:\Program Files (x86)\Microsoft Visual Studio\2017\Community\VC\Redist\MSVC\14.16.27012\MergeModules\*" -Destination "C:\Program Files (x86)\Common Files\Merge Modules"

# COPY docker-entrypoint-windows.ps1 /entrypoint.ps1
COPY docker-entrypoint.sh /entrypoint.sh

RUN chmod 775 /entrypoint.sh
RUN chmod 777 $WORKDIR
WORKDIR $WORKDIR

SHELL ["bash.exe", "-c"]
ENTRYPOINT ["/docker-entrypoint.sh"]