#!/usr/bin/env bash
set -e
set -u

function ip_for(){
    server=$1
    ip=$($NOVA show ${server} | sed -En "/public network/ s/^.* ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}).*$/\1/p")
    if [[ ${ip} =~ "." ]]; then
        echo ${ip}
    else
        echo ""
    fi
}

function get_image_type(){
    case $1 in
        "ubuntu")
            IMAGE_TYPE="12.04 LTS"
            ;;
        "redhat")
            IMAGE_TYPE="Red Hat Enterprise Linux 6.1"
            ;;
        "centos")
            IMAGE_TYPE="CentOS 6.3"
            ;;
        "fedora")
            IMAGE_TYPE="Fedora 17"
            ;;
        *)
            echo "Invalid OS specified"
            echo "Only available options are ubuntu, centos, redhat & fedora"
            exit 1
            ;;
    esac
}

function boot_instance(){
   server_name=$1
   imagelist=$($NOVA image-list)
   flavorlist=$($NOVA flavor-list)

   image=$(echo "${imagelist}" | grep "${IMAGE_TYPE}" | head -n1 | awk '{ print $2 }')
   flavor=$(echo "${flavorlist}" | grep "${FLAVOR_TYPE}" | head -n1 | awk '{ print $2 }')

   if [[ -f ${key_location} ]]; then
       if ! ( $NOVA list | grep -q " ${server_name} " ); then
           $NOVA boot --flavor=${flavor} --image ${image} ${network_string} --file /root/.ssh/authorized_keys=${key_location} ${server_name} > /dev/null 2>&1
       else
           echo "Server name ${server_name} already exists"
           exit 1
        fi
   else
       echo "Please setup your specified key ${key_location} file for key injection to cloud servers "
       exit 1
   fi
}

function get_network(){
   if ( $NOVA network-list | grep -q ${NET_ID}-net ); then
       priv_network_id=$($NOVA network-list | grep ${NET_ID}-net | awk '{print $2}')
       network_string="--nic net-id=${priv_network_id} ${network_string}"
   fi
}

function client_setup(){
   server=$1
   ip=$(ip_for $server)

   #ssh ${SSHOPTS} root@$ip "true && curl -L https://www.opscode.com/chef/install.sh | bash"
   #ssh ${SSHOPTS} root@$ip "mkdir -p /etc/chef"

   #scp ${SSHOPTS} ~/validation.pem root@$ip:/etc/chef/validation.pem
   #scp ${SSHOPTS} ~/client.rb root@$ip:/etc/chef/client.rb

   knife bootstrap $ip -d chef-full --sudo
}

function wait_for_ip(){
   server=$1
   count=0
   max_count=20

   echo "Waiting for IPv4 on ${server}"

   while ! ( $NOVA list | grep ${server} | grep -q "ERROR" ); do
       ip=$(ip_for ${server});
       if [ "${ip}" == "" ]; then
           sleep 20
           count=$(( count + 1 ))
           if [ ${count} -gt ${max_count} ]; then
               echo "Aborting... too slow"
               exit 1
           fi
       else
           echo "Got IPv4: ${ip} for server: ${server}"
           break
       fi
   done

   if ( $NOVA list | grep ${server} | grep -q "ERROR" ); then
       echo "${server} in ERROR state, build failed"
       exit 1
   fi
}

function wait_for_server(){
   server=$1
   count=0
   max_ping=60
   max_count=18

   wait_for_ip ${server}

   ip=$(ip_for ${server})

   echo "Waiting for ping on ${ip}"
   count=0
   while ( ! ping -c1 ${ip} > /dev/null 2>&1 ); do
       count=$(( count + 1 ))
       if [ ${count} -gt ${max_ping} ]; then
           echo "timeout waiting for ping"
           exit 1
       fi
       sleep 10
   done

   echo "SSH ready - waiting for valid login"
   count=0

   while ( ! ssh ${SSHOPTS} root@${ip} id | grep -q "root" ); do
       count=$(( count + 1 ))
       if [ ${count} -gt ${max_count} ]; then
           echo "timeout waiting for login"
           exit 1
       fi
       sleep 10
   done
   echo "Login Successful"
}

function steal_swap_for_swift_cinder(){
    server=$1
    ip=$(ip_for $server)

    ssh $SSHOPTS root@${ip} modprobe dummy || true
    ssh $SSHOPTS root@${ip} ifconfig dummy0 up || true
    ssh $SSHOPTS root@${ip} 'sed -i "/xvdc1/d" /etc/fstab; swapoff /dev/xvdc1; fdisk /dev/xvdc << EOF
d
w
EOF' || true
}

