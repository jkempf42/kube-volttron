#! /bin/bash

set -x

# Create /run/cni if not there, or clean out if there, then start dhcp daemon
# in the background.

if [ -d /run/cni ] ;
then
    sudo rm -rf /run/cni/*
else
    sudo mkdir /run/cni
    sudo chmod a+rwx /run/cni
    sudo touch /run/cni/dhcpd.log
    sudo chmod a+rwx /run/cni/dhcpd.log
fi

cd /opt/cni/bin
sudo ./dhcp daemon -pidfile=/run/cni/dhcpd.pid </dev/null &>/run/cni/dhcpd.log &


   
