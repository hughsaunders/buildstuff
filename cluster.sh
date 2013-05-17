boot(){
    ./magnet.sh -s=chefserver.uk.rs.wherenow.org\
        -n=osprivate\
        -p=~/.ssh/id_rsa.pub\
        -f=4\
        -sc=6\
        -c=grizzlyupgrade\
        -e=grizzlyupgrade
}


client_run(){
    node="$1"
    echo -e "\n\n============== Running Chef on $node =============\n\n"
    
    ip=$(supernova uk show $node |awk '/accessIPv4/{print $4}')
    ssh root@$ip 'sed -i "/chefserver/d" /etc/hosts; echo "162.13.5.179 chefserver" >> /etc/hosts; chef-client'
}

addroles(){
    knife node run_list add grizzlyupgrade1 'role[ha-controller1], role[graphite], role[collectd-server]'
    knife node run_list add grizzlyupgrade2 'role[ha-controller2], role[collectd-client]'
    knife node run_list add grizzlyupgrade3 'role[single-compute], role[cinder-volume], role[collectd-client]'
    knife node run_list add grizzlyupgrade4 'role[swift-setup], role[swift-management-server], role[swift-proxy-server], role[swift-account-server], role[swift-container-server], role[swift-object-server], role[collectd-client]'
    knife node run_list add grizzlyupgrade5 'role[swift-account-server], role[swift-container-server], role[swift-object-server], role[collectd-client]'
    knife node run_list add grizzlyupgrade6 'role[swift-account-server], role[swift-container-server], role[swift-object-server], role[collectd-client]'
}

run(){
    #HA controllers and nova
    client_run grizzlyupgrade1 && \
    client_run grizzlyupgrade2 && \
    client_run grizzlyupgrade3 && \

    #swift
    client_run grizzlyupgrade4 && \
    client_run grizzlyupgrade5 && \
    client_run grizzlyupgrade6 && \

    client_run grizzlyupgrade4 && \
    client_run grizzlyupgrade5 && \
    client_run grizzlyupgrade6
}

del ()
{
    [ -z "$1" ] && return
    $NOVA list | awk -F \| '/'$1'/{print $2}' | while read id; do
        echo "deleting instance $id";
        supernova uk delete $id;
    done;
    knife node list | grep $1 | while read node; do
        knife node delete $node -y || :;
    done
    knife client list | grep $1 | while read node; do
        knife client delete $node -y || :;
    done
}

clear(){
    del grizzlyupgrade
}

for cmd in $@; do
    eval $cmd
done