function credentials_check(){
   #only need to source nova env if not using supernova
   if [[ "$NOVA" == "nova" ]]; then
       if [[ -f ${HOME}/csrc ]]; then
           source ${HOME}/csrc
       elif [[ -n $OS_USERNAME ]] && [[ -n $OS_TENANT_NAME ]] && [[ -n $OS_AUTH_URL ]] && [[ -n $OS_PASSWORD ]]; then
           echo "env variables already set"
       else
           echo "Please setup your cloud credentials file in ${HOME}/csrc"
           exit 1
       fi
   fi
}

function check_network(){
    if ( $NOVA network-list | grep -q " ${network_value} " ); then
        priv_network_id=$($NOVA network-list | grep ${network_value} | awk '{print $2}')
        network_string="--nic net-id=${priv_network_id} ${network_string}"
    else
        echo "Invalid Network specified"
        usage
        exit 1
    fi
}

function clientrun(){
    server=$1
    ip=$(ip_for $server)
    if [ ${OS} = "redhat" ]; then
        ssh ${SSHOPTS} root@$ip "sed -i -e '/Defaults.*requiretty/s/^/#/g' /etc/sudoers"
    fi
    ssh ${SSHOPTS} root@$ip "chef-client"
}

function clientdelete(){
    server=$1
    nova_uuid=""
    knife node delete -y $server
    knife client delete -y $server
    echo "Deleting ${server}"
    uuid=$($NOVA list | grep ${server} | awk '{print $2}' | head -1)
    $NOVA delete ${uuid}
}

function reindex_server(){
    server=$1
    ip=$(ip_for $server)
    ssh ${SSHOPTS} root@$ip "chef-server-ctl reindex"
}

function upload_cookbooks(){
    cookbook_path=$1
    knife cookbook upload -a -o $1
}

function download_cookbooks(){
    download_path=$1
    git clone --recursive -b sprint http://github.com/rcbops/chef-cookbooks $1
}

function usage(){
cat <<EOF
usage: $0 options

This script will install integrated Chef Client instances on the Rackspace Cloud.

OPTIONS:
  -h --help  Show this message
  -v --verbose  Verbose output
  -V --version  Output the version of this script

ARGUMENTS:
  -c= --client-name=<Client Name>
         Name for the instance to be spun up
  -s= --server=<Server Name>
         Specify the name of the Chef Server - default "chef-server"
         Used with re-index
  -n= --network=<Existing network name>|<Existing network uuid>
         Setup a private cloud networks, will require "nova network-create" command
         You can specify an existing network name or network uuid
  -p= --public-key=[location of key file]
         Specify the location of the key file to inject onto the cloud servers
  -r --run
         Chef-client run on specified server
  -d --delete
         Delete node
  -o= --os=[redhat | centos | ubuntu | fedora ]
         Specify the OS to install on the server - default ubuntu
  -f= --flavor=<Specify Flavor>
         Specify the flavor of the instance, by size - default "4GB"
  -sc= --server-count=<Number of servers>
         Will create specified number of servers named <client name><number>
  -ri --reindex
         Run a re-index on the chef-server specified by "-s"
  -u= --upload=<Path to cookbooks>
         Upload cookbooks in specified Path
         Defaults to $PWD/cookbooks
  -dl= --download=<Path to download>
         Download cookbooks from the rcbops repo and upload them
         Defaults to $PWD
EOF
}

function display_version() {
cat <<EOF
$0 (version: $VERSION)
EOF
}

####################
# Global Variables #
NOVA=${NOVA:-nova}
VERSION=1.0.0
if [ -L $0 ]; then
    BASEDIR=$(dirname $(readlink $0))
else
    BASEDIR=$(dirname $0)
fi
####################

####################
#  Flag Variables  #
NET_ID="chef-net"
IMAGE_TYPE=${IMAGE_TYPE:-"12.04 LTS"}
OS="ubuntu"
FLAVOR_TYPE=${FLAVOR_TYPE:-"4GB"}
INST_NAME="chef-client"
chef_server="chef-server"
new_server=true
client_run=false
client_delete=false
reindex=false
upload=false
download=false
server_count=1
download_location="$PWD/chef-cookbooks"
cookbook_location="${PWD}/cookbooks"
####################

