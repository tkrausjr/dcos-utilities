#!/bin/bash
#
# BASH script to install DCOS on a node
#
# Usage:
#
#   dcos_install.sh <role>...
#
#
# Metadata:
#   dcos image commit: 934037ba2ca3347dab3965d3aff1c75c145b49a3
#   generation date: 2016-01-06 22:03:10.576361
#
# TODO(cmaloney): Copyright + License string here

set -o errexit -o nounset -o pipefail

declare -i OVERALL_RC=0
declare -i PREFLIGHT_ONLY=0
declare -i DISABLE_PREFLIGHT=0

declare ROLES=""
declare RED=""
declare BOLD=""
declare NORMAL=""

# Check if this is a terminal, and if colors are supported, set some basic
# colors for outputs
if [ -t 1 ]; then
    colors_supported=$(tput colors)
    if [[ $colors_supported -ge 8 ]]; then
        RED='\e[1;31m'
        BOLD='\e[1m'
        NORMAL='\e[0m'
    fi
fi

# Setup getopt argument parser
ARGS=$(getopt -o dph --long "disable-preflight,preflight-only,help" -n "$(basename "$0")" -- "$@")

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

function setup_directories() {
    echo -e "Creating directories under /etc/mesosphere"
    mkdir -p /etc/mesosphere/roles
    mkdir -p /etc/mesosphere/setup-flags
}

function setup_dcos_roles() {
    # Set DCOS roles
    for role in $ROLES
    do
        echo "Creating role file for ${role}"
        touch "/etc/mesosphere/roles/$role"
    done
}

# Set DCOS machine configuration
function configure_dcos() {
echo -e 'Configuring DCOS'
mkdir -p `dirname /etc/mesosphere/setup-flags/repository-url`
cat <<'EOF' > "/etc/mesosphere/setup-flags/repository-url"
http://192.168.100.234>

EOF
chmod 644 /etc/mesosphere/setup-flags/repository-url

mkdir -p `dirname /etc/mesosphere/setup-flags/bootstrap-id`
cat <<'EOF' > "/etc/mesosphere/setup-flags/bootstrap-id"
BOOTSTRAP_ID=299269a7aa9e23a1edc94de3f2375356b2942af8

EOF
chmod 644 /etc/mesosphere/setup-flags/bootstrap-id

mkdir -p `dirname /etc/mesosphere/setup-flags/cluster-packages.json`
cat <<'EOF' > "/etc/mesosphere/setup-flags/cluster-packages.json"
["dcos-config--setup_4ad1518260d1aeaabbe3246729a54533c849a95b", "dcos-detect-ip--setup_4ad1518260d1aeaabbe3246729a54533c849a95b", "dcos-metadata--setup_4ad1518260d1aeaabbe3246729a54533c849a95b", "onprem-config--setup_4ad1518260d1aeaabbe3246729a54533c849a95b"]
EOF
chmod 644 /etc/mesosphere/setup-flags/cluster-packages.json


}

# Install the DCOS services, start DCOS
function setup_and_start_services() {
echo -e 'Setting and starting DCOS'
mkdir -p `dirname /etc/systemd/system/dcos-link-env.service`
cat <<'EOF' > "/etc/systemd/system/dcos-link-env.service"
[Unit]
Before=dcos.target
[Service]
Type=oneshot
StandardOutput=journal+console
StandardError=journal+console
ExecStartPre=/usr/bin/mkdir -p /etc/profile.d
ExecStart=/usr/bin/ln -sf /opt/mesosphere/environment.export /etc/profile.d/dcos.sh

EOF
chmod 644 /etc/systemd/system/dcos-link-env.service

mkdir -p `dirname /etc/systemd/system/dcos-download.service`
cat <<'EOF' > "/etc/systemd/system/dcos-download.service"
[Unit]
Description=Download the DCOS
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/opt/mesosphere/
[Service]
EnvironmentFile=/etc/mesosphere/setup-flags/bootstrap-id
Type=oneshot
StandardOutput=journal+console
StandardError=journal+console
ExecStartPre=/usr/bin/curl --fail --retry 20 --continue-at - --location --silent --show-error --verbose --output /tmp/bootstrap.tar.xz http://192.168.100.234>/bootstrap/${BOOTSTRAP_ID}.bootstrap.tar.xz
ExecStartPre=/usr/bin/mkdir -p /opt/mesosphere
ExecStart=/usr/bin/tar -axf /tmp/bootstrap.tar.xz -C /opt/mesosphere
ExecStartPost=-/usr/bin/rm -f /tmp/bootstrap.tar.xz

EOF
chmod 644 /etc/systemd/system/dcos-download.service

mkdir -p `dirname /etc/systemd/system/dcos-setup.service`
cat <<'EOF' > "/etc/systemd/system/dcos-setup.service"
[Unit]
Description=Prep the Pkgpanda working directories for this host.
Requires=dcos-download.service
After=dcos-download.service
[Service]
Type=oneshot
StandardOutput=journal+console
StandardError=journal+console
EnvironmentFile=/opt/mesosphere/environment
ExecStart=/opt/mesosphere/bin/pkgpanda setup --no-block-systemd
[Install]
WantedBy=multi-user.target
EOF
chmod 644 /etc/systemd/system/dcos-setup.service


systemctl start dcos-link-env
systemctl enable dcos-setup
systemctl start dcos-setup

}

