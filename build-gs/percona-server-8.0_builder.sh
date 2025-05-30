#!/bin/sh

shell_quote_string() {
  echo "$1" | sed -e 's,\([^a-zA-Z0-9/_.=-]\),\\\1,g'
}

usage () {
    cat <<EOF
Usage: $0 [OPTIONS]
    The following options may be given :
        --builddir=DIR      Absolute path to the dir where all actions will be performed
        --get_sources       Source will be downloaded from github
        --build_src_rpm     If it is 1 src rpm will be built
        --build_source_deb  If it is 1 source deb package will be built
        --build_rpm         If it is 1 rpm will be built
        --build_deb         If it is 1 deb will be built
        --build_tarball     If it is 1 tarball will be built
        --with_ssl          If it is 1 tarball will also include ssl libs
        --with_ssl_gm       If it is 1, openssl with gm will be activated
        --install_deps      Install build dependencies(root previlages are required)
        --branch            Branch for build
        --repo              Repo for build
        --perconaft_repo    PerconaFT repo
        --perconaft_branch  Branch for PerconaFT
        --tokubackup_repo   TokuBackup repo
        --tokubackup_branch Btanch for TokuBackup
        --rpm_release       RPM version( default = 1)
        --deb_release       DEB version( default = 1)
        --no_git_info       Not in an git branch
        --local_boost       No need download boost
        --help) usage ;;
Example $0 --builddir=/tmp/PS57 --get_sources=1 --build_src_rpm=1 --build_rpm=1
EOF
        exit 1
}

append_arg_to_args () {
  args="$args "$(shell_quote_string "$1")
}

parse_arguments() {
    pick_args=
    if test "$1" = PICK-ARGS-FROM-ARGV
    then
        pick_args=1
        shift
    fi

    for arg do
        val=$(echo "$arg" | sed -e 's;^--[^=]*=;;')
        case "$arg" in
            # these get passed explicitly to mysqld
            --builddir=*) WORKDIR="$val" ;;
            --build_src_rpm=*) SRPM="$val" ;;
            --build_source_deb=*) SDEB="$val" ;;
            --build_rpm=*) RPM="$val" ;;
            --build_deb=*) DEB="$val" ;;
            --get_sources=*) SOURCE="$val" ;;
            --build_tarball=*) TARBALL="$val" ;;
            --with_ssl=*) WITH_SSL="$val" ;;
            --with_ssl_gm=*) WITH_SSL_GM="$val" ;;
            --branch=*) BRANCH="$val" ;;
            --repo=*) REPO="$val" ;;
            --install_deps=*) INSTALL="$val" ;;
            --perconaft_branch=*) PERCONAFT_BRANCH="$val" ;;
            --tokubackup_branch=*)      TOKUBACKUP_BRANCH="$val" ;;
            --perconaft_repo=*) PERCONAFT_REPO="$val" ;;
            --tokubackup_repo=*) TOKUBACKUP_REPO="$val" ;;
            --rpm_release=*) RPM_RELEASE="$val" ;;
            --deb_release=*) DEB_RELEASE="$val" ;;
            --with_debug=*) WITH_DEBUG="$val" ;;
            --no_git_info=*) NO_GIT_INFO="$val" ;;
            --local_boost=*) LOCAL_BOOST="$val" ;;
            --help) usage ;;
            *)
              if test -n "$pick_args"
              then
                  append_arg_to_args "$arg"
              fi
              ;;
        esac
    done
}

check_workdir(){
    if [ "x$WORKDIR" = "x$CURDIR" ]
    then
        echo >&2 "Current directory cannot be used for building!"
        exit 1
    else
        if ! test -d "$WORKDIR"
        then
            echo >&2 "$WORKDIR is not a directory."
            exit 1
        fi
    fi
    return
}

add_percona_yum_repo(){
    if [ ! -f /etc/yum.repos.d/percona-dev.repo ]
    then
        curl -o /etc/yum.repos.d/percona-dev.repo https://jenkins.percona.com/yum-repo/percona-dev.repo
	sed -i 's:$basearch:x86_64:g' /etc/yum.repos.d/percona-dev.repo
    fi
    return
}

