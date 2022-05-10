#! /bin/bash

set -x

# Kill dhcp daemon with pid in /run/cni/dhcp.pid

sudo kill -9 `cat /run/cni/dhcpd.pid`