set +e

declare -i DISABLE_VERSION_CHECK=0

# check if sort -V works
function check_sort_capability() {
    $( echo '1' | sort -V >/dev/null 2>&1 || exit 1 )
    RC=$?
    if [[ "$RC" -eq "2" ]]; then
        echo -e "${RED}Disabling version checking as sort -V is not available${NORMAL}"
        DISABLE_VERSION_CHECK=1
    fi
}

function version_gt() {
    # sort -V does version-aware sort
    HIGHEST_VERSION="$(echo "$@" | tr " " "
" | sort -V | tail -n 1)"
    test $HIGHEST_VERSION == "$1"
}

function print_status() {
    CODE_TO_TEST=$1
    EXTRA_TEXT=${2:-}
    if [[ $CODE_TO_TEST == 0 ]]; then
        echo -e "${BOLD}PASS $EXTRA_TEXT${NORMAL}"
    else
        echo -e "${RED}FAIL $EXTRA_TEXT${NORMAL}"
    fi
}

function check_command_exists() {
    COMMAND=$1
    DISPLAY_NAME=${2:-$COMMAND}

    echo -e -n "Checking if $DISPLAY_NAME is installed and in PATH: "
    $( command -v $COMMAND >/dev/null 2>&1 || exit 1 )
    RC=$?
    print_status $RC
    (( OVERALL_RC += $RC ))
    return $RC
}

function check_version() {
    COMMAND_NAME=$1
    VERSION_ATLEAST=$2
    COMMAND_VERSION=$3
    DISPLAY_NAME=${4:-$COMMAND}

    echo -e -n "Checking $DISPLAY_NAME version requirement (>= $VERSION_ATLEAST): "
    version_gt $COMMAND_VERSION $VERSION_ATLEAST
    RC=$?
    print_status $RC "${NORMAL}($COMMAND_VERSION)"
    (( OVERALL_RC += $RC ))
    return $RC
}

