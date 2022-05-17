#! /usr/bin/bash



curl https://releases.rancher.com/install-docker/19.03.sh | sh
curl -sfL https://get.k3s.io | K3S_TOKEN="`cat node-token`" K3S_URL=https://10.8.0.1:6443 sh -s - --docker --node-ip 10.8.0.2 --node-external-ip 192.168.0.128 $@
