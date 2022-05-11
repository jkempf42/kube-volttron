# Deploying the Volttron K8s Gateway Node

The gateway node sits at a remote site, like in a building or at a solar farm
or a EV charger,
connected to the site's local area network with routing to the Internet.
A gateway pod with a Volttron deployment acts as an intermediary between the
IoT devices running on site and the Volttron Central pod running on the
control node in the
cloud (nominally Azure but you can change it) or in an on-prem data center. 
The gateway pod monitors IoT devices 
on the site, reports the data back to the Volttron Central node running in the
cloud, and conveys commands from Volttron Central to the devices.

You have a choice of two different preconfigured containerized Volttron microservices
for two IoT device simulators to try out:

- vremote - a Volttron microservice using the fake driver that comes with the 
Volttron distro. This microservice requires no additional simulated or
actual device and no additional network configuration.

- vbac - a Volttron microservice that handles devices using the 
[BACnet protocol](http://www.bacnet.org/). This device requires at most one device
that responds to BACnet. A [simulated AHU device](https://github.com/bbartling/building-automation-web-weather) incorporated by copy as sim_AHU.py here, based on the [BAC0](https://bac0.readthedocs.io/en/latest/) package by Christian Tremblay, is provided courtesy of Ben Barting, see below for more on how to deploy it. The vbac microservice requires additional network configuration an
overview of which is given is discussed in the next section.


## BACnet gateway node network architecture

If you decide to deploy vbac, you will need some additional networking support to
allow the Volttron BACnet proxy agent access to BACnet devices on the local area
network. By default, kube-volttron uses the [Flannel CNI driver](https://github.com/flannel-io/flannel#flannel)
for intra cluster networking between pods. Flannel constructs an isolated overlay network inside the cluster
with CIDR 10.244.0.0/16 using the [VXLAN overlay protocol](https://datatracker.ietf.org/doc/html/rfc7348), and there
is no routing between pods inside the cluster and devices outside by default, though pods on the gateway node 
can communicate with pods on other nodes in the cluster, including the Volttron Central pod in the cloud, through 
the overlay. In the figure below, the BACnet K8s cluster network architecture allows the vbac pod to communicate with devices on the host IP subnet by 
creating another interface in the pod connected directly to the host network.

![BACnet network architecture](image/bn-gateway-node-arch-flannel.png)

The gateway pod is configured with an additional network interface using some advanced features of the CNI. The [Multus
multi-interface CNI driver](https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/configuration.md) 
connects up both the intra-cluster Flannel network and a second interface imported from
the second interface on the gateway host into the gateway pod. The Multus
git distro is already incorporated by reference into the gateway-node directory
via the subdirectory multus-cni.
This means the host VM or OS must have two Ethernet interfaces, one
connected to the local area network and the Internet through a router and one that is absorbed into the gateway
pod when it is created. [^1] A K8s yaml manifest is provided to create `NetworkAttachementDefinition` K8s CNI 
object called `bacnet` 
of type `host-device` for the second interface. This obtains its DHCP address from the host IP subnet, 
allowing the Volttron BACnet Proxy Agent running in the gateway pod to conduct UDP traffic over BACnet port 47808 
with devices (both simulated
and real) running on the host IP subnet. The Volttron BACnet Proxy Agent communicates with the Volttron Platform
Driver Agent via the VIP bus running on the Unix socket 22916. Similarly, the other Volttron agents communicate
amongst themselves using the VIP bus. The Actuator Agent, Forwarding Historian, and Volttron Central Platform Agent
communicate with the Volttron Central pod using HTTPs over the intra cluster network on port 8443. 
Note that at this time the Volttron BACnet Proxy Agent does not
conduct BACnet broadcast (WhoIs/IAm) but this architecture should enable broadcast from and to the gateway
pod in the future. Without the second interface, the gateway pod cannot communicate with BACnet devices
on the host IP subnet. [^2]

[^1] The installation directions below walk you through creating a VM with VirtualBox that has an additional 
interface.

[^2] Some CNI drivers that do not use overlays ("flat" drivers) may allow broadcast and direct access to the host network, this is an area for future work.

## Preparing the base VM or operating system

As mentioned above, you will need a base VM or operating system with two network interfaces to support
a two interface gateway pod. How you configure an additional 
interface depends on what 
operating system and/or VM manager you are using. Kube-volttron was developed on 
Ubuntu 20.04 using the VirtualBox VMM, so the directions for adding an 
additional interface to a VirtualBox VM are explained in detail in the following subsections.

### Clone a VM or import an ISO for a new one.
Clone an existing VM using VirtualBox by right clicking on the VM in the left side menu bar and choosing *Clone* from the VM menu.

### Bring up the Network Settings tab
Right click on the new VM in the left side menu bar of the VirtualBox app
to bring up the VM menu, then click on *Settings*. When
the *Settings* tab is up, click on *Network* in the left side menu bar. You should get a tab that looks like this:

![Network Settings tab](image/vb-net-settings.png)

Be sure your first interface is a *Bridged Adaptor* and not NAT or anything else

### Configure the second interface

Click on the *Adaptor 2* tab then
click the check box marked *Enable Network Adaptor*. Select the 
*Bridged Adaptor* for the network type. Click on the *Advanced* arrow and make sure the *Cable Connected* 
checkbox is checked.

### Save the configuration

Save the configuration by clicking on the *OK* button on the bottom right.

Your VM should be ready to run.

## If you have a cloud Volttron Central already deployed

If you already have a K8s node deployed in the cloud, you should use the [BYOH 
ClusterAPI](https://github.com/vmware-tanzu/cluster-api-provider-bringyourownhost) operator to deploy and provision your gateway node, see the parent README and you can skip the next section since ClusterAPI handles K8s installation on
worker nodes.

## Preinstallation host config

Prior to installing K8s, be sure to set the hostname on the node:

	hostnamectl set-hostname <new-hostname>
	
and confirm the change with:

	hostnamectl

You should not have to reboot the node.

Find your host IP addresses using `ifconfig` and note the IP address having the lowest host number (last field).
For example, on my machine the first interface has host number 125 and is named `enp0s3` while the second interface
has host number 126 and has name `enp0s8`. Kubernetes will run on the first interface while the second interface 
will become part of the gateway pod.

Make a directory to put in downloaded files and other artifacts of the cluster setup:

	mkdir kubeadm-install
	

## Deploying K8s on the gateway node.

`kubeadm` is the recommended deployment tool for K8s on the node, because many other K8s distros are opinionated
about networking in specific ways that may be incompatible 
with running a pod having a second interface onto the host subnet. 
The cluster installation process should take about 45 minutes, and if something goes wrong, you should simply delete
your VM (if you are using a VM) and clone a new one or reinstall the OS and start over because it is 
very timeconsuming to troubleshoot a broken installation. 
You can find instructions for
installing K8s with `kubeadm` [here](https://computingforgeeks.com/deploy-kubernetes-cluster-on-ubuntu-with-kubeadm/). 
The page includes instructions for installing
the Docker runtime but be sure to also install the Mirantis docker shim,
since the shim is no longer distributed with K8s by default. A [link](https://computingforgeeks.com/install-mirantis-cri-dockerd-as-docker-engine-shim-for-kubernetes/) to the instructions for installing the shim is 
on the kubeadm installation page at the place in the process where you need to install it 
but is also included here for reference.

When when you use kubeadm to pull images, be sure to include the --cri-socket for Docker:

	sudo kubeadm config images pull --cri-socket=unix:///run/cri-dockerd.sock
	
The socket file needs to be formatted as a URL, otherwise kubeadm will complain.

The `kubeadm init` command also needs to be run as root:

	sudo kubeadm init --control-plane-endpoint <host IP address w. lowest host number> --pod-network-cidr 10.244.0.0/16  --cri-socket unix:///run/cri-dockerd.sock

The pod network CIDR given above is for Flannel, which we will use as the CNI provider for the intra-pod network.

Near the end of the printout, `kubeadm` prints instructions for enabling nonroot users to access the cluster. Be sure
to run them before going any further.

At the end of the output for `kubeadm init`, instructions for adding a worker node will be printed, for example:

	You can now join any number of control-plane nodes by copying certificate authorities
	and service account keys on each node and then running the following as root:

	kubeadm join <host IP address w. lowest host number>:6443 --token zz7oz0.levc66osara7u9ij \
		--discovery-token-ca-cert-hash sha256:be2301e4a26f33a0d408dc49068765493da2a2dde76784a4ca3af5dfee3fe031 \
		--control-plane 

	Then you can join any number of worker nodes by running the following on each as root:

	kubeadm join 192.168.0.125:6443 --token zz7oz0.levc66osara7u9ij \
		--discovery-token-ca-cert-hash sha256:be2301e4a26f33a0d408dc49068765493da2a2dde76784a4ca3af5dfee3fe031 

You should note these down. While it isn't likely that you will need to add another node, best to save it in a file
just in case. 

For cluster networking, you should use Flannel, which is the simplest (constructs an overlay network in the 10.244.0.0/16
private address space). To install Flannel, type the following into a shell window:

	kubectl apply -f https://github.com/coreos/flannel/raw/master/Documentation/kube-flannel.yml

You also need to remove the taint on the K8s control node that prohibits app 
workloads from running on it, since the gateway cluster only has one node. 
Use the following command:

	kubectl taint node <node host-name> node-role.kubernetes.io/master-
	
## Clone the kube-volttron git repo

If you haven't already, clone the kube-volttron git repo:

	git clone https://github.com/jak42/kube-volttron/
	
Change to the `gateway-node` subdirectory:

	cd kube-volttron/gateway-node

## Installing the Multus multi-network CNI driver

In order to deploy a multi-interface pod, you need to install the Multus CNI driver.
Complete instructions for installing Multus including technical background are [here](https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/quickstart.md). Your clone of the `kube-volttron` repo should have cloned Multus as a 
submodule. 

To install Multus, change to the `multus-cni` subdirectory and install the Multus custom resource:

	cd multus-cni
	cat ./deployments/multus-daemonset-thick-plugin.yml | kubectl apply -f -

Wait for a few minutes, then check that the pods are running:

	kubectl get pods --all-namespaces | grep -i multus

You should see output like this:

	kube-system   kube-multus-ds-zrv4j           1/1     Running   6 (13h ago)    24d

Note that there is no way to uninstall Multus once you have installed it, so don't install it on a K8s cluster
unless you want to run multiple CNI plugins.

There are other options for 
handling multi-interface pods, but they are all complicated and primarily for
software defined networking telcom use cases. We only need one pod with two 
interfaces, one for the intra cluster pod network and one for talking to BACnet devices on the host subnet.

## Configuring the host network to support a multi-interface pod

First, we need to enable routing on the host. Edit `/etc/sysctl.conf` and uncomment `net.ipv4.ip_forward=1` and 
`net.ipv6.conf.all.forwarding=1` to enable routing on the host after reboot, if they aren't already, 
then use the command:

	sudo sysctl <routing variable>=1

where `<routing variable>` is  `net.ipv4.ip_forward` and `net.ipv6.conf.all.forwarding` to enable routing 
in the running host.

You can test whether your configuration has worked by running:

	sudo sysctl -a | grep <routing variable>

Multus requires IP address management (ipam) to be specified for the second pod interface. 
Since we want the second interface to be part of the host network, we need to provision the IP address
from the host subnet DHCP server. Unfortunately, Multus cannot find 
the DHCP server on your host subnet without a relay, so we need
to start the CNI DHCP relay on the host. Two utility scripts are provided 
for this purpose. The scripts run commands with `sudo` so you will be prompted 
for your password:

- `start-dhcpd.sh` - Start the CNI DHCP relay daemon. Handles cleanup of 
old log file 
or creation of a directory for the log file and CNI dhcp daemon socket file if the directory
doesn't exist.

- `stop-dhcpd.sh` - Kills the CNI DHCP relay daemon

[This page](https://www.cni.dev/plugins/current/ipam/dhcp/)
provides more information on enabling DHCP ipam for K8s CNI.

## Kubernetes manifests for deploying gateway pods

A collection of Kubernetes yaml manifests are provided for testing and demos.
In addition to manifests for the two IoT gateway pods, a manifest is provided 
for deploying a Volttron Central pod including the SQL Lite historian, in case
you want to try out the gateway node standalone. This section describes the
manifests. 

Note that if you decide to develop your own Volttron microservice containers, 
you will need to replace the name of the container image in the manifests under the 
`spec.template.containers.image` key, which is currently set to
`jkempf42/public-repo:<image type tag>`, with your own repository and image tag.

### Volttron Central microservice manifests

The Volttron Central microservice requires the following two manifests: 

- `vcentral-deploy.yml`: This sets up a K8s `Deployment` for a vcentral Volttron Central microservice with an 
SQL Lite historian. 
The deployment has only one replica. The
K8s `Deployment` restarts the pod if it crashes. The database is not exported from the container so the data won't 
be saved if you bring down the gateway node.

- `vcentral-service.yml`: This defines a `ClusterIP` type service for vcentral, but
with an external IP address so that you can access the Volttron Central 
Web UI from a 
browser running on the host for testing. You should replace the IP address in
the manifest, the array value of the key `spec.externalIPs`, with the IP address of your host machine. 
Currently this is set to `192.168.0.118`. The Volttron Central Web UI will run on the standard Volttron port,
8443, on your host machine so be sure there is no other service running on
that port. The service manifest also contains a port definition for the 
VIP bus port at port number 22916 so the gateway pods can connect to
the VIP bus (individual pods in a K8s cluster have no access to a common Unix
socket which is how agents typically communicate on the VIP bus). 
Note that the `externalIPs` configuration is
only for development, testing, and demo purposes. In the actual cloud-based Volttron
Central deployment, this is replaced with a K8s `Ingress` or
`Gateway` object.

### Manifests for deploying the vremote microservice with the fake driver 

The vremote microservice requires the following two manifests:

- `vremote-deploy.yml`: Creates a one pod `Deployment` of the vremote microservice, with a forwarding historian to send data to the Volttron Central pod historian. 

- `vremote-service.yml`: A `ClusterIP` type service for the vremote pod, with HTTP and VIP ports defined. 
There is no external IP definition for the vremote microservice,
since the vremote microservice is only accessed through the Volttron Central Web UI.

### BACnet NetworkAttachmentDefinition manifest for second gateway pod interface

The K8s CNI handles additional pod interfaces though a 
`NetworkAttachmentDefinition` object. 
Multus requires a network attachment point definition to configure the vbac 
pod with the second interface. 
The file `bacnet-net-attach-def.yml` contains an attachment definition for the
gateway pod's second interface. Multus matches the value of the `NetworkAttachmentDefinition` 
`metadata.name` (`bacnet` in this case) with a configuration item in 
the bacnet `Deployment` pod spec for the second interface. The `spec.config` value is a 
JSON object providing the configuration for the second interface.

Edit the manifest to configure it to your network as follows:

- Find the name of the second interface on your host by typing `ifconfig` or `ip address` 
to a `bash` shell, or find it from your notes from above. This is the interface with the higher IP host number (last
byte of the IP address).

- Edit the `bacnet-net-attach-def.yml` file and change the `"device"` 
property value, which is set to `"enp0s8"`, to the name of the second network 
interface on your host machine. This interface will get 
absorbed into the cluster network namespace and disappear from the
host network namespace when you deploy a pod with a
second interface.

### Configmap manifests for vbac

The K8s `Configmap` object provides a way to inject configuration data into a container when a pod is deployed. 
Container images can be distributed without the final configuration in them, and 
then a customized configuration specific to the particular deployment environment can be injected when
the container is deployed.
Because Volttron was originally build around a monolithic architecture, the original volttron-docker distro does configuration by deploying all the agents into a container with their all of their deployment environment configuration
in them. Every Volttron deployment is built from scratch and configured on the machine where it will run. However, the
microservice-volttron distro has been engineered to allow redistributable containers. 

The two yaml files defining `Configmap` objects are:

- `bacnet-configmap.yml`: Creates a `Configmap` in the `/home/volttron/configs/bacnet` directory with
two file "keys": `sim-AHU.config` and `sim-AHU.csv`. The first contains the IP address of the simulated
AHU device and other data for the BACnet driver, the second contains the simulated AHU device schema we
are interested in accessing. These files are only loaded by Volttron when it builds the vbac image, after
that they are not accessed.

- `platform-driver-configmap.yml`: Contains exactly the same information as `bacnet-configmap.yml`, 
except it is placed into a directory where the Volttron build process squirrels away configuation 
data, `/home/volttron/.volttron/configuration_store`. The information is in a different format, basically
a consolidation of the `sim-AHU.config` and `sim-AHU.csv` files into a single JSON object. This is the
file that is loaded into the Platform Driver Agent BACnet driver when the vbac container boots.


### Vbac microservice manifests for BACnet devices

The vbac microservice with the gateway for the BACnet protocol consists of two 
manifests:

- `vbac-deploy.yml`: Creates a one pod `Deployment` of the vbac microservice
running the Volttron BACnet Proxy Agent, with a forwarding historian to send data to 
the Volttron Central pod historian database, and an actuator agent to receive commands from Volttron Central. 
This manifest needs to be customized to your network as described below.

- `vbac-service.yml`: A `ClusterIP` type service for the vbac pod, with 
HTTP and VIP ports defined. There is no external IP definition for the 
vbac service, since the vbac service is accessed only through the Volttron 
Central Web UI.

Customize the `vbac-deploy.yml` `Deployment` manifest as follows:

- Edit the file and replace the value of the `"default-route"` property, set to  `"192.168.0.118"`, in the JSON object that is the value of the 
`spec.template.annotaions.k8s.v1.cni.cncf.io/networks` key with the IP 
address of your host machine. Normally with Flannel, the default route goes out the `eth0` interface as shown in
the above diagram and over `cni0` host interface into the `flannel` overlay. 
Changing the default route ensures that traffic to the host subnet exits the pod
through the `net0` interface which is on the host subnet. Traffic to other pods in the cluster, including the vcentral
pod, will still go through the `eth0` interface.

## Deploying the vcentral microservice pod

You need to have a Volttron Central microservice deployed somewhere in your cluster
network before deploying any gateways, because the gateways use hostname base service discovery look for the
Volttron Central hostname (`vcentral` in by default) to connect up
with Volttron Central. If you don't have a cloud or on-prem remote Volttron Central deployed
you can deploy a test vcentral microservice in
the standalone gateway cluster as follows. 

First, deploy the `Service` with:

	kubectl apply -f vcentral-service.yml
	
Then the `Deployment`:

	kubctl apply -f vcentral-deploy.yml
	
Check if the pod is running with:

	kubectl get pods
	
If the pod is running, you should see something like:

	NAME                       READY   STATUS    RESTARTS      AGE
	vcentral-97b777d64-thd95   1/1     Running   0             2m
	
The first time you start it, it may take a while to download the image.

You can test whether the Volttron Central microservice is running through a 
browser running on the host to browse to the Web page. Type 
`https://<host IP address>:8443/index.html` into the address bar. This will bring up the
Volttron Central admin splash page:

![Volttron Central splash page](image/vc-admin-splash.png)

Click on *Login to Administration Area* to bring up the master admin
config page, where you can set the admin username and password:

![Voltron Central master admin password config](image/vc-master-admin-pw-config.png)

After filling in the admin username and password, click *Set Master Password* and you should see the admin login page come up.

You can view the Volttron Central dashboard web app by browsing to the URL 
`https://<host machine IP address>:8443/vc/index.html`. This will bring up the Volttron Central login page:

![Volttron Central login page](image/vc-login.png)

Type in the username and password you previously entered to the admin config. You 
should now be in the Volttron Central dashboard Web app:

![Volttron Central dashboard web app](image/vc-dashboard.png)

This should verify that the vcentral microservice is working.

Note that the vcentral microservice uses SQL-lite without mounting an external volume for the database 
so the database will not
outlive the pod lifetime.

### Deploying the vremote microservice pod

If you just want to try out kube-volttron, you can deploy the vremote pod with
the fake driver. First you need to deploy the vremote `Service`:

	kubectl apply -f vremote-service.yml
	
Then the `Deployment`:

	kubctl apply -f vremote-deploy.yml
	
Check if the pod is running with:

	kubectl get pods
	
If the pod is running, you should see something like:

	NAME                       READY   STATUS    RESTARTS      AGE
	vcentral-97b777d64-tvnml   1/1     Running   0             30m
	vremote-847b9686c4-wn8tz   1/1     Running   0             14s

You can check if the vremote gateway is visible in Volttron Central by returning
to your browser, clicking the refresh button, then clicking on *Platforms*. 
You should see a display like this:

![Volttron Central platforms display](image/vc-vremote-platforms.png)

Notice that the display says that 0 agents are running. This is because Volttron
uses the process id of the agent process to determine if the agent is running, but
if the agent is running in a separate container, the process id will be in a 
separate Linux namespace and therefore invisible to the Volttron Central web app.

Clicking on *vremote* shows the agents running in the vremote microservice:

![Vremote agents running](image/vc-vremote-agents-running.png)

Go up to the menu bar in the upper right hand corner and click on *Charts*.
This will bring up a display where you can configure charts of data to display.
Click on the *Add Charts* button and the *Add Chart* dialog should come up. Click on the *Topics* pulldown list.
You should see a pulldown list of variables you can display (*OutsideAirTemperature1*, etc.).
If you'd like to display a chart, select the variable, then select the chart type in the *Chart Type* pulldown.

This should confirm that your vremote gateway microservice pod is running and can connect to the vcentral pod
running on the local node.

Be sure to remove the vremote `Deployment` before creating the vbac `Deployment`:

	kubectl delete deploy vremote
	
## Deploying the simulated BACnet AHU

The Python file `sim-AHU.py` is a copy of Ben Barting's simulated air handling unit, programmed on top of the
BAS0 package. Install the BAS0 package using `pip`:

	pip install BAS0
	
In a separate bash shell window, start the simulated air handling unit:

	python3 sim-AHU.py
	
You should see the following:

	2022-05-07 19:26:00,094 - INFO    | Starting BAC0 version 21.12.03 (Lite)
	2022-05-07 19:26:00,095 - INFO    | Use BAC0.log\_level to adjust verbosity of the app.
	2022-05-07 19:26:00,095 - INFO    | Ex. BAC0.log\_level('silence') or BAC0.log_level('error')
	2022-05-07 19:26:00,095 - INFO    | Starting TaskManager
	2022-05-07 19:26:00,125 - INFO    | Using ip : 192.168.0.118
	2022-05-07 19:26:00,177 - INFO    | Starting app...
	2022-05-07 19:26:00,177 - INFO    | BAC0 started
	2022-05-07 19:26:00,178 - INFO    | Registered as Simple BACnet/IP App
	2022-05-07 19:26:00,180 - INFO    | Update Local COV Task started
	2022-05-07 19:26:00,181 - INFO    | Adding DPR0-O to application.
	2022-05-07 19:26:00,181 - INFO    | Adding DPR1-O to application.
	2022-05-07 19:26:00,181 - INFO    | Adding DPR2-O to application.
	2022-05-07 19:26:00,181 - INFO    | Adding DPR3-O to application.
	2022-05-07 19:26:00,181 - INFO    | Adding DPR4-O to application.
	2022-05-07 19:26:00,181 - INFO    | Adding DPR5-O to application.
	2022-05-07 19:26:00,181 - INFO    | Adding DPR6-O to application.
	2022-05-07 19:26:00,181 - INFO    | Adding DPR7-O to application.
	2022-05-07 19:26:00,181 - INFO    | Adding DPR8-O to application.
	2022-05-07 19:26:00,181 - INFO    | Adding DPR9-O to application.
	2022-05-07 19:26:00,181 - INFO    | Adding DAP-SP to application.
	2022-05-07 19:26:00,182 - INFO    | Adding SF-S to application.
	2022-05-07 19:26:00,182 - INFO    | APP Created Success!
	2022-05-07 19:26:00,182 - INFO    | DPR0-O is Real(50)
	2022-05-07 19:26:00,182 - INFO    | Duct Pressure Setpoint is Real(1)
	2022-05-07 19:26:10,188 - INFO    | DPR1-O is Real(50)
	2022-05-07 19:26:10,189 - INFO    | Duct Pressure Setpoint is Real(1)
	2022-05-07 19:26:20,195 - INFO    | DPR2-O is Real(50)
	2022-05-07 19:26:20,196 - INFO    | Duct Pressure Setpoint is Real(1)

Note down the IP address in line 5, since you will be using that to edit the Volttron Platform Driver Agent `Configmaps`.

Since the vbac container has the basic configuration for the simulated AHU baked
in, you will have to build another container with configuration if you
want to deploy BACnet with other devices. See the Volttron documentation pages
[here](https://volttron.readthedocs.io/en/main/driver-framework/bacnet/bacnet-auto-configuration.html) about the scripts you'll need to run to find BACnet
devices and generate configuration files for the Platform Driver Agent BACnet 
driver.

## Deploying the vbac pod

### Customize the Platform Driver Agent `ConfigMaps`

Edit the two `Configmap` files `bacnet-configmap.yml` and `platform-driver-configmap.yml` and
replace the IP address `192.168.0.118` with the IP address on which `sim-AHU.py` is running, noted 
down in the previous step.

Create the two `Configmaps` using `kubectl`:

	kubectl apply -f bacnet-configmap.yml
	kubectl apply -f platform-driver-configmap.yml

You can check if the creation operation succeeded with:

	kubectl get configmap bacnet-config
	kubectl get configmap platform-driver-config

or print more detailed information using `kubectl describe`.

### Creating the vbac `Service`

Before creating the vbac `Deployment`, you first need to create the vbac `Service` and the `bacnet` `NetworkAttachmentDefinition`.

Create the vbac `Service` as follows:

	kubectl apply -f vbac-service.yml
	
This creates a `ClusterIP` service for vbac on both the http (port 8443) and the VIP bus (port 22916). 

Create the `bacnet` `NetworkAttachmentDefinition` as follows:

	kubectl apply -f bacnet-net-attach-def.yml
	
You can examine the `bacnet NetworkAttachmentDefinition` with:

	kubectl describe net-attach-def bacnet
	
### Creating the vbac `Deployment`

Create the vbac deployment as follows:

	kubectl apply -f vbac-deploy.yml
	
	
Use:

	kubectl get --watch pod
	
to watch the pods until the vbac pod is running. Note that the pod will have a uuid after the generic
pod name "vbac".

### Check whether the deployment was successful from the Volttron Central web app

Using the Vottron Central web app deployed either locally earlier or in the cloud, check whether the deployment was
successful by logging in and navigating to the *Platforms* page as described above. Click on *vbac*->*Charts*->*Add Chart*.
In the *Add Chart* dialog, click on the *Topics* pulldown and you should see a pulldown list as in the following display:

![Vbac topic list](image/vbac-topic-list.png)

Click on one of the topics then move down to the *Chart Type* pulldown list to add a chart.

## Troubleshooting

If you run into trouble deploying one of the microservice `Deployments`, you can use the `kubectl` log command to check the container logs:

	kubectl get pods
	kubectl logs <pod name>

If you are having problems with networking or service discovery, you can
troubleshoot by exec-ing into one of the pods and using the Ubuntu 
Linux networking tools. 

	kubectl exec -it <pod name? -- /bin/bash
	