get_sources(){
    if [ "${SOURCE}" = 0 ]
    then
        echo "Sources will not be downloaded"
        return 0
    fi
    cd "${WORKDIR}"

   
    cd ${CURDIR}/../
    REVISION=$(git rev-parse --short HEAD)
    #git reset --hard
    source MYSQL_VERSION
    cat MYSQL_VERSION > ${WORKDIR}/percona-server-8.0.properties
    echo "REVISION=${REVISION}" >> ${WORKDIR}/percona-server-8.0.properties
    BRANCH_NAME="${BRANCH}"
    echo "BRANCH_NAME=${BRANCH_NAME}" >> ${WORKDIR}/percona-server-8.0.properties
    export PRODUCT=Percona-Server-${MYSQL_VERSION_MAJOR}.${MYSQL_VERSION_MINOR}
    echo "PRODUCT=Percona-Server-${MYSQL_VERSION_MAJOR}.${MYSQL_VERSION_MINOR}" >> ${WORKDIR}/percona-server-8.0.properties
    export PRODUCT_FULL=${PRODUCT}.${MYSQL_VERSION_PATCH}${MYSQL_VERSION_EXTRA}
    echo "PRODUCT_FULL=${PRODUCT}.${MYSQL_VERSION_PATCH}${MYSQL_VERSION_EXTRA}" >> ${WORKDIR}/percona-server-8.0.properties
    echo "BUILD_NUMBER=${BUILD_NUMBER}" >> ${WORKDIR}/percona-server-8.0.properties
    echo "BUILD_ID=${BUILD_ID}" >> ${WORKDIR}/percona-server-8.0.properties
    #echo "PERCONAFT_REPO=${PERCONAFT_REPO}" >> ${WORKDIR}/percona-server-8.0.properties
    #echo "PERCONAFT_BRANCH=${PERCONAFT_BRANCH}" >> ${WORKDIR}/percona-server-8.0.properties
    #echo "TOKUBACKUP_REPO=${TOKUBACKUP_REPO}" >> ${WORKDIR}/percona-server-8.0.properties
    #echo "TOKUBACKUP_BRANCH=${TOKUBACKUP_BRANCH}" >> ${WORKDIR}/percona-server-8.0.properties
    #echo "TOKUDB_VERSION=${MYSQL_VERSION_MAJOR}.${MYSQL_VERSION_MINOR}.${MYSQL_VERSION_PATCH}${MYSQL_VERSION_EXTRA}" >> ${WORKDIR}/percona-server-8.0.properties
    BOOST_PACKAGE_NAME=$(cat cmake/boost.cmake|grep "SET(BOOST_PACKAGE_NAME"|awk -F '"' '{print $2}')
    echo "BOOST_PACKAGE_NAME=${BOOST_PACKAGE_NAME}" >> ${WORKDIR}/percona-server-8.0.properties
    echo "RPM_RELEASE=${RPM_RELEASE}" >> ${WORKDIR}/percona-server-8.0.properties
    echo "DEB_RELEASE=${DEB_RELEASE}" >> ${WORKDIR}/percona-server-8.0.properties

    if [ -z "${DESTINATION:-}" ]; then
        export DESTINATION=experimental
    fi
    TIMESTAMP=$(date "+%Y%m%d-%H%M%S")
    echo "DESTINATION=${DESTINATION}" >> ${WORKDIR}/percona-server-8.0.properties
    echo "UPLOAD=UPLOAD/${DESTINATION}/BUILDS/${PRODUCT}/${PRODUCT_FULL}/${BRANCH_NAME}/${REVISION}/${TIMESTAMP}" >> ${WORKDIR}/percona-server-8.0.properties

    #rm -rf storage/tokudb/PerconaFT
    #rm -rf plugin/tokudb-backup-plugin/Percona-TokuBackup
    git submodule init
    git submodule update
    #rm -rf storage/tokudb/PerconaFT
    #rm -rf plugin/tokudb-backup-plugin/Percona-TokuBackup
    #if [ ${PERCONAFT_REPO} = 0 ]; then
    #    PERCONAFT_REPO=''
    #fi
    #if [ ${TOKUBACKUP_REPO} = 0 ]; then
    #    TOKUBACKUP_REPO=''
    #fi

    #if [ -z ${PERCONAFT_REPO} -a -z ${TOKUBACKUP_REPO} ]; then
    #    mkdir plugin/tokudb-backup-plugin/Percona-TokuBackup
    #    mkdir storage/tokudb/PerconaFT
    #    git submodule init
    #    git submodule update
    #    cd storage/tokudb/PerconaFT
    #    git fetch origin
    #    git checkout ${PERCONAFT_BRANCH}
    #    if [ ${PERCONAFT_BRANCH} = "master" ]; then
    #        git pull
    #    fi
    #    cd ${WORKDIR}/greatsql
    #    #
    #    cd plugin/tokudb-backup-plugin/Percona-TokuBackup
    #    git fetch origin
    #    git checkout ${TOKUBACKUP_BRANCH}
    #    if [ ${TOKUBACKUP_BRANCH} = "master" ]; then
    #        git pull
    #    fi
    #    cd ${WORKDIR}/greatsql
    #else
    #    cd storage/tokudb
    #    git clone ${PERCONAFT_REPO}
    #    cd PerconaFT
    #    git checkout ${PERCONAFT_BRANCH}
    #    cd ${WORKDIR}/greatsql
    #    #
    #    cd plugin/tokudb-backup-plugin
    #    git clone ${TOKUBACKUP_REPO}
    #    cd Percona-TokuBackup
    #    git checkout ${TOKUBACKUP_BRANCH}
    #    cd ${WORKDIR}/greatsql
    #fi
    ##
    git submodule update
#cd storage/rocksdb/rocksdb_plugins/zenfs
#   ZEN_VER=$(git describe --abbrev=7 --dirty)
#   sed -i "s/^VERSION=.*/VERSION=$ZEN_VER/" generate-version.sh
#   ./generate-version.sh
    cd -

    cd ${WORKDIR}
    mkdir -p mybuild
    cd mybuild
    #if [ "x$RHEL" = "x8" ]; then
    #   export CC=${CC:-gcc}
    #   export CXX=${CXX:-g++}
    #fi
    env
    if [ $LOCAL_BOOST = 0 ]
    then
      cmake3 ${CURDIR}/..  -DWITH_SSL=system -DWITH_ZLIB=bundled -DWITH_TOKUDB=0 -DWITH_ROCKSDB=OFF -DGROUP_REPLICATION_WITH_ROCKSDB=OFF -DALLOW_NO_SSE42=ON -DFORCE_INSOURCE_BUILD=1 -DWITH_AUTHENTICATION_LDAP=OFF -DDOWNLOAD_BOOST=1 -DWITH_BOOST=${CURDIR}/boost_1_77_0.tar.bz2
    else
      tar -xzvf ${CURDIR}/boost_1_77_0.tar.gz -C ${CURDIR}
      cmake3 ${CURDIR}/..  -DWITH_SSL=system -DWITH_ZLIB=bundled -DWITH_TOKUDB=0 -DWITH_ROCKSDB=OFF -DGROUP_REPLICATION_WITH_ROCKSDB=OFF -DALLOW_NO_SSE42=ON -DFORCE_INSOURCE_BUILD=1 -DWITH_AUTHENTICATION_LDAP=OFF -DDOWNLOAD_BOOST=0 -DWITH_BOOST=${CURDIR}/boost_1_77_0
    fi
    make dist
    #
    EXPORTED_TAR=$(basename $(find . -type f -name greatsql*.tar.gz | sort | tail -n 1))
    #
    PSDIR=${EXPORTED_TAR%.tar.gz}
    rm -fr ${PSDIR}
    tar xzf ${EXPORTED_TAR}
    rm -f ${EXPORTED_TAR}
    # add git submodules because make dist uses git archive which doesn't include them
    #rsync -av storage/tokudb/PerconaFT ${PSDIR}/storage/tokudb --exclude .git
    #rsync -av plugin/tokudb-backup-plugin/Percona-TokuBackup ${PSDIR}/plugin/tokudb-backup-plugin --exclude .git
    rsync -av ${CURDIR}/../storage/rocksdb/rocksdb/ ${PSDIR}/storage/rocksdb/rocksdb --exclude .git
    rsync -av ${CURDIR}/../storage/rocksdb/rocksdb_plugins/zenfs ${PSDIR}/storage/rocksdb/rocksdb_plugins/zenfs --exclude .git
    #rsync -av storage/rocksdb/third_party/lz4/ ${PSDIR}/storage/rocksdb/third_party/lz4 --exclude .git
    #rsync -av storage/rocksdb/third_party/zstd/ ${PSDIR}/storage/rocksdb/third_party/zstd --exclude .git
    rsync -av ${CURDIR}/../extra/coredumper/ ${PSDIR}/extra/coredumper --exclude .git
    rsync -av ${CURDIR}/../extra/libkmip ${PSDIR}/extra --exclude .git
    rsync -av ${CURDIR}/../extra/libzbd ${PSDIR}/extra --exclude .git
    #
    cd ${WORKDIR}/mybuild/${PSDIR}
    # set tokudb version - can be seen with show variables like '%version%'
    #sed -i "1s/^/SET(TOKUDB_VERSION ${TOKUDB_VERSION})\n/" storage/tokudb/CMakeLists.txt
    #
    sed -i "s:@@PERCONA_VERSION_EXTRA@@:${MYSQL_VERSION_EXTRA#-}:g" build-gs/debian/rules
    sed -i "s:@@REVISION@@:${REVISION}:g" build-gs/debian/rules
    #sed -i "s:@@TOKUDB_BACKUP_VERSION@@:${TOKUDB_VERSION}:g" build-gs/debian/rules
    #
    sed -i "s:@@MYSQL_VERSION@@:${MYSQL_VERSION_MAJOR}.${MYSQL_VERSION_MINOR}.${MYSQL_VERSION_PATCH}:g" build-gs/percona-server.spec
    sed -i "s:@@PERCONA_VERSION@@:${MYSQL_VERSION_EXTRA#-}:g" build-gs/percona-server.spec
    sed -i "s:@@REVISION@@:${REVISION}:g" build-gs/percona-server.spec
    sed -i "s:@@RPM_RELEASE@@:${RPM_RELEASE}:g" build-gs/percona-server.spec
    sed -i "s:@@BOOST_PACKAGE_NAME@@:${BOOST_PACKAGE_NAME}:g" build-gs/percona-server.spec
    cd ${WORKDIR}/mybuild
    if [ $SRPM = 0 ]; then
      tar --owner=0 --group=0 --exclude=.bzr --exclude=.git --exclude=.gitconfig --exclude=.gitlab-ci.yml -czf ${PSDIR}.tar.gz ${PSDIR}
    else
      tar --owner=0 --group=0 --exclude=.bzr --exclude=.git --exclude=.gitconfig --exclude=.gitlab-ci.yml -czf ${PSDIR}.tar.gz ${PSDIR}
    fi

    mkdir -p $WORKDIR/source_tarball
    mkdir -p $CURDIR/source_tarball
    cp ${PSDIR}.tar.gz $WORKDIR/source_tarball
    cp ${PSDIR}.tar.gz $CURDIR/source_tarball
    cd $CURDIR
    return
}

