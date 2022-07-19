# Deploying Volttron Central on the central node.

The instructions below assume that you have configured a cluster following the
directions in `cluster-config/README.md`. The instructions will walk 
you through the steps needed to deploy the `vcentral` microservice in 
your central node VM. 

## Vcentral manifests

### Vcentral service manifests

The `vcentral` service manifests are contained in the following two yaml files: 

- `vcentral-deploy.yml`: This sets up a Kubernetes Deployment for a vcentral Volttron Central microservice with an 
SQL Lite historian mounted to the VM's file system so the data survives the
container going down. The deployment has only one replica pod. The Kubernetes Deployment restarts the pod if it crashes. 
You need to edit the file and replace the value of the 
`kubernetes.io/hostname` key which is`central-node` 
with the hostname of your central node.

- `vcentral-service.yml`: This defines a NodePort type Service for the `vcentral` HTTP service at
port 8443 and the VIP bus service at port 22916. The Nginx reverse proxy
forwards HTTP requests on port 80 of the global DNS name for the VM to port 8443 if you are running
`central-node` in a cloud, or you can access the service directly at port 8443 
if you are running in a local VirtualBox
VM. The VIP bus service allows the `gateway-node` pod to connect
with the VIP bus in the `central-node` pod. 

### Vcentral storage manifest

The `vcentral` storage manifest in the file `vcentral-storage.yml` defines three Kubernetes objects for mounting a local directory into the `vcentral` pod:

- StorageClass: This defines a type for a Kubernetes persistent volume. A `local` storage class is
used because we want to mount a local directory, and the class name is `local-storage`

- PersistentVolume: This type describes the path to the actual directory on the local node we 
want to mount. It also needs to specify what node the directory is on in the `nodeAffinity` section. 
Change the node name in the `matchExpressions:` `values:` section from
`central-node` to the hostname of your central node if you changed it. 
Note the `spec.persistentVolumeReclaimPolicy` is set to `Retain`
indicating that the volume should be retained if the pod goes down, and the `storageClassName` indicates the name of the StorageClass type of the persistent volume, in this case `local-storage`.

- PersistentVolumeClaim: This type allows a pod to exercise a claim on the PersistentVolume. 
It also indicates 
the `storageClassName`, again, `local-storage`. The `accessModes` 
array is set to `ReadWriteOnce` indicating that
only one pod at a time can read and write to the volume.

## Preparing the `central-node` for `vcentral` deployment

We use node labels to restrict the deployment of the `vcentral` microservice to the control node. `Kubeadm` adds a label
with the hostname, having key `kubernetes.io/hostname`. Check whether that label is present on the central node:

	kubectl get nodes --show-labels | grep <central node hostname>
	
If it isn't there, use the following command to add it:

	kubectl label nodes <central node hostname> kubernetes.io/hostname=<central node hostname>
	
We also need to create a local directory for the persistent volume 
on `central-node` that will hold the Historian database. 

	sudo mkdir -p /data/volttron/db
	
and change the permissions so anyone can read/write it:

	sudo chmod -R 777 /data/volttron/db
	
### Deploying the `vcentral` microservice with storage

Change to the `central-node` directory.

#### Deploying the persistent storage objects

The persistent storage objects are deployed with:

	kubectl apply -f vcentral-storage.yml

then check whether the objects have been created:

	kubectl get storageclass

which should show something like:

	NAME                     PROVISIONER                    RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
	volttron-local-storage   kubernetes.io/no-provisioner   Delete          WaitForFirstConsumer   false                  21m

Check for the PersistentVolume:

	kubectl get persistentVolume

which should show something like:

	NAME          CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS             REASON   AGE
	vcentral-pv   500Mi      RWO            Retain           Available           volttron-local-storage            56s

Check for the PersistentVolumeClaim:

	kubectl get persistentVolumeClaim
	
which should show something like:

	NAME             STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS             AGE
	vcentral-claim   Pending                                      volttron-local-storage   69s

#### Deploying the `vcentral` service objects

The `vcentral` service objects are deployed with:

	kubectl apply -f vcentral-service.yml
	
and you can check whether they have been deployed with:


	kubectl get service

which should show something like:

	NAME         TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)                          AGE
	kubernetes   ClusterIP   10.96.0.1        <none>        443/TCP                          23h
	vcentral     NodePort    10.110.166.233   <none>        8443:31776/TCP,22916:30777/TCP   15s
	
#### Creating the `vcentral` Deployment

Finally, we can create the `vcentral` deployment:

	kubectl apply -f vcentral-deploy.yml
	
We can watch the `vcentral` pod come up with:

	kubectl get --watch pods
	
which will follow progress on creating the pod:

	NAME                        READY   STATUS              RESTARTS   AGE
	vcentral-55f7968955-x54jq   0/1     ContainerCreating   0          26s
	vcentral-55f7968955-x54jq   1/1     Running             0          89s

#### Configuring Nginx to proxy the Volttron Central website through a cloud VM's DNS name

If you are running on a cloud VM, you now need to configure Nginx to proxy the Volttron
Central website through the cloud VM's DNS name.

