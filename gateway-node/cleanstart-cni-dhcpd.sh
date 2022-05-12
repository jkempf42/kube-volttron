#!/bin/bash

set -x

if ! [ -z "$(ls -A /run/cni)" ] ; then
    rm -rf /run/cni/*
fi

exec /opt/cni/bin/dhcp daemon