get_system(){
    if [ -f /etc/redhat-release ]; then
	GLIBC_VER_TMP="$(rpm glibc -qa --qf %{VERSION})"
        RHEL=$(rpm --eval %rhel)
        ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
        OS_NAME="el$RHEL"
        OS="rpm"
    else
	GLIBC_VER_TMP="$(dpkg-query -W -f='${Version}' libc6 | awk -F'-' '{print $1}')"
        ARCH=$(uname -m)
        OS_NAME="$(lsb_release -sc)"
        OS="deb"
    fi
    export GLIBC_VER="glibc${GLIBC_VER_TMP}"
    return
}

install_deps() {
    if [ $INSTALL = 0 ]
    then
        echo "Dependencies will not be installed"
        return;
    fi
    if [ ! $( id -u ) -eq 0 ]
    then
        echo "It is not possible to instal dependencies. Please run as root"
        exit 1
    fi
    CURPLACE=$(pwd)

    if [ "x$OS" = "xrpm" ]; then
        RHEL=$(rpm --eval %rhel)
        ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
#add_percona_yum_repo
        yum install -y percona-release-latest.noarch.rpm
        percona-release enable tools testing
        yum -y install epel-release
        yum -y install git numactl-devel rpm-build gcc-c++ gperf ncurses-devel perl readline-devel openssl-devel jemalloc zstd
        if [ "${RHEL}" -lt 8 ]; then
          yum -y install zstd-devel
        else
          yum -y install libarchive.x86_64
        fi
        yum -y install time zlib-devel libaio-devel bison cmake3 cmake pam-devel jemalloc-devel pkg-config
        if [ "${RHEL}" -lt 8 ]; then
          yum -y install libeatmydata
        fi
        yum -y install perl-Time-HiRes libcurl-devel openldap-devel unzip wget libcurl-devel patchelf
        yum -y install perl-Env perl-Data-Dumper perl-JSON MySQL-python perl-Digest perl-Digest-MD5 perl-Digest-Perl-MD5 || true
        if [ "${RHEL}" -lt 7 ]; then
            until yum -y install centos-release-scl; do
                echo "waiting"
                sleep 1
            done
            yum -y install  gcc-c++ devtoolset-8-gcc-c++ devtoolset-8-binutils devtoolset-8-gcc devtoolset-8-gcc-c++
            yum -y install ccache devtoolset-8-libasan-devel devtoolset-8-libubsan-devel devtoolset-8-valgrind devtoolset-8-valgrind-devel
            yum -y install libasan libicu-devel libtool libzstd-devel lz4-devel make pkg-config
            yum -y install re2-devel redhat-lsb-core lz4-static
            source /opt/rh/devtoolset-8/enable
        elif [ "${RHEL}" -lt 8 ]; then
            until yum -y install centos-release-scl; do
                echo "waiting"
                sleep 1
            done
            yum -y install  gcc-c++ devtoolset-10-gcc-c++ devtoolset-10-binutils devtoolset-10-gcc devtoolset-10-gcc-c++
            yum -y install ccache devtoolset-10-libasan-devel devtoolset-10-libubsan-devel devtoolset-10-valgrind devtoolset-10-valgrind-devel
            yum -y install libasan libicu-devel libtool libzstd-devel lz4-devel make pkg-config
            yum -y install re2-devel redhat-lsb-core lz4-static
            source /opt/rh/devtoolset-10/enable
        else
	    yum -y install perl.x86_64
            yum -y install binutils gcc gcc-c++ tar rpm-build rsync bison glibc glibc-devel libstdc++-devel make openssl-devel pam-devel perl perl-JSON perl-Memoize pkg-config
            yum -y install automake autoconf cmake cmake3 jemalloc jemalloc-devel
	    yum -y install libaio-devel ncurses-devel numactl-devel readline-devel time
	    yum -y install rpcgen re2-devel libtirpc-devel
	    yum -y install zstd libzstd libzstd-devel
        fi
        if [ "x$RHEL" = "x6" ]; then
            yum -y install Percona-Server-shared-56
	          yum -y install libevent2-devel
	      else
            yum -y install libevent-devel
        fi
    else
        apt-get -y install dirmngr || true
        apt-get update
        apt-get -y install dirmngr || true
        apt-get -y install lsb-release wget
        wget https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb && dpkg -i percona-release_latest.$(lsb_release -sc)_all.deb
        percona-release enable tools testing
        export DEBIAN_FRONTEND="noninteractive"
        export DIST="$(lsb_release -sc)"
            until sudo apt-get update; do
            sleep 1
            echo "waiting"
        done
        apt-get -y purge eatmydata || true

        apt-get update
        apt-get -y install psmisc pkg-config
        apt-get -y install libsasl2-modules:amd64 || apt-get -y install libsasl2-modules
        apt-get -y install dh-systemd || true
        apt-get -y install curl bison cmake perl libssl-dev gcc g++ libaio-dev libldap2-dev libwrap0-dev gdb unzip gawk
        apt-get -y install lsb-release libmecab-dev libncurses5-dev libreadline-dev libpam-dev zlib1g-dev libcurl4-openssl-dev
        apt-get -y install libldap2-dev libnuma-dev libjemalloc-dev libc6-dbg valgrind libjson-perl libsasl2-dev patchelf
        if [ x"${DIST}" = xfocal ]; then
            apt-get -y install python3-mysqldb
        else
            apt-get -y install python-mysqldb
        fi
        apt-get -y install libeatmydata
        apt-get -y install libmecab2 mecab mecab-ipadic
        apt-get -y install build-essential devscripts doxygen doxygen-gui graphviz rsync
        apt-get -y install cmake autotools-dev autoconf automake build-essential devscripts debconf debhelper fakeroot libaio-dev
        apt-get -y install ccache libevent-dev libgsasl7 liblz4-dev libre2-dev libtool po-debconf
        if [ x"${DIST}" = xfocal -o x"${DIST}" = xbionic -o x"${DIST}" = xdisco -o x"${DIST}" = xbuster ]; then
            apt-get -y install libeatmydata1
        fi
        if [ x"${DIST}" = xfocal -o x"${DIST}" = xbionic -o x"${DIST}" = xstretch -o x"${DIST}" = xdisco -o x"${DIST}" = xbuster ]; then
            apt-get -y install libzstd-dev
        else
            apt-get -y install libzstd1-dev
        fi
    fi
    if [ ! -d /usr/local/percona-subunit2junitxml ]; then
        cd /usr/local
        git clone https://gitee.com/mirrors_percona/percona-subunit2junitxml.git
        rm -rf /usr/bin/subunit2junitxml
        ln -s /usr/local/percona-subunit2junitxml/subunit2junitxml /usr/bin/subunit2junitxml
        cd ${CURPLACE}
    fi
    return;
}