Edit `/etc/nginx/nginx.conf` as superuser and comment out the line for 
sites enabled:

	\# include /etc/nginx/sites-enabled/*;


This ensures that the only pathnames will come from `/etc/nginx/conf.d`, which is
where we will put the config file for `kube-volttron`. Save the file and 
exit.

Copy the file `kube.conf` from this directory into the Nginx 
configuration directory:


	sudo cp kube.conf /etc/nginx/conf.d

Reload Nginx with:

	sudo nginx -s reload
	
It should not print anything out if your edits were correct.


#### Creating a system service to restart dnsmasq and Nginx after `vcentral` is running

If your `central-node` VM is running in a cloud, you may want to shut
it down periodically to save cost or for other reasons then boot it up
again when you need it. Because `systemd` does not sychronize starting 
`dnsmasq.service` and `nginx.service` with the Kubernetes cluster, if
the CoreDNS pods are not running when `dnsmasq` boots, 
`dnsmasq` won't be able to resolve 
any names within the cluster for `nginx` and so the Nginx service fails to 
start when it checks for `vcentral` site to proxy, and `dnsmasq` fails to 
connect with the CoreDNS pods in the cluster. 

To fix this, we define a `systemd` service, `restart-nginx-dnsmasq.service` 
in the file by that name in this directory. The service starts up the
shell script in `restart-nginx-dnsmasq.sh`. This shell script does the
following:

- Checks if Nginx has been configured to proxy requests to `vcentral`,

- Waits until the `vcentral` service is running,

- Restarts `dnsmasq.service` and `nginx.service`. 

To 

## Testing the `vcentral` deployment


### Checking if the Volttron Central microservice web site is up

If `central-node` is running on a cloud VM, you can test whether the deployment suceeded by running the following command from the `ssh` command line:

	curl -k https://vcentral.default.svc.cluster.local:8443/index.html

It should print out the HTML code for the Volttron Central administrative splash page.Note 
that using the VM's global DNS name may not work from 
the VM itself, but you can always use the service name 
directly if you want to access it from outside the cluster on `central-node`.

If `central-node` is  running on a local VirtualBox VM, you should be able to get to the Volttron Central administrative
configuration page by typing https://vcentral.default.svc.cluster.local:8443/index.html into the
browser URL bar of a browser running on the local VM. Note that `dnsmasq` does not export 
the name to any nodes
outside the local VM itself, so you will have to use a browser on the local VM to access it.

If the `central-node` is running in a cloud VM, find its DNS name. On Azure, the DNS name 
for your VM is on the VM *Overview* page.  You can then use a browser from the `gateway-node`
host or a laptop to access the 
Volttron Central website over the Internet by 
typing `http://<DNS name for VM>/index.html` into the browser address
bar. When accessing the Website over the Internet, you need to use 
`http` and not `https` because the port opened on the firewall is port 80.

### Configuring passwords in the Volttron Central admin page and viewing the dashboard

The Volttron Central admin splash page looks like:

![Volttron Central splash page](image/vc-admin-splash.png)

Click on *Login to Administration Area* to bring up the master admin
config page, where you can set the admin username and password:

![Voltron Central master admin password config](image/vc-master-admin-pw-config.png)

After filling in the admin username and password, click *Set Master Password* and you should see the admin login page come up.

You can view the Volttron Central dashboard web app by browsing to the URL 
`https://<site host>/vc/index.html`, where `<site host>` is either
`vcentral.default.svc.cluster.local` if your `central-node` is in a local VM or
`<DNS name for VM>` if your `central-node` is in a cloud VM. 

This will bring up the Volttron Central dashboard login page:

![Volttron Central login page](image/vc-login.png)

Type in the username and password you previously entered to the admin config and click on the *Log in* 
button. You should now be in the Volttron Central dashboard Web app:

![Volttron Central dashboard web app](image/vc-dashboard.png)

This should verify that the vcentral microservice web site is working.

## Troubleshooting

The `vcentral` log can be viewed with:

	kubectl logs <vcentral pod name>
	
Note that an error message may be printed out from SSL indicating a problem for the certificate, that
is because it is a self-signed cert and should not affect validation of web requests to the Volttron Central server. You may also get an SSL error involving
the `flannel.1` interface if you run the central node in a cloud server,
but that should not affect your ability to get to the Volttron Central 
website from the Internet.

You can exec a shell in the `vcentral` pod using the following command:

	kubectl exec -it <vcentral pod name> -- /bin/bash

You can modify config files if needed and start and stop Volttron.

If you want to start the `vcentral` pod up in a shell without starting Volttron, add the following lines
into the `vcentral-deploy.yml` in the pod spec section, just after the `imagePullPolicy:` line
and indented at the same level:

          command: ["/bin/bash"]
          args: [ "-c", "while true; do sleep 600; done" ]

You can then exec into the pod and start Volttron by hand. Be sure to `su volttron` before starting it, otherwise some Python packages may not be found.
This can be helpful if you need to debug some problem with Volttron.









	