function check() {
    # Wrapper to invoke both check_commmand and version check in one go
    if [[ $# -eq 4 ]]; then
       DISPLAY_NAME=$4
    elif [[ $# -eq 2 ]]; then
       DISPLAY_NAME=$2
    else
       DISPLAY_NAME=$1
    fi
    check_command_exists $1 $DISPLAY_NAME
    # check_version takes {3,4} arguments
    if [[ "$#" -ge 3 && $DISABLE_VERSION_CHECK -eq 0 ]]; then
        check_version $*
    fi
}

function check_service() {
  PORT=$1
  NAME=$2
  echo -e -n "Checking if port $PORT (required by $NAME) is in use: "
  RC=0
  cat /proc/net/{udp*,tcp*} | cut -d: -f3 | cut -d' ' -f1 | grep -q $(printf "%04x" $PORT) && RC=1
  print_status $RC
  (( OVERALL_RC += $RC ))
}

function check_preexisting_dcos() {
    echo -e -n 'Checking if DCOS is already installed: '
    if [[ ( -d /etc/systemd/system/dcos.target ) ||        ( -d /etc/systemd/system/dcos.target.wants ) ||        ( -d /opt/mesosphere ) ]]; then
        # this will print: Checking if DCOS is already installed: FAIL (Currently installed)
        print_status 1 "${NORMAL}(Currently installed)"
        echo
        cat <<EOM
Found an existing DCOS installation. To reinstall DCOS on this this machine you must
first uninstall DCOS then run dcos_install.sh. To uninstall DCOS, follow the product
documentation provided with DCOS.
EOM
        echo
        exit 1
    else
        print_status 0 "${NORMAL}(Not installed)"
    fi
}

function check_all() {
    # Disable errexit because we want the preflight checks to run all the way
    # through and not bail in the middle, which will happen as it relies on
    # error exit codes
    set +e
    echo -e "${BOLD}Running preflight checks${NORMAL}"

    check_preexisting_dcos

    check_sort_capability

    local docker_version=$(docker version 2>/dev/null | awk '
        BEGIN {
            version = 0
            client_version = 0
            server_version = 0
        }
        {
            if($1 == "Server:") {
                server = 1
                client = 0
            } else if($1 == "Client:") {
                server = 0
                client = 1
            } else if ($1 == "Server" && $2 == "version:") {
                server_version = $3
            } else if ($1 == "Client" && $2 == "version:") {
                client_version = $3
            }
            if(server && $1 == "Version:") {
                server_version = $2
            } else if(client && $1 == "Version:") {
                client_version = $2
            }
        }
        END {
            if(client_version == server_version) {
                version = client_version
            } else {
                split(client_version, cv, ".")
                split(server_version, sv, ".")

                y = length(cv) > length(sv) ? length(cv) : length(sv)

                for(i = 1; i <= y; i++) {
                    if(cv[i] < sv[i]) {
                        version = client_version
                        break
                    } else if(sv[i] < cv[i]) {
                        version = server_version
                        break
                    }
                }
            }
            print version
        }
    ')
    # CoreOS stable as of Aug 2015 has 1.6.2
    check docker 1.6 "$docker_version"

    check curl
    check bash
    check ping
    check tar
    check xz
    check unzip

    # $ systemctl --version ->
    # systemd nnn
    # compiler option string
    # Pick up just the first line of output and get the version from it
    check systemctl 200 $(systemctl --version | head -1 | cut -f2 -d' ') systemd

    echo -e -n "Checking if group 'nogroup' exists: "
    getent group nogroup > /dev/null
    RC=$?
    print_status $RC
    (( OVERALL_RC += $RC ))

    for service in       "80 mesos-ui"       "53 mesos-dns"       "15055 dcos-history"       "5050 mesos-master"       "2181 zookeeper"       "8080 marathon"       "3888 zookeeper"       "8181 exhibitor"       "8123 mesos-dns"
    do
      check_service $service
    done

    for role in "$ROLES"
    do
        if [ "$role" != "master" -a "$role" != "slave" -a "$role" != "slave_public" ]; then
            echo -e "${RED}FAIL Invalid role $role. Role must be one of {master,slave,slave_public}{NORMAL}"
            (( OVERALL_RC += 1 ))
        fi
    done


    return $OVERALL_RC
}

function dcos_install()
{
    # Enable errexit
    set -e

    setup_directories
    setup_dcos_roles
    configure_dcos
    setup_and_start_services

}

function usage()
{
    echo -e "${BOLD}Usage: $0 [--disable-preflight|--preflight-only] <roles>${NORMAL}"
}

function main()
{
    eval set -- "$ARGS"

    while true ; do
        case "$1" in
            -d|--disable-preflight) DISABLE_PREFLIGHT=1;  shift  ;;
            -p|--preflight-only) PREFLIGHT_ONLY=1 ; shift  ;;
            -h|--help) usage; exit 1 ;;
            --) shift ; break ;;
            *) usage ; exit 1 ;;
        esac
    done

    if [[ $DISABLE_PREFLIGHT -eq 1 && $PREFLIGHT_ONLY -eq 1 ]]; then
        echo -e 'Both --disable-preflight and --preflight-only can not be specified'
        usage
        exit 1
    fi

    shift $(($OPTIND - 1))
    ROLES=$@

    if [[ $PREFLIGHT_ONLY -eq 1 ]] ; then
        check_all
    else
        if [[ -z $ROLES ]] ; then
            echo -e 'Atleast one role name must be specified'
            usage
            exit 1
        fi
        echo -e "${BOLD}Starting DCOS Install Process${NORMAL}"
        if [[ $DISABLE_PREFLIGHT -eq 0 ]] ; then
            check_all
            RC=$?
            if [[ $RC -ne 0 ]]; then
                echo 'Preflight checks failed. Exiting installation. Please consult product documentation'
                exit $RC
            fi
        fi
        # Run actual install
        dcos_install
    fi

}

# Run it all
main