get_tar(){
    TARBALL=$1
    TARFILE=$(basename $(find $WORKDIR/$TARBALL -name 'greatsql*.tar.gz' | sort | tail -n1))
    if [ -z $TARFILE ]
    then
        TARFILE=$(basename $(find $CURDIR/$TARBALL -name 'greatsql*.tar.gz' | sort | tail -n1))
        if [ -z $TARFILE ]
        then
            echo "There is no $TARBALL for build"
            exit 1
        else
            cp $CURDIR/$TARBALL/$TARFILE $WORKDIR/$TARFILE
        fi
    else
        cp $WORKDIR/$TARBALL/$TARFILE $WORKDIR/$TARFILE
    fi
    return
}

get_deb_sources(){
    param=$1
    echo $param
    FILE=$(basename $(find $WORKDIR/source_deb -name "greatsql*.$param" | sort | tail -n1))
    if [ -z $FILE ]
    then
        FILE=$(basename $(find $CURDIR/source_deb -name "greatsql*.$param" | sort | tail -n1))
        if [ -z $FILE ]
        then
            echo "There is no sources for build"
            exit 1
        else
            cp $CURDIR/source_deb/$FILE $WORKDIR/
        fi
    else
        cp $WORKDIR/source_deb/$FILE $WORKDIR/
    fi
    return
}

