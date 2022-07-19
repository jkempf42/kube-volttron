#! /bin/bash

# Restart nginx.service and dnsmasq.service when the CoreDNS pods are
# running.

# Check if Nginx is configured for vcentral

if [[ ! -e /etc/nginx/conf.d/kube.conf ]] ; then
    exit
fi

grep vcentral /etc/nginx/nginx.conf/kube.conf 2>1 1>/dev/null
RETURN=?$

if [[ $? -ne 0 ]]; then
    exit
fi

# Wait until the API server comes up.

curl -k https://vcentral.default.svc.cluster.local:8443 2>1 1>/dev/null
RETURN=$?

while [[ $RETURN -ne 0 ]]; do

    curl -k https://vcentral.default.svc.cluster.local:8443 2>1 1>/dev/null
    RETURN=$?

done

# Restart dnsmasq and nginx

echo "Restarting dnsmasq.service and nginx.service."

systemctl restart dnsmasq.service
systemctl restart nginx.service

echo "Done."


