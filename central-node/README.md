# Deploying Volttron Central on the central node.

The instructions below assume that you have configured a cluster following the
directions in `cluster-config/README.md`. The instructions will walk 
you through the steps needed to deploy the `vcentral` microservice in 
your central node VM. 

## Vcentral manifests

### Vcentral service manifests

The `vcentral` services manifests are contained in the following three yaml files: 

- `vcentral-deploy.yml`: This sets up a Kubernetes `Deployment` for a vcentral Volttron Central microservice with an 
SQL Lite historian mounted to the VM's file system so the data survives the
container going down. The deployment has only one replica pod. The Kubernetes `Deployment` restarts the pod if it crashes. 
You need to edit the file and replace the value of the 
`kubernetes.io/hostname` key which is`central-node` 
with the hostname of your central node.

- `vcentral-service.yml`: This defines a `ClusterIP` type service for vcentral, but
with an external IP address so that you can access the Volttron Central 
Web UI from a 
browser running on the host for testing. You can find out the addresses on your host
interface with `ifconfig`. You should replace the IP address in
the manifest that is the array value of the key `externalIPs`, with an IP address of the central
node machine on your local subnet. Don't use the loopback address (`127.0.0.1`) as the `Deployment`
will get an error when it tries to deploy a pod. Also, don't use the address on `wg0`, `flannel.1`
or `cni0` nor any of the `veth` interfaces since they are used by Kubenetes.
The Volttron Central Web UI will run on the standard Volttron port,
8443, on your host machine so be sure there is no other service running on
that port. The service manifest also contains a port definition for the 
VIP bus port at port number 22916 so the gateway pods can connect to
the VIP bus (individual pods in a Kubernetes cluster have no access to a common Unix
socket which is how agents typically communicate on the VIP bus). 

### Vcentral storage manifest

The `vcentral` storage manifest in the file `vcentral-storage.yml` defines three Kubernetes objects for mounting a 
local directory into the `vcentral` pod:

- `StorageClass`: This defines a type for a Kubernetes persistent volume. A `local` storage class is
used because we want to mount a local directory, and the class name is `local-storage`

- `PersistentVolume`: This type describes the path to the actual directory on the local node we 
want to mount. It also needs to specify what node the directory is on in the `nodeAffinity` section. 
Change the node name in the `matchExpressions:` `values:` section from
`central-node` to the hostname of your central node. 
Note the `spec.persistentVolumeReclaimPolicy` is set to `Retain`
indicating that the volume should be retained if the pod goes down, and the `storageClassName` indicates the name of the `StorageClass` type of the persistent volume, in this case `local-storage`.

- `PersistentVolumeClaim`: This type allows a pod to exercise a claim on the `PersistentVolume`. 
It also indicates 
the `storageClassName`, again, `local-storage`. The `accessModes` 
array is set to `ReadWriteOnce` indicating that
only one pod at a time can read and write to the volume.

## Preparing the node for vcentral deployment

We use node labels to restrict the deployment of the `vcentral` microservice to the control node. `Kubeadm` adds a label
with the hostname, having key `kubernetes.io/hostname`. Check whether that label is present on the central node:

	kubectl get nodes --show-labels | grep <central node hostname>
	
If it isn't there, use the following command to add it:

	kubectl label nodes <central node hostname> kubernetes.io/hostname=<central node hostname>
	
We also need to create a local directory for the persistent volume that will hold the historian database. 

	sudo mkdir -p /data/volttron/db
	
and change the permissions so anyone can read/write it:

	sudo chmod -R 777 /data/volttron/db
	
### Deploying the `vcentral` microservice with storage

#### Deploying the persistent storage objects

The persistent storage objects are deployed with:

	kubectl apply -f vcentral-storage.yml

then check whether the objects have been created:

	kubectl get storageclass
	NAME                     PROVISIONER                    RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
	volttron-local-storage   kubernetes.io/no-provisioner   Delete          WaitForFirstConsumer   false                  21m
	
	kubectl get persistentVolume
	NAME          CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS             REASON   AGE
	vcentral-pv   500Mi      RWO            Retain           Available           volttron-local-storage            56s
	
	kubectl get persistentVolumeClaim
	NAME             STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS             AGE
	vcentral-claim   Pending                                      volttron-local-storage   69s

#### Deploying the `vcentral` service objects

The `vcentral` service objects are deployed with:

	kubectl apply -f vcentral-service.yml
	
and you can check whether they have been deployed with:


	kubectl get service
	NAME         TYPE        CLUSTER-IP      EXTERNAL-IP     PORT(S)              AGE
	kubernetes   ClusterIP   10.96.0.1       <none>          443/TCP              19h
	vcentral     ClusterIP   10.105.192.93   192.168.0.129   8443/TCP,22916/TCP   5s
	
#### Deploying the `vcentral` deployment

Finally, we can create the `vcentral` deployment:

	kubectl apply -f vcentral-deploy.yml
	
We can watch the `vcentral` pod come up with:

	kubectl get --watch pods
	
which will follow progress on creating the pod:

	NAME                        READY   STATUS              RESTARTS   AGE
	vcentral-55f7968955-x54jq   0/1     ContainerCreating   0          26s
	vcentral-55f7968955-x54jq   1/1     Running             0          89s

#### Testing the Volttron Central microservice web site

You can test whether the Volttron Central microservice is running through a 
browser running on the host to browse to the Web page. Type 
`https://<host IP address>:8443/index.html` into the address bar. Your 
browser will bring up a page indicating that the certificate may be 
questionable, this is normal behavior because `vcentral` uses a self-signed
certificate. Click on the *Advanced*->*Continue* button or however your
browser designates it.

This will bring up the Volttron Central admin splash page:

![Volttron Central splash page](image/vc-admin-splash.png)

Click on *Login to Administration Area* to bring up the master admin
config page, where you can set the admin username and password:

![Voltron Central master admin password config](image/vc-master-admin-pw-config.png)

After filling in the admin username and password, click *Set Master Password* and you should see the admin login page come up.

You can view the Volttron Central dashboard web app by browsing to the URL 
`https://<host machine IP address>:8443/vc/index.html`. This will bring up the Volttron Central login page:

![Volttron Central login page](image/vc-login.png)

Type in the username and password you previously entered to the admin config and click on the *Log in* 
button. You should now be in the Volttron Central dashboard Web app:

![Volttron Central dashboard web app](image/vc-dashboard.png)

This should verify that the vcentral microservice web site is working.

## Troubleshooting

The `vcentral` log can be viewed with:

	kubectl logs <vcentral pod name>
	
Note that an error message may be printed out from SSL indicating a problem for the certificate, that
is because it is a self-signed cert and should not affect validation of web requests to the
Volttron Central server.

You can exec a shell in the `vcentral` pod using the following command:

	kubectl exec -it <vcentral pod name> -- /bin/bash

You can modify config files if needed and start and stop Volttron.

If you want to start the `vcentral` pod up in a shell without starting Volttron, add the following lines
into the `vcentral-deploy.yml` in the pod spec section, just after the `imagePullPolicy:` line
and indented at the same level:

          command: ["/bin/bash"]
          args: [ "-c", "while true; do sleep 600; done" ]

You can then exec into the pod and start Volttron by hand. Be sure to `su volttron` before starting
it, otherwise some Python packages may not be found.









	
