#! /bin/bash

# Restart nginx.service when vcentral is
# running.

# Check if Nginx is configured for vcentral

if [[ ! -e /etc/nginx/conf.d/kube.conf ]] ; then
    exit
fi

grep vcentral /etc/nginx/conf.d/kube.conf &>/dev/null
RETURN=$?

if [[ $RETURN -ne 0 ]]; then
    exit
fi

# Wait until the API server comes up.

curl -k https://vcentral.default.svc.cluster.local:8443 &>/dev/null
RETURN=$?

while [[ $RETURN -ne 0 ]]; do

    curl -k https://vcentral.default.svc.cluster.local:8443 &>/dev/null
    RETURN=$?

done

# Restart nginx

echo "Restarting nginx.service."

systemctl restart nginx.service

echo "Done."