build_srpm(){
    if [ $SRPM = 0 ]
    then
        echo "SRC RPM will not be created"
        return;
    fi
    if [ "x$OS" = "xdeb" ]
    then
        echo "It is not possible to build src rpm here"
        exit 1
    fi
    cd $WORKDIR
    if [ $NO_GIT_INFO = 0 ]
    then
      get_tar "source_tarball"
    fi
    rm -fr rpmbuild
    ls | grep -v greatsql*.tar.* | xargs rm -rf
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    TARFILE=$(basename $(find . -name 'greatsql-*.tar.gz' | sort | tail -n1))
    NAME=$(echo ${TARFILE}| awk -F '-' '{print $1"-"$2}')
    VERSION=$(echo ${TARFILE}| awk -F '-' '{print $3}')
    #
    SHORTVER=$(echo ${VERSION} | awk -F '.' '{print $1"."$2}')
    TMPREL=$(echo ${TARFILE}| awk -F '-' '{print $4}')
    RELEASE=${TMPREL%.tar.gz}
    #
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}
    #
    cd ${WORKDIR}/rpmbuild/SPECS
    tar vxzf ${WORKDIR}/${TARFILE} --wildcards '*/build-gs/*.spec' --strip=2
    #
    cd ${WORKDIR}/rpmbuild/SOURCES
    if [ $LOCAL_BOOST = 0 ]
    then
      #wget https://dl.bintray.com/boostorg/release/1.73.0/source/${BOOST_PACKAGE_NAME}.tar.gz
      wget https://boostorg.jfrog.io/artifactory/main/release/1.77.0/source/boost_1_77_0.tar.gz
      #wget http://downloads.sourceforge.net/boost/${BOOST_PACKAGE_NAME}.tar.gz
      #wget http://jenkins.percona.com/downloads/boost/${BOOST_PACKAGE_NAME}.tar.gz
    else
      cp ${CURDIR}/boost_1_77_0.tar.gz .
    fi
    tar vxzf ${WORKDIR}/${TARFILE} --wildcards '*/build-gs/rpm/*.patch' --strip=3
    tar vxzf ${WORKDIR}/${TARFILE} --wildcards '*/build-gs/rpm/filter-provides.sh' --strip=3
    tar vxzf ${WORKDIR}/${TARFILE} --wildcards '*/build-gs/rpm/filter-requires.sh' --strip=3
    tar vxzf ${WORKDIR}/${TARFILE} --wildcards '*/build-gs/rpm/mysql_config.sh' --strip=3
    #
    cd ${WORKDIR}
    #
    mv -fv ${TARFILE} ${WORKDIR}/rpmbuild/SOURCES
    #
    rpmbuild -bs --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .generic" rpmbuild/SPECS/percona-server.spec
    #

    mkdir -p ${WORKDIR}/srpm
    mkdir -p ${CURDIR}/srpm
    cp rpmbuild/SRPMS/*.src.rpm ${CURDIR}/srpm
    cp rpmbuild/SRPMS/*.src.rpm ${WORKDIR}/srpm
    return
}

build_mecab_lib(){
    MECAB_TARBAL="mecab-0.996.tar.gz"
    MECAB_LINK="http://jenkins.percona.com/downloads/mecab/${MECAB_TARBAL}"
    MECAB_DIR="${WORKDIR}/${MECAB_TARBAL%.tar.gz}"
    MECAB_INSTALL_DIR="${WORKDIR}/mecab-install"
    rm -f ${MECAB_TARBAL}
    rm -rf ${MECAB_DIR}
    rm -rf ${MECAB_INSTALL_DIR}
    mkdir ${MECAB_INSTALL_DIR}
    wget ${MECAB_LINK}
    tar xf ${MECAB_TARBAL}
    cd ${MECAB_DIR}
    if [ ${ARCH} = aarch64 ]; then
        ./configure --with-pic --prefix=/usr --build=arm-linux
    else
        ./configure --with-pic --prefix=/usr
    fi
    make
    make check
    make DESTDIR=${MECAB_INSTALL_DIR} install
    cd ${MECAB_INSTALL_DIR}
    if [ -d usr/lib64 ]; then
  mkdir -p usr/lib
        mv usr/lib64/* usr/lib
    fi
    cd ${WORKDIR}
}

build_mecab_dict(){
    MECAB_IPADIC_TARBAL="mecab-ipadic-2.7.0-20070801.tar.gz"
    MECAB_IPADIC_LINK="http://jenkins.percona.com/downloads/mecab/${MECAB_IPADIC_TARBAL}"
    MECAB_IPADIC_DIR="${WORKDIR}/${MECAB_IPADIC_TARBAL%.tar.gz}"
    rm -f ${MECAB_IPADIC_TARBAL}
    rm -rf ${MECAB_IPADIC_DIR}
    wget ${MECAB_IPADIC_LINK}
    tar xf ${MECAB_IPADIC_TARBAL}
    cd ${MECAB_IPADIC_DIR}
    # these two lines should be removed if proper packages are created and used for builds
    export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:${MECAB_INSTALL_DIR}/usr/lib
    sed -i "/MECAB_DICT_INDEX=\"/c\MECAB_DICT_INDEX=\"${MECAB_INSTALL_DIR}\/usr\/libexec\/mecab\/mecab-dict-index\"" configure
    #
    if [ ${ARCH} = aarch64 ]; then
        ./configure --with-mecab-config=${MECAB_INSTALL_DIR}/usr/bin/mecab-config --build=arm-linux
    else
        ./configure --with-mecab-config=${MECAB_INSTALL_DIR}/usr/bin/mecab-config
    fi
    make
    make DESTDIR=${MECAB_INSTALL_DIR} install
    cd ../
    cd ${MECAB_INSTALL_DIR}
    if [ -d usr/lib64 ]; then
        mv usr/lib64/* usr/lib
    fi
    cd ${WORKDIR}
}

build_rpm(){
    if [ $RPM = 0 ]
    then
        echo "RPM will not be created"
        return;
    fi
    if [ "x$OS" = "xdeb" ]
    then
        echo "It is not possible to build rpm here"
        exit 1
    fi
    SRC_RPM=$(basename $(find $WORKDIR/srpm -name 'greatsql-*.src.rpm' | sort | tail -n1))
    if [ -z $SRC_RPM ]
    then
        SRC_RPM=$(basename $(find $CURDIR/srpm -name 'greatsql-*.src.rpm' | sort | tail -n1))
        if [ -z $SRC_RPM ]
        then
            echo "There is no src rpm for build"
            echo "You can create it using key --build_src_rpm=1"
            exit 1
        else
            cp $CURDIR/srpm/$SRC_RPM $WORKDIR
        fi
    else
        cp $WORKDIR/srpm/$SRC_RPM $WORKDIR
    fi
    cd $WORKDIR
    rm -fr rpmbuild
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}
    cp $SRC_RPM rpmbuild/SRPMS/

    RHEL=$(rpm --eval %rhel)
    ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
    #
    echo "RHEL=${RHEL}" >> percona-server-8.0.properties
    echo "ARCH=${ARCH}" >> percona-server-8.0.properties
    #
    SRCRPM=$(basename $(find . -name '*.src.rpm' | sort | tail -n1))
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}
    #
    mv *.src.rpm rpmbuild/SRPMS
    RHEL=$(rpm --eval %rhel)
    if [ "${RHEL}" -lt 7 ]; then
        source /opt/rh/devtoolset-11/enable
    elif [ "${RHEL}" -lt 8 ]; then
        source /opt/rh/devtoolset-11/enable
    elif [ -f "/opt/rh/gcc-toolset-10/enable" ]; then
        source /opt/rh/gcc-toolset-10/enable
    fi
    build_mecab_lib
    build_mecab_dict

    cd ${WORKDIR}
    if [ "${RHEL}" -lt 7 ]; then
        source /opt/rh/devtoolset-11/enable
    elif [ "${RHEL}" -lt 8 ]; then
        source /opt/rh/devtoolset-11/enable
    elif [ -f "/opt/rh/gcc-toolset-10/enable" ]; then
        source /opt/rh/gcc-toolset-10/enable
    fi
    #
    if [ ${ARCH} = x86_64 ]; then
        rpmbuild --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .el${RHEL}" --define "with_tokudb 0" --define "with_rocksdb 0"  --define "with_mecab ${MECAB_INSTALL_DIR}/usr" --define 'with_debuginfo 1' --rebuild rpmbuild/SRPMS/${SRCRPM}
    else
        rpmbuild --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .el${RHEL}" --define "with_tokudb 0" --define "with_rocksdb 0" --define "with_mecab ${MECAB_INSTALL_DIR}/usr" --define 'with_debuginfo 1' --rebuild rpmbuild/SRPMS/${SRCRPM}
    fi
    return_code=$?
    if [ $return_code != 0 ]; then
        exit $return_code
    fi
    mkdir -p ${WORKDIR}/rpm
    mkdir -p ${CURDIR}/rpm
    cp rpmbuild/RPMS/*/*.rpm ${WORKDIR}/rpm
    cp rpmbuild/RPMS/*/*.rpm ${CURDIR}/rpm

}

build_source_deb(){
    if [ $SDEB = 0 ]
    then
        echo "source deb package will not be created"
        return;
    fi
    if [ "x$OS" = "xrpm" ]
    then
        echo "It is not possible to build source deb here"
        exit 1
    fi
    rm -rf greatsql*
    get_tar "source_tarball"
    rm -f *.dsc *.orig.tar.gz *.debian.tar.gz *.changes
    #

    TARFILE=$(basename $(find . -name 'greatsql-*.tar.gz' | grep -v tokudb | sort | tail -n1))

    NAME=$(echo ${TARFILE}| awk -F '-' '{print $1"-"$2}')
    VERSION=$(echo ${TARFILE}| awk -F '-' '{print $3}')
    SHORTVER=$(echo ${VERSION} | awk -F '.' '{print $1"."$2}')
    TMPREL=$(echo ${TARFILE}| awk -F '-' '{print $4}')
    RELEASE=${TMPREL%.tar.gz}

    NEWTAR=greatsql_${VERSION}-${RELEASE}.orig.tar.gz
    mv ${TARFILE} ${NEWTAR}

    tar xzf ${NEWTAR}
    ls -la
    cd greatsql-${VERSION}-${RELEASE}
    cp -ap build-gs/debian/ .
    dch -D unstable --force-distribution -v "${VERSION}-${RELEASE}-${DEB_RELEASE}" "Update to new upstream release Percona Server ${VERSION}-${RELEASE}-1"
    dpkg-buildpackage -S

    cd ${WORKDIR}

    mkdir -p $WORKDIR/source_deb
    mkdir -p $CURDIR/source_deb
    cp *.debian.tar.* $WORKDIR/source_deb
    cp *_source.changes $WORKDIR/source_deb
    cp *.dsc $WORKDIR/source_deb
    cp *.orig.tar.gz $WORKDIR/source_deb
    cp *.debian.tar.* $CURDIR/source_deb
    cp *_source.changes $CURDIR/source_deb
    cp *.dsc $CURDIR/source_deb
    cp *.orig.tar.gz $CURDIR/source_deb
}

build_deb(){
    if [ $DEB = 0 ]
    then
        echo "source deb package will not be created"
        return;
    fi
    if [ "x$OS" = "xrpm" ]
    then
        echo "It is not possible to build source deb here"
        exit 1
    fi
    for file in 'dsc' 'orig.tar.gz' 'changes' 'debian.tar*'
    do
        get_deb_sources $file
    done
    cd $WORKDIR
    rm -fv *.deb

    export DEBIAN_VERSION="$(lsb_release -sc)"

    DSC=$(basename $(find . -name '*.dsc' | sort | tail -n 1))
    DIRNAME=$(echo ${DSC%-${DEB_RELEASE}.dsc} | sed -e 's:_:-:g')
    VERSION=$(echo ${DSC} | sed -e 's:_:-:g' | awk -F'-' '{print $3}')
    RELEASE=$(echo ${DSC} | sed -e 's:_:-:g' | awk -F'-' '{print $4}')
    ARCH=$(uname -m)
    export EXTRAVER=${MYSQL_VERSION_EXTRA#-}
    #
    echo "ARCH=${ARCH}" >> percona-server-8.0.properties
    echo "DEBIAN_VERSION=${DEBIAN_VERSION}" >> percona-server-8.0.properties
    echo "VERSION=${VERSION}" >> percona-server-8.0.properties
    #

    dpkg-source -x ${DSC}

    cd ${DIRNAME}
    dch -b -m -D "$DEBIAN_VERSION" --force-distribution -v "${VERSION}-${RELEASE}-${DEB_RELEASE}.${DEBIAN_VERSION}" 'Update distribution'

    if [ ${DEBIAN_VERSION} != trusty -a ${DEBIAN_VERSION} != xenial -a ${DEBIAN_VERSION} != jessie -a ${DEBIAN_VERSION} != stretch -a ${DEBIAN_VERSION} != artful -a ${DEBIAN_VERSION} != bionic -a ${DEBIAN_VERSION} != focal -a "${DEBIAN_VERSION}" != disco -a "${DEBIAN_VERSION}" != buster ]; then
        gcc47=$(which gcc-4.7 2>/dev/null || true)
        if [ -x "${gcc47}" ]; then
            export CC=gcc-4.7
            export USE_THIS_GCC_VERSION="-4.7"
            export CXX=g++-4.7
        else
            export CC=gcc-4.8
            export USE_THIS_GCC_VERSION="-4.8"
            export CXX=g++-4.8
        fi
    fi

    if [ ${DEBIAN_VERSION} = "xenial" ]; then
        sed -i 's/export CFLAGS=/export CFLAGS=-Wno-error=date-time /' debian/rules
        sed -i 's/export CXXFLAGS=/export CXXFLAGS=-Wno-error=date-time /' debian/rules
    fi

    if [ ${DEBIAN_VERSION} = "stretch" -o ${DEBIAN_VERSION} = "bionic" -o ${DEBIAN_VERSION} = "focal" -o ${DEBIAN_VERSION} = "buster" -o ${DEBIAN_VERSION} = "disco" ]; then
        sed -i 's/export CFLAGS=/export CFLAGS=-Wno-error=deprecated-declarations -Wno-error=unused-function -Wno-error=unused-variable -Wno-error=unused-parameter -Wno-error=date-time /' debian/rules
        sed -i 's/export CXXFLAGS=/export CXXFLAGS=-Wno-error=deprecated-declarations -Wno-error=unused-function -Wno-error=unused-variable -Wno-error=unused-parameter -Wno-error=date-time /' debian/rules
    fi
    if [ ${DEBIAN_VERSION} = "cosmic" ]; then
        sed -i 's/export CFLAGS=/export CFLAGS=-Wno-error=deprecated-declarations -Wno-error=unused-function -Wno-error=unused-variable -Wno-error=unused-parameter -Wno-error=date-time -Wno-error=ignored-qualifiers -Wno-error=class-memaccess -Wno-error=shadow /' debian/rules
        sed -i 's/export CXXFLAGS=/export CXXFLAGS=-Wno-error=deprecated-declarations -Wno-error=unused-function -Wno-error=unused-variable -Wno-error=unused-parameter -Wno-error=date-time -Wno-error=ignored-qualifiers -Wno-error=class-memaccess -Wno-error=shadow /' debian/rules
    fi
    dpkg-buildpackage -rfakeroot -uc -us -b

    cd ${WORKDIR}
    mkdir -p $CURDIR/deb
    mkdir -p $WORKDIR/deb
    cp $WORKDIR/*.deb $WORKDIR/deb
    cp $WORKDIR/*.deb $CURDIR/deb
}

build_tarball(){
    if [ $TARBALL = 0 ]
    then
        echo "Binary tarball will not be created"
        return;
    fi
    #get_tar "source_tarball"
    SOURCEDIR="$(cd $(dirname "$0"); cd ..; pwd)"
    cd $WORKDIR
    #TARFILE=$(basename $(find . -name 'greatsql-*.tar.gz' | sort | tail -n1))
    if [ -f /etc/debian_version ]; then
      export OS_RELEASE="$(lsb_release -sc)"
    fi
    #
    if [ -f /etc/redhat-release ]; then
      export OS_RELEASE="centos$(lsb_release -sr | awk -F'.' '{print $1}')"
      export RHEL=$(rpm --eval %rhel)
      if [ "${RHEL}" -lt 7 ]; then
          source /opt/rh/devtoolset-11/enable
      else
          if [ -e /opt/rh/devtoolset-11/enable ]; then
              if [ "x${ARCH}" = "xaarch64" ]; then
                  # no devtoolset-11-gcc/g++ on aarch64 for now
                  source /opt/rh/devtoolset-10/enable
              else
                  source /opt/rh/devtoolset-11/enable
              fi
        else
              source /opt/rh/gcc-toolset-11/enable
        fi
      fi
    fi

#if [ -f /etc/redhat-release ]; then
#     export OS_RELEASE="centos$(lsb_release -sr | awk -F'.' '{print $1}')"
#     RHEL=$(rpm --eval %rhel)
#     if [ "${RHEL}" -lt 7 ]; then
#         source /opt/rh/devtoolset-11/enable
#     elif [ "${RHEL}" -lt 8 ]; then
#         source /opt/rh/devtoolset-10/enable
#     elif [ -f "/opt/rh/gcc-toolset-10/enable" ]; then
#         source /opt/rh/gcc-toolset-10/enable
#     fi
#   fi
    #

    ARCH=$(uname -m 2>/dev/null||true)
    #TARFILE=$(basename $(find . -name 'greatsql-*.tar.gz' | sort | grep -v "tools" | tail -n1))
    #NAME=$(echo ${TARFILE}| awk -F '-' '{print $1"-"$2}')
    #VERSION=$(echo ${TARFILE}| awk -F '-' '{print $3}')
    #
    #SHORTVER=$(echo ${VERSION} | awk -F '.' '{print $1"."$2}')
    #TMPREL=$(echo ${TARFILE}| awk -F '-' '{print $4}')
    #RELEASE=${TMPREL%.tar.gz}
    #
    if [ -f /etc/redhat-release ]; then
      RHEL=$(rpm --eval %rhel)
      if [ "${RHEL}" -lt 8 ]; then
        export CFLAGS=$(rpm --eval %{optflags} | sed -e "s|march=i386|march=i686|g")
        export CXXFLAGS="${CFLAGS}"
      elif [ ${ARCH} = aarch64 ]; then
        echo # do nothing
      else
        export CFLAGS=$(rpm --eval %{optflags} | sed -e "s|march=i386|march=i686|g")
        export CXXFLAGS="${CFLAGS}"
      fi
    fi

    build_mecab_lib
    build_mecab_dict
    MECAB_INSTALL_DIR="${WORKDIR}/mecab-install"
    rm -fr TARGET && mkdir TARGET
    rm -rf jemalloc
    if [ ${ARCH} = aarch64 ]; then
        JEMALLOC_DIR=""
    else
        JEMALLOC_DIR="${WORKDIR}/jemalloc"
        git clone https://gitee.com/mirrors/jemalloc.git
        (
        cd jemalloc
        git checkout 3.6.0
        bash autogen.sh
        )
    fi

    if [ "x$WITH_SSL_GM" = "x1" ]; then
      echo "build and install custom openssl for gmssl"
      (
        if [ ! -d openssl ]; then
          git clone https://gitee.com/babassl/Tongsuo.git openssl
          cd openssl
          git checkout 8.3.2
          ./config enable-ntls --prefix=${WORKDIR}/ssl/
          make -j10
          make install
       else
          cd openssl
          make -j10 install
       fi
      )
    else
      mkdir -p ${WORKDIR}/ssl/lib
      mkdir -p ${WORKDIR}/ssl/include
      if [ "x$OS" = "xdeb" ]; then
          cp -av /usr/lib/x86_64-linux-gnu/libssl* ${WORKDIR}/ssl/lib
	        cp -av /usr/lib/x86_64-linux-gnu/libcrypto* ${WORKDIR}/ssl/lib
          cp -av /usr/include/openssl ${WORKDIR}/ssl/include/
      else
          cp -av /usr/lib*/libssl.so* ${WORKDIR}/ssl/lib
	        cp -av /usr/lib*/libcrypto* ${WORKDIR}/ssl/lib
          cp -av /usr/include/openssl ${WORKDIR}/ssl/include/
      fi
    fi

    BUILD_OPT=""
    if [ $WITH_DEBUG = 1 ]; then
      BUILD_OPT="--debug"
    fi

    export LD_LIBRARY_PATH=${WORKDIR}/ssl/lib:$LD_LIBRARY_PATH
    if [ "x$WITH_SSL" = "x1" ]; then
        CMAKE_OPTS="-DWITH_ROCKSDB=0 -DGROUP_REPLICATION_WITH_ROCKSDB=OFF -DALLOW_NO_SSE42=ON -DINSTALL_LAYOUT=STANDALONE -DWITH_AUTHENTICATION_LDAP=OFF -DWITH_SSL=${WORKDIR}/ssl " bash -xe ${SOURCEDIR}/build-gs/build-binary.sh --with-mecab="${MECAB_INSTALL_DIR}/usr" --with-jemalloc="${JEMALLOC_DIR}" --with-no-git=$NO_GIT_INFO --local-boost=$LOCAL_BOOST ${BUILD_OPT} ${EXTRA_BUILD_OPTION} TARGET
        DIRNAME="yassl"
    else
        CMAKE_OPTS="-DWITH_ROCKSDB=0 -DGROUP_REPLICATION_WITH_ROCKSDB=OFF -DALLOW_NO_SSE42=ON -DWITH_AUTHENTICATION_LDAP=OFF" bash -xe ${SOURCEDIR}/build-gs/build-binary.sh --with-mecab="${MECAB_INSTALL_DIR}/usr" --with-jemalloc="${JEMALLOC_DIR}" --with-no-git=$NO_GIT_INFO --local-boost=$LOCAL_BOOST ${BUILD_OPT} ${EXTRA_BUILD_OPTION} TARGET
        DIRNAME="tarball"
    fi
    mkdir -p ${WORKDIR}/${DIRNAME}
    #cp TARGET/*.tar.gz ${WORKDIR}/${DIRNAME}
    cp TARGET/*.tar.xz ${WORKDIR}/${DIRNAME}
    cd ${WORKDIR}/${DIRNAME}
    #for file in `ls *.tar.gz`
    for file in `ls *.tar.xz`
    do
      filename=`find . -name $file | tail -n 1`
      echo $filename
      md5sum $filename | awk '{print $1}' > $filename.md5
    done
    cd ../../
}

#main

CURDIR=$(pwd)
VERSION_FILE=$CURD/..//percona-server-8.0.properties
args=
WORKDIR=
SRPM=0
SDEB=0
RPM=0
DEB=0
SOURCE=0
TARBALL=0
WITH_SSL=0
WITH_SSL_GM=0
WITH_DEBUG=0
NO_GIT_INFO=0
LOCAL_BOOST=0
OS_NAME=
ARCH=
OS=
TOKUBACKUP_REPO=
PERCONAFT_REPO=
INSTALL=0
RPM_RELEASE=1
DEB_RELEASE=1
REVISION=0
BRANCH="8.0"
RPM_RELEASE=1
DEB_RELEASE=1
EXTRA_BUILD_OPTION=
MECAB_INSTALL_DIR="${WORKDIR}/mecab-install"
REPO="git://github.com/percona/percona-server.git"
PRODUCT=Percona-Server-8.0
MYSQL_VERSION_MAJOR=8
MYSQL_VERSION_MINOR=0
MYSQL_VERSION_PATCH=12
MYSQL_VERSION_EXTRA=-1
PRODUCT_FULL=Percona-Server-8.0.32.1
BOOST_PACKAGE_NAME=boost_1_77_0
PERCONAFT_BRANCH=Percona-Server-5.7.22-22
TOKUBACKUP_BRANCH=Percona-Server-5.7.22-22
parse_arguments PICK-ARGS-FROM-ARGV "$@"

check_workdir
get_system
install_deps
get_sources

if [ "x$WITH_SSL_GM" = "x1" ]; then
  EXTRA_BUILD_OPTION="${EXTRA_BUILD_OPTION:-} --with-ssl-gm"
fi

build_tarball
build_srpm
build_source_deb
build_rpm
build_deb