####################
#  Check ENV Vars  #
OS_AUTH_URL=${OS_AUTH_URL:-}
OS_TENANT_NAME=${OS_TENANT_NAME:-}
OS_USERNAME=${OS_USERNAME:-}
OS_PASSWORD=${OS_PASSWORD:-}
####################

####################
# Boot String Vars #
network_string="--nic net-id=00000000-0000-0000-0000-000000000000"
network_value="chef_net"
verbose_string=""
key_location=${HOME}/.ssh/authorized_keys
SSHOPTS="-q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
####################

for arg in $@; do
    flag=$(echo $arg | cut -d "=" -f1)
    value=$(echo $arg | cut -d "=" -f2)
    case $flag in
        "--client" | "-c")
            if [ "$value" != "--client" ] && [ "$value" != "-c" ]; then
                INST_NAME=$value
            else
                echo "Please Specify client name"
                usage
                exit 1
            fi
            ;;
        "--server" | "-s")
            if [ "$value" != "--server" ] && [ "$value" != "-s" ]; then
                chef_server=$value
            else
                echo "Please specify chef-server name"
                usage
                exit 1
            fi
            ;;
        "--run" | "-r")
            new_server=false
            client_run=true
            ;;
        "--network" | "-n")
            network_value=$value
            ;;
        "--public-key" | "-p")
            if [ "$value" != "--public-key" ] && [ "$value" != "-p" ]; then
                if [ ${value:0:1} == "/" ]; then
                    key_location=$value
                elif [ ${value:0:1} == "~" ]; then
                    key_location="$HOME""${value:1}"
                else
                    key_location="$PWD""/""$value"
                fi
            fi
            ;;
        "--delete" | "-d")
            new_server=false
            client_delete=true
            ;;
        "--os" | "-o")
            value=$(echo $value | tr "[:upper:]" "[:lower:]")
            OS=$value
            get_image_type $value
            ;;
        "--flavor" | "-f")
            if [ "$value" != "--flavor" ] && [ "$value" != "-f" ]; then
                FLAVOR_TYPE=$value
            else
                echo "Please specify legitimate flavor size"
                exit 1
            fi
            ;;
        "--server-count" | "-sc")
            if [ $value -eq $value 2>/dev/null ]; then
                server_count=$value
            else
                usage
                exit 1
            fi
            ;;
        "--reindex" | "-ri")
            reindex=true
            new_server=false
            ;;
        "--upload" | "-u")
            new_server=false
            upload=true
            if [ "$value" != "--upload" ] && [ "$value" != "-u" ]; then
                if [ ${value:0:1} == "/" ]; then
                    cookbook_location=$value
                elif [ ${value:0:1} == "~" ]; then
                    cookbook_location="$HOME""${value:1}"
                else
                    cookbook_location="$PWD""/""$value"
                fi
            fi
            ;;
        "--download" | "-dl")
            download=true
            new_server=false
            if [ "$value" != "--download" ] && [ "$value" != "-d" ]; then
                if [ ${value:0:1} == "/" ]; then
                    download_location=$value
                elif [ ${value:0:1} == "~" ]; then
                    download_location="$HOME""${value:1}"
                else
                    download_location="$PWD""/""$value"
                fi
                download_location="$download_location/chef-cookbooks"
            fi
            ;;
        "--help" | "-h")
            usage
            exit 0
            ;;
        "--verbose" | "-v")
            VERBOSE=1
            verbose_string="-v"
            set -x
            ;;
        "--version" | "-V")
            display_version
            exit 0
            ;;
        *)
            echo "Invalid option $flag"
            usage
            exit 1
            ;;
    esac
done

credentials_check

if ( $new_server ); then
    check_network
    for client in $(seq 1 $server_count); do
        TEMP_NAME=$INST_NAME$client
        boot_instance $TEMP_NAME
    done
    for client in $(seq 1 $server_count); do
        TEMP_NAME=$INST_NAME$client
        wait_for_server $TEMP_NAME
        steal_swap_for_swift_cinder $TEMP_NAME
        client_setup $TEMP_NAME
    done
elif ( $client_run ); then
    clientrun $INST_NAME
elif ( $client_delete ); then
    clientdelete $INST_NAME
elif ( $reindex ); then
    reindex_server $chef_server
elif ( $upload ); then
    upload_cookbooks $cookbook_location
elif ( $download ); then
    download_cookbooks $download_location
    upload_cookbooks "$download_location/cookbooks/"
fi
exit
