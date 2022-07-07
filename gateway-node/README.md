# Deploying the kube-volttron gateway node

The gateway node sits at a remote site, like in a building or at a solar farm
or a EV charger,
connected to the site's local area network with routing to the Internet.
A gateway pod with a Volttron deployment acts as an intermediary between the
IoT devices running on site and the Volttron Central pod running on the
control node. 
The gateway pod monitors IoT devices 
on the site, reports the data back to the Volttron Central historian
running in the
central node, and conveys commands from Volttron Central to the devices. In the
kube-volttron prototype, the gateway node runs in a VirtualBox VM,
monitors a simulated service running directly the host, and reports back
to the Volttron Central historian also running in a VirtualBox VM on the
same host. 

You have a choice of two different preconfigured containerized Volttron 
microservices for two IoT device simulators to try out:

- `vremote` - a Volttron microservice using the fake driver that comes with the 
Volttron distro. This microservice requires no additional simulated or
actual device, no additional Kubernetes objects.

- `vbac` - a Volttron microservice that handles devices using the 
[BACnet protocol](http://www.bacnet.org/). This device requires
the [simulated AHU device](https://github.com/bbartling/building-automation-web-weather), provided courtesy of Ben Barting, incorporated here
by copy as sim-AHU.py which is
based on the [BAC0](https://bac0.readthedocs.io/en/latest/) package by Christian Tremblay. See below for more on how to deploy it. Device configuration for sim-AHU.py is baked into the `vbac` microservice. The `vbac` microservice 
also requires additional network configuration an
overview of which is given is discussed in the next section, and additonal
Kubernetes objects.


## BACnet gateway node network architecture

If you decide to deploy `vbac`, you will need some additional networking support to
allow the Volttron BACnet proxy agent to access BACnet devices on the local area
network. By default, kube-volttron uses the
[Flannel CNI driver](https://github.com/flannel-io/flannel#flannel)
for intra cluster networking between pods. Flannel constructs an 
isolated overlay network inside the cluster
with CIDR 10.244.0.0/16 using the 
[VXLAN overlay protocol](https://datatracker.ietf.org/doc/html/rfc7348), and there
is no routing between pods inside the cluster and devices outside by default, 
though pods on the gateway node 
can communicate with pods on other nodes in the cluster, including the 
Volttron Central pod on the central node, through 
the overlay. With Flannel, any communication with the site network must go through a proxy.

BACnet uses broadcast for device discovery, and the Volttron BACnet proxy must be able to 
send and receive UDP traffic directly to and from the device, so the `vbac` pod
needs an interface directly on the local site network. The BACnet architecture uses
some advanced features of the CNI to enable multi-interface pods.
The [Multus multi-interface CNI driver](https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/configuration.md)
that was installed as part of the cluster configuration allows pods to be configured
with an additional interface on the site network. The figure below shows the 
BACnet Kubernetes cluster network architecture.   

![BACnet network architecture](image/bn-gateway-node-arch-flannel.png)

Multus connects up both the intra-cluster Flannel network and a second interface imported from
the gateway host into the `vbac` pod. As part of 
setting up your cluster, you created and configured a VirtualBox VM with two interfaces on the site local
network and deployed Multus on the central node. [^1]
Both interfaces are
connected to the local area network, one is connected to the Internet through a router and one is 
absorbed into the gateway
pod when it is created. A Kubernetes yaml manifest is provided to create a `NetworkAttachementDefinition` 
CNI object for the second interface, called `bacnet` 
of type `host-device`. The interface obtains its DHCP address from the host IP subnet, 
allowing the Volttron BACnet Proxy Agent running in the gateway pod to conduct UDP traffic over 
BACnet port 47808 
with devices (both simulated
and real) running on the host IP subnet. 

The other services communicate internally to the pod using Unix sockets
or over the Flannel network interface to
the `vcentral` agent.
The Volttron BACnet Proxy Agent communicates with the Volttron Platform
Driver Agent via the VIP bus running on the Unix socket 22916. Similarly, the other Volttron agents communicate
amongst themselves using the VIP bus. The Actuator Agent, Forwarding Historian, and Volttron Central Platform Agent
communicate with the Volttron Central pod using HTTPs over the Flannel network on port 8443. 
Note that at this time the Volttron BACnet Proxy Agent does not
conduct BACnet broadcast (WhoIs/IAm) but this architecture should enable broadcast from and to the `vbac` pod in the future. Without the second interface, the gateway pod cannot communicate with BACnet devices on the host IP subnet. [^2]

[^1] Or if you aren't using VirtualBox then otherwise created an Ubuntu 20.04 node  with a second interface.

[^2] Some CNI drivers ("flat" drivers) allow direct access to the host network from pods. 
Whether they can support
broadcast is a topic for further study. 

## Collecting information on the network interfaces

Since you will need to customize the `NetworkAttachmentDefinition` file for your gateway 
node's networking interface information, 
you need to collect information on your network interfaces. 
Find your gateway node IP addresses using `ifconfig` and note the IP address having the highest number as the last
character in its name.
For example, on my machine the first interface is named `enp0s3` while the second interface
is named `enp0s8`. The second interface will become part of the gateway pod.


### Manifests for deploying the vremote microservice with the fake driver 

The `vremote` microservice requires the following two manifests:

- `vremote-deploy.yml`: Creates a one pod `Deployment` of the `vremote` microservice, with a forwarding historian to send data to the Volttron Central pod historian, and an Actuator agent
to receive commands for the fake device. Edit the file and 
change the name of the `kubernetes.io/hostname` value to your gateway node hostname.

- `vremote-service.yml`: A `ClusterIP` type service for the `vremote` pod, 
with HTTP and VIP ports defined. 
There is no external IP definition for the `vremote` microservice,
since the `vremote` microservice is only accessed through the Volttron Central dashboard.

### BACnet NetworkAttachmentDefinition manifest for second gateway pod interface

The Kubernetes CNI handles additional pod interfaces though a 
`NetworkAttachmentDefinition` object. 
Multus requires a network attachment point definition to configure the `vbac` 
pod with the second interface. 
The file `bacnet-net-attach-def.yml` contains an attachment definition for the
gateway pod's second interface. Multus matches the value of the `NetworkAttachmentDefinition` 
`name` in the `metaData` section (`bacnet` in this case) with a configuration item in 
the bacnet `Deployment` pod spec for the second interface. The `config` value is a 
JSON object providing the configuration for the second interface.

### Configmap manifests for `vbac`

The Kubernetes `Configmap` object provides a way to inject configuration data into a 
container when a pod is deployed. 
Container images can be distributed without the final configuration in them, and 
then a customized configuration specific to the particular deployment environment 
can be injected when
the container is deployed.
Because Volttron was originally build around a monolithic architecture, the 
original volttron-docker repo does configuration by deploying all the agents into a 
container with all of their deployment environment configuration
in them when the container is built. Every Volttron deployment is built from scratch 
and configured on the machine where it will run. However, the
microservice-volttron distro has been engineered to allow redistributable containers. 

The two yaml files defining `Configmap` objects are:

- `bacnet-configmap.yml`: Creates a `Configmap` in the `vbac` container
`/home/volttron/configs/bacnet` 
directory with
two file "keys": `sim-AHU.config` and `sim-AHU.csv`. The first contains the IP address of the simulated
AHU device and other data for the BACnet driver, the second contains the simulated AHU device schema we
are interested in accessing. These files are only loaded by Volttron when it builds the `vbac` 
image, after that they are not accessed.

- `platform-driver-configmap.yml`: Contains exactly the same information as `bacnet-configmap.yml`, 
except it is placed into a directory where the Volttron build process squirrels away configuation 
data, `/home/volttron/.volttron/configuration_store`. The information is in a different format, basically
a consolidation of the `sim-AHU.config` and `sim-AHU.csv` files into a single JSON object. This is the
file that is loaded into the Platform Driver Agent BACnet driver when the `vbac` container boots.


### `Vbac` microservice manifests for BACnet devices

The `vbac` microservice with the gateway for the BACnet protocol consists of two 
manifests:

- `vbac-deploy.yml`: Creates a one pod `Deployment` of the `vbac` microservice
running the Volttron BACnet Proxy Agent, with a Forwarding Historian to send data to 
the Volttron Central pod historian database, and an Actuator agent to receive commands 
from Volttron Central. Edit the file and 
change the name of the `kubernetes.io/hostname` value to your gateway node hostname.

- `vbac-service.yml`: A `ClusterIP` type service for the `vbac` pod, with 
HTTP and VIP ports defined. There is no external IP definition for the 
`vbac` service, since the `vbac` service is accessed only through the Volttron 
Central Web UI.

### Deploying the `vremote` microservice pod

If you just want to try out kube-volttron, you can deploy the `vremote` pod with
the fake driver. First you need to deploy the `vremote` `Service`:

	kubectl apply -f vremote-service.yml
	
Then the `Deployment`:

	kubctl apply -f vremote-deploy.yml
	
Check if the pod is running with:

	kubectl get pods | grep vremote
	
If the pod is running, you should see something like:

	vremote-847b9686c4-wn8tz   1/1     Running   0             14s

You can check if the `vremote` fake device is visible in Volttron Central by bringing up
the Volttron Central dashboard in your browser, 
then clicking on *Platforms*. You should see a display like this:

![Volttron Central platforms display](image/vc-vremote-platforms.png)

Notice that the display says that 0 agents are running. This is because the dashboard
uses the process id of the agent process to determine if the agent is running, but
if the agent is running in a separate container on another machine as in kube-volttron, 
the process id is unavailable to the Volttron Central web app.

Clicking on *vremote* shows the agents running in the `vremote` microservice:

![Vremote agents running](image/vc-vremote-agents-running.png)

Go up to the menu bar in the upper right hand corner and click on *Charts*.
This will bring up a display where you can configure charts of data to display.
Click on the *Add Charts* button and the *Add Chart* dialog should come up. 
Click on the *Topics* pulldown list.
You should see a pulldown list of variables you can display (*OutsideAirTemperature1*, etc.).
If you'd like to display a chart, select the variable, then select the chart type 
in the *Chart Type* pulldown.

This should confirm that your `vremote` microservice pod is running and can connect 
to the `vcentral` pod running on the central node.

Be sure to remove the `vremote` `Deployment` before creating the `vbac` `Deployment`:

	kubectl delete deploy vremote
	
## Deploying the simulated BACnet AHU

The Python file `sim-AHU.py` is a copy of Ben Barting's simulated air handling unit, 
programmed on top of the
BAC0 package. On the gateway node, install the BAC0 package using `pip` 
(installing `pip` if it isn't already):

	pip install BAC0
	
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

Since the `vbac` container has the basic configuration for the simulated AHU baked
in, you will have to build another container with configuration if you
want to deploy BACnet with other devices. See the Volttron documentation pages
[here](https://volttron.readthedocs.io/en/main/driver-framework/bacnet/bacnet-auto-configuration.html) about the scripts you'll need to run to find BACnet
devices and generate configuration files for the Platform Driver Agent BACnet 
driver.

## Deploying the `vbac` pod

### Customizing the `bacnet` `NetworkAttachmentDefinition`

Edit the `bacnet-net-attach-def.yml` manifest to configure it to your network as follows:

- Find the name of the second interface on the gateway node by typing `ifconfig` or `ip address` 
to a `bash` shell. This is the interface with the
highest number as the last character in its name. 

- Edit the `bacnet-net-attach-def.yml` file and change the `"device"` 
property value, which is set to `"enp0s8"`, to the name of the second network 
interface on your host machine. This interface will get 
absorbed into the cluster network namespace and disappear from the
host network namespace when you deploy a pod with a
second interface.

### Customizing the Platform Driver Agent `ConfigMaps`

Edit the two `Configmap` files `bacnet-configmap.yml` and `platform-driver-configmap.yml` 
and
replace the IP address `192.168.0.122` with the IP address on which `sim-AHU.py` is running.

Create the two `Configmaps` using `kubectl`:

	kubectl apply -f bacnet-configmap.yml
	kubectl apply -f platform-driver-configmap.yml

You can check if the creation operation succeeded with:

	kubectl get configmap bacnet-config
	kubectl get configmap platform-driver-config

or print more detailed information using `kubectl describe`.

### Creating the `vbac` `Service` and the `NetworkAttachmentDefinition`

Before creating the `vbac` `Deployment`, you first need to create the `vbac` `Service` and the `bacnet` `NetworkAttachmentDefinition`.

Create the `vbac` `Service` as follows:

	kubectl apply -f vbac-service.yml
	
This creates a `ClusterIP` service for `vbac` on both the HTTP (port 8443) and the VIP bus (port 22916). 

Create the `bacnet` `NetworkAttachmentDefinition` as follows:

	kubectl apply -f bacnet-net-attach-def.yml
	
You can examine the `bacnet NetworkAttachmentDefinition` with:

	kubectl describe net-attach-def bacnet
	
### Creating the `vbac` `Deployment`

Create the `vbac` deployment as follows:

	kubectl apply -f vbac-deploy.yml
	
Use:

	kubectl get --watch pod
	
to watch the pods until the `vbac` pod is running. Note that the pod will have a uuid after the generic pod name "`vbac`".

### Check whether the deployment was successful from the Volttron Central web app

Using the Vottron Central web app, check whether the deployment was
successful by logging in and navigating to the *Platforms* page as described above. Click on *`vbac`*->*Charts*->*Add Chart*.
In the *Add Chart* dialog, click on the *Topics* pulldown and you should see a pulldown list as in the following display:

![`Vbac` topic list](image/vbac-topic-list.png)

Click on one of the topics then move down to the *Chart Type* pulldown list to add a chart. 

Here is an example of what charts look like:

![`Vbac` chart](image/vbac-charts.png)

Congratulations! You now have a Kubernetes cluster running with Volttron microservices!

## Troubleshooting

If you run into trouble deploying one of the microservice `Deployments`, you can use the `kubectl` log command to check the container logs:

	kubectl get pods
	kubectl logs <pod name>

If you are having problems with networking or service discovery, you can
troubleshoot by exec-ing into one of the pods and using the Ubuntu 
Linux networking tools. 

	kubectl exec -it <pod name> -- /bin/bash
	














