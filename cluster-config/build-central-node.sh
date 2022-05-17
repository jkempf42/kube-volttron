#! /usr/bin/bash

curl https://releases.rancher.com/install-docker/19.03.sh | sh
curl -sfL https://get.k3s.io | sh -s - --docker --write-kubeconfig-mode 644 --node-ip 10.8.0.1 --node-external-ip 192.168.0.129
