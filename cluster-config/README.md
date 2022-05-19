# Deploying a Kubernetes cluster for Volttron microservices

Kube-volttron uses [Wireguard VPN](https://www.wireguard.com/) 
for point to point encrypted communication
between the cloud VM and the on-site gateway nodes 
and [`kubeadm`](https://kubernetes.io/docs/reference/setup-tools/kubeadm/) 
to configure and administer the cluster. While there
are simpler Kubernetes distros to install, they generally are 
opinionated about networking in ways that make setting up and 
maintaining multi-interface pods difficult. These directions walk you 
through:

- Installing and configuring a Wireguard VPN running through a `wg0` 
interface on a central node running in a 
cloud VM and a local gateway node running in a VirtualBox VM located on
the site local area network. The node configurations generalize so that 
the local gateway node could be any device that can run Ubuntu or another Linux
variant, and the central node could be a VM running in an on prem 
data center, a VM on a laptop, or even a dedicated server. Both nodes
need internet connectivity.

- Installing Docker for the container runtime, the basic Kubernetes services
on both nodes and `kubeadm` on both nodes, and the Flannel and Multus CNI 
plugins on the central node. Flannel 
is used for the intra-cluster, pod-to-pod network, and Multus is used to
provide a second interface for pods running in the gateway nodes that 
have special networking needs, like, for example, using broadcast to discover
devices in the site's local area network. Pods can't access the site 
local network through Flannel.[^1]

- Creating a cluster with `kubeadm` with the gateway node is connected to the
central node and listed as a worker.

[^1] Some CNI plugins that do not use overlays ("flat" drivers) 
may allow broadcast and direct access to the host network, 
this is an area for future work.

## Installing and configuring the central and gateway base nodes with a Wireguard VPN.

### Installing and configuring the Volttron Central central node cloud VM.

The first step is to bring up a VM running Ubuntu 20.04 on your favorite cloud
provider (I used Azure) to act as a server. K3s installation requirements are 
listed 
[here](https://rancher.com/docs/k3s/latest/en/installation/installation-requirements/), for example, for a server node that can support up to 100 agent 
(worker) nodes, a
VM with 4 VCPUs and 8 GB RAM is recommended. After installing the VM, you should configure the network to open port 51820 for incoming traffic, since this
is the port Wireguard uses by default, in addition to port 22 for `ssh` access
Also, write down the public IP address assigned to the VM and reserve 
the address
so that the VM will get the same address every time it boots.

### Installing and configuring the gateway node

You will need a base VM or operating system with two 
network interfaces to support
a two interface gateway pod. How you configure an additional 
interface depends on what 
operating system and/or VM manager you are using. 
Kube-volttron was developed on 
Ubuntu 20.04 using the VirtualBox VMM, so the directions for adding an 
additional interface to a VirtualBox VM are explained in detail in the following subsections.

#### Clone a VM or import an ISO for a new one.
Clone an existing VM using VirtualBox by right clicking on the VM in the left side menu bar and choosing *Clone* from the VM menu. In the *MAC Address Policy* pulldown, scroll down to the setting *Generate new MAC addresses for all network adaptors*.

#### Bring up the Network Settings tab
Right click on the new VM in the left side menu bar of the VirtualBox app
to bring up the VM menu, then click on *Settings*. When
the *Settings* tab is up, click on *Network* in the left side menu bar. You should get a tab that looks like this:

![Network Settings tab](image/vb-net-settings.png)

Be sure your first interface is a *Bridged Adaptor* and not NAT or anything else

#### Configure the second interface

Click on the *Adaptor 2* tab then
click the check box marked *Enable Network Adaptor*. Select the 
*Bridged Adaptor* for the network type. Click on the *Advanced* arrow and make sure the *Cable Connected* 
checkbox is checked.

#### Save the configuration

Save the configuration by clicking on the *OK* button on the bottom right.

Your VM should be ready to run.

### Preinstallation host config, node uniqueness check, and routing configuration

Prior to installing Wireguard and k3s, be sure to set the hostname on both
nodes:

	hostnamectl set-hostname <new-hostname>
	
and confirm the change with:

	hostnamectl

You should not have to reboot the node to have the hostname change take
effect.

Kubenetes uses the hardware MAC addresses and machine id to identify
pods. Use the following to ensure that the two nodes have unique 
MAC addresses and machine ids:

- Get the MAC address of the network interfaces using the command `ip link` or `ifconfig -a`,
- Check the product\_uuid cby using the command `sudo cat /sys/class/dmi/id/product_uuid`.

Kubernetes also needs specific ports to be free, see [here](https://kubernetes.io/docs/reference/ports-and-protocols/) for list. You can check which ports are
being used with:

	sudo ss -lntp
	
Finally, we need to enable routing on both nodes by editing
`/etc/sysctl.conf` as root
and uncommenting `net.ipv4.ip_forward=1` and 
`net.ipv6.conf.all.forwarding=1` to enable routing on the host after reboot, if they aren't already.
Then use the command:

	sudo sysctl <routing variable>=1

where `<routing variable>` is  `net.ipv4.ip_forward` and `net.ipv6.conf.all.forwarding` to enable routing 
in the running host.

You can test whether your configuration has worked by running:

	sudo sysctl -a | grep <routing variable>

### Installing and configuring the Wireguard VPN

Most of the pages with instructions for installing and configuring 
Wireguard on the 
Ubuntu 20.04 assume you want to deploy it as a VPN server and route through it 
to other
services, in order to hide your local machine's or mobile phone's IP address.
The result is that the web pages include instructions for configuring iptables
to route packets out of the VM, which are completely unnecessary for the
kube-volttron use case. 
Kube-volttron doesn't need this, since the only service the gateway nodes
will be accessing is the Volttron Central service running on the cloud VM. 
The best guide I've found is at [this link](https://www.digitalocean.com/community/tutorials/how-to-set-up-wireguard-on-ubuntu-20-04). The author notes 
where you can skip configuration instructions for deploying Wireguard as 
a VPN server, and includes instructions for configuring with IPv6 which
are nice if you have IPv6 available but only increase the complexity. Below,
I've summarized the instructions for installing and configurating Wireguard
specifically for the kube-volttron use case using IPv4.

Note that these instructions work best if you have a VM or bare metal device running Ubuntu 20.4 as your gateway node
from which you can work back into the cloud using `ssh`. You can 
open one window and `ssh` into your cloud VM and have the other on the gateway 
machine. Both sides need to have Wireguard installed and configured.

#### Installing Wireguard and related packages

Update/upgrade on both the gateway node and VM with:

	sudo apt update
	sudo apt upgrade
	
After the upgrade is complete, install Wireguard:

	sudo apt install wiregard

`apt` will suggest you install one of `openresolv` or `resolvconf`, the
following instructions are based on installing `resolvconf`:

	sudo apt install resolveconf
	
You should also install your favorite editor on the cloud VM if it isn't there, and packages containing network debugging tools including `net-tools` and `inetutils-traceroute` (for `ifconfig` and `traceroute`) just in case you need them.

#### Configuring the Wireguard VPN

Wireguard creates a virtual interface on a node across which runs a UDP VPN 
to other
peers. The interface has a public and private key associated with it that
is used for encrypting the packets. The link between one peer and another 
is point to point. Wireguard comes with two utilities:

- `wg`: the full command line utility for setting up a wireguard interface.

- `wg-quick`: a simpler command line utility that summarizes frequently used collections of command parameters under a single command. 

The configuration file for the Wireguard interface is kept in the directory
`/etc/wireguard`. 

#### Generating public and private keys for the interface.

Starting on your gateway node, generate a private and public key using the 
Wireguard `wg` command line utility:

	wg genkey | sudo tee /etc/wireguard/private.key
	sudo chmod go= /etc/wireguard/private.key

The first command generates a base64 encoded key and echos it to 
`/etc/wireguard/private.key` and to the terminal, the second changes 
the permissions so
nobody except root can look at it.

Next, generate a public key from the private key as follows:

	sudo cat /etc/wireguard/private.key | wg pubkey | sudo tee /etc/wireguard/public.key
	
This command first writes the private key from the file to `stdout`, then generates the public key with `wg pubkey`, then writes the public key to 
`/etc/wireguard/public.key` and to the terminal. 

After you've created the keys on your cloud VM, repeat the above instructions
on your gateway node.

#### Choosing an IP address range for you VPN subnet

The next step is to choose an IP address range for the VPN subnet on which
your gateway nodes will run. You have a choice of three different ranges 
having the following CIDRs:

    10.0.0.0/8
    172.16.0.0/12
    192.168.0.0/16
	
Since Docker tends to use the 172 range and many internal networks use the
192 range, for most purposes, the 10 range is best as it has the most
number of addresses available.

Assuming you choose that, you then need to choose a subnet range. We'll use
`10.8.0.0/24`, with the cloud VM server 
having address `10.8.0.1` and the first
gateway node having `10.8.0.2`. Note that these addresses are only
the address of the Wireguard point to point VPN interface, and have nothing
to do with the IP addresses of other interfaces in your gateway node or 
cloud VM.

#### Creating the wg0 interface configuration file.

The next step is to create a configuration file for the two peers (cloud 
VM and gateway node). First, we'll do the cloud VM.

Using your favorite editor, open a new file in `/etc/wireguard` (running as sudo) called `wg0.conf`. Edit the file to insert the following configuration:

	[Interface]
	PrivateKey = <insert private key of cloud VM here>
	Address = 10.8.0.1/24
	ListenPort = 51820
	SaveConfig = true

	[Peer]
	PublicKey = <insert public key of gateway node here>
	Endpoint = <public IP address of gateway VM>:51820
	AllowedIPs = 10.8.0.0/24
	PersistentKeepAlive = 21

Most gateway nodes will run behind an ISP firewall and router, and the nodes'
IP addresses will be in one of the private IP subnets described above. 
You can find
your gateway node's public IP address by browsing
[here](https://whatsmyip.org.) from the gateway node. Be sure to 
also include the private key of the cloud VM and public
key of the gateway node where indicated. 

After you have completed editing the configuration file on the cloud VM, you
should create one on the gateway node as `/etc/wireguard/wg0`:

	[Interface]
	PrivateKey = <insert private key of gateway node here>
	Address = 10.8.0.2/24
	ListenPort = 51820
	SaveConfig = true

	[Peer]
	PublicKey = <insert public key of cloud VM here>
	Endpoint = <public IP address of cloud VM>:51820
	AllowedIPs = 10.8.0.0/24
	PersistentKeepAlive = 21

using the public IP address of the cloud VM you wrote down when you created
the VM in the first step. Be sure to add the 
gateway node private key and cloud VM public key at the indicated spots.

#### Creating the `wg0` interface and installing a system service

Now with the configuration complete, you can create the wg0 interface
and install a system service so it is recreated when your VM and gateway
node reboot. 

The one time command for enabling the interface is:

	sudo wg-quick up

This will create a virtual interface for each configuration file in
`/etc/wireguard` and configure it to route addresses in the allowed
range over the VPN.

To enable a system service, use:

	sudo systemctl enable wg-quick@wg0.service
	
then:

	sudo systemctl start wg-quick@wg0.service

to start the service, and:

	sudo systemctl status wg-quick@wg0.service

to see the service status. Note that the status output will show all the
`ip` commands used to create and configure the `wg0` interface. 

#### Configuring additional gateway nodes.

To configure additional gateway nodes, install Wireguard on the node and 
generate
a public and private key as described above. Then select an IP address
for the gateway node `wg0` interface in the `10.8.0.0/24` range, incrementing
the last number by one each time you configure a new node. You can
have a maximum of 254 gateway nodes on the VPN. Create a 
configuration file for `wg0` in `/etc/wireguard/wg0.conf`, being sure
to add the appropriate keys and IP address as described above. You can copy
the file above and change the configuration key values as appropriate.

Once you have the new gateway configured, you should add an additional
`Peer` section to the `/etc/wireguard/wg0.conf` file on the cloud VM server.
If the
new gateway is at a different site, likely the `Endpoint` field will 
change because the site's Internet gateway will have a different public
IP address. Also, you should put the new gateway's public key into the
`PublicKey` field. The other fields should remain the same.

After the new gateway and server have been reconfigured, restart
the `wg0` interface on the server by:

	ip link delete wg0
	wg-quick up
	
and:

	systemctl disable wg-quick@wg0.service
	systemctl enable wg-quick@wg0.service

Also start up the interface on the new gateway using 
the commands in the previous section.

## Installing Docker and the Kubernetes services on both nodes and the CNI plugins on the central node

These instructions are a condensation of the `kubeadm` installation
instructions [here](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/).

First check if Docker is installed and running on your node 
with the following commands:

	systemctl status docker.service
	systemctl status docker.socket

If these indicate that Docker is running, then skip this section.

### Installing the Docker container runtime and `cri-dockerd`

Until recently, Docker was tightly integrated with Kubernetes but that 
changed somewhere around Release 1.21. The newer releases support multiple
container runtimes, but since the microservice-volttron containers 
used in the deployments were developed on Docker, we'll use that to
avoid potential incompatibility problems. 

Installing Docker Engine from the default Ubuntu repo if it isn't already is
recommended. The following steps outline the procedure,
and must be followed on both nodes. Make sure you have
access to the Docker repo first by running:

	apt policy | grep docker

You should see:

	500 https://download.docker.com/linux/ubuntu focal/stable amd64 Packages
		origin download.docker.com

If nothing shows up, follow the steps  [here](https://docs.docker.com/engine/install/ubuntu/) which include installing access to the repo.

You will also need to install `cri-docker` which replaces `dockershim`, 
instructions are after the Docker install.

#### Install prerequisites

Update the apt package index and install packages to allow apt to use a repository over HTTPS:

	sudo apt update
	sudo apt install \
		ca-certificates \
		curl \
		gnupg \
		lsb-release
		
#### Install Docker Engine 

Update the package index, and install the latest version of Docker Engine, the Docker CLI, containerd:

	sudo apt update
	sudo apt install docker-ce docker-ce-cli containerd.io
	
#### Installing `cri-dockerd`

Instructions for installing `cri-dockerd` are located [here](https://computingforgeeks.com/install-mirantis-cri-dockerd-as-docker-engine-shim-for-kubernetes/). Although the instructions are complete, they apply to several Linux distros
so we condense below for Ubuntu. Note that `cri-dockerd` must be 
installed after Docker Engine.

##### Ensure you have `wget` and `curl`

Run the following to ensure you have these utilities:

	sudo apt update
	sudo apt install git wget curl
	
##### Get the latest version and download `cri-dockerd`

For the latest version:

	VER=$(curl -s https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest|grep tag_name | cut -d '"' -f 4)
	echo $VER

If you are not in the `cluster-config` directory, change to it and run
the following commands:

	wget https://github.com/Mirantis/cri-dockerd/releases/download/${VER}/cri-dockerd-${VER}-linux-amd64.tar.gz
	tar xvf cri-dockerd-${VER}-linux-amd64.tar.gz
	
Now move `cri-dockerd` to `/usr/local/bin` and check the version:

	sudo mv cri-dockerd /usr/local/bin/
	cri-dockerd --version

##### Set up a `cri-dockerd` service

Run the following commands to download the configuration files for `systemctl`, edit the service config file, and put the config files into the right place:

	wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.service
	wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.socket
	sudo mv cri-docker.socket cri-docker.service /etc/systemd/system/
	sudo sed -i -e 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,' /etc/systemd/system/cri-docker.service
	
##### Adding your user to the `docker` group

In order to use the Docker CLI as a user, you need to add your username to
the `docker` group:

	sudo usermod -aG docker $USER
	newgrp docker
	
##### Start the socket and service and confirm the socket is running

Run the following commands to start the service and socker:

	sudo systemctl daemon-reload
	sudo systemctl enable cri-docker.service
	sudo systemctl enable --now cri-docker.socket
	
Run the following commands to check whether the socker is running:

	systemctl status cri-docker.socket

Ensure that the Docker socket is where `kubadm` expects it to be:

	sudo ls -l /var/run/cri-dockerd.sock

### Installing the Kubernetes services and `kubeadm`

First, turn off swap on both nodes. `kubeadm` used to not work if swap was 
on but now it issues a warning:

	sudo swapoff -a
	sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

The next step is to install `kubeadm`, `kubelet`, and `kubectl` on both
nodes. First check whether you already have access to the repository with:

	sudo apt policy | grep kubernetes
	
If you see something like:

	500 https://apt.kubernetes.io kubernetes-xenial/main amd64 Packages
     release o=kubernetes-xenial,a=kubernetes-xenial,n=kubernetes-xenial,l=kubernetes-xenial,c=main,b=amd64
     origin apt.kubernetes.io

If not, then do the following:

- Update the apt package index and install packages needed to use the Kubernetes apt repository:

	`sudo apt-get update
	sudo apt-get install -y apt-transport-https ca-certificates curl`

- Download the Google Cloud public signing key:

	`sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg`

- Add the Kubernetes apt repository:

	`echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list`
	
To install the Kubernetes utilities type the following commands:

	sudo apt-get update
	sudo apt-get install -y kubelet kubeadm kubectl
	sudo apt-mark hold kubelet kubeadm kubectl

This installs `kubelet` as a systemd service. 

## Creating a cluster with `kubedm`

#### Configuring the central node as the control node

First step is to run `kubeadm` with arguments specific to central node
host. The following arguments need to be set:

- Since we are using Flannel, we need to reserve the pod CIDR using the 
following argument `--pod-network-cidr=10.244.0.0/16`. This reserves
IP address space for the inter-pod, intra-cluster network.

- We need to advertise the API server on the `wg0` interface so all
traffic between the API server and the gateway nodes is encrypted.
If you followed the Wireguard numbering scheme above, 
then use `--apiserver-advertise-address=10.8.0.1`, otherwise,
substitute the address you assigned to the `wg0` interface.

- We want to have the control plane node advertised with an address
accessable on the local network. Use the address assigned to the
interface with the lowest number in its name, i.e. if you have two
interfaces, one named `enp0s3` and `enp0s8`, use the address assigned to
the former with `--control-plane-endpoint=<central node address>`. 
You can use `ifconfig` to find the address.

-- The Docker socket needs to be specified using the argument 
`--cri-socket=unix:///var/run/cri-dockerd.sock`

Run `kubeadm init` on the central node:

	sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=10.8.0.1 --control-plane-endpoint=<central node address> --cri-socket=unix:///var/run/cri-dockerd.sock
	
When `kubeadm` is finished, it will print out:

Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

	mkdir -p $HOME/.kube
	sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	sudo chown $(id -u):$(id -g) $HOME/.kube/config

	You should now deploy a Pod network to the cluster.
	Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
	/docs/concepts/cluster-administration/addons/

	You can now join any number of machines by running the following on each node
	as root:

	kubeadm join <control-plane-host>:<control-plane-port> --token <token> --discovery-token-ca-cert-hash sha256:<hash>

Copy down the final `kubeadm join` command since we will use this shortly to
join the gateway node to the central node control plane.

To run `kubectl` as a nonroot user, do the following:

	mkdir -p $HOME/.kube
	sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	sudo chown $(id -u):$(id -g) $HOME/.kube/config

#### Installing the CNI networking plugins on the central node

The following steps should be done on the central control node _only_.

To install Flannel:

	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
	
To install Multus, first clone the Multus git repo:

	git clone https://github.com/k8snetworkplumbingwg/multus-cni
	
Then change into the `multus-cni` directory apply the yaml manifest:

	cat ./deployments/multus-daemonset-thick-plugin.yml | kubectl apply -f -
	
You can check if Flannel and Multus are running with:

	ku get -n kube-system pods | grep flannel

which should print:

	kube-flannel-ds-t5k5b                 1/1     Running   0          8m6s
	
And:

	ku get -n kube-system pods | grep multus

which should print:

	kube-multus-ds-r9mg8                  1/1     Running   0          2m41s
	
#### Configuring the gateway node as a worker node

To join the gateway node to the cluster as a worker node, use the
`kubeadm join` command that `kubadm init` printed out just before
it finished adding on the argument for the CRI socket, [^2] for example:

	sudo kubeadm join 192.168.0.129:6443 --token 05zqtn.bc8odaj6kpnfyq00 \
	--discovery-token-ca-cert-hash sha256:8a830ba4c49281a2baa4cf9368b78d132bcb6cb85272d3a8e1780d023e9556a5 --cri-socket=unix:///var/run/cri-dockerd.sock
	
The token is only good for a day, if you need to install more gateway nodes,
use this command on the control node to create a new one:

	kubeadm token create

If you don't have the value of `--discovery-token-ca-cert-hash` you can find by running this command on the control node:

	openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | \
	openssl dgst -sha256 -hex | sed 's/^.* //'

	
Finally, to use `kubectl` on the gateway node to deploy pods, you need
to copy the config file over from the control node to the gateway node. 
You should use `scp` on the gateway node: 

	scp $USER@<control-plane-host>:/home/$USER/.kube/config .

Also copy the file into `/etc/kubernetes/admin.conf` as root so
other users have access to it.
	
Check if everything is running OK by running `kubectl` on the gateway:

	kubectl get -n kube-system pods

which should print something like:

	NAME                                  READY   STATUS    RESTARTS   AGE
	coredns-6d4b75cb6d-qcgpd              1/1     Running   0          48m
	coredns-6d4b75cb6d-skwnc              1/1     Running   0          48m
	etcd-k3s-central                      1/1     Running   0          48m
	kube-apiserver-k3s-central            1/1     Running   0          48m
	kube-controller-manager-k3s-central   1/1     Running   0          48m
	kube-flannel-ds-pm5q9                 1/1     Running   0          10m
	kube-flannel-ds-t5k5b                 1/1     Running   0          34m
	kube-multus-ds-2x52l                  1/1     Running   0          10m
	kube-multus-ds-r9mg8                  1/1     Running   0          28m
	kube-proxy-5294k                      1/1     Running   0          48m
	kube-proxy-vrz9h                      1/1     Running   0          10m
	kube-scheduler-k3s-central            1/1     Running   0          48m

[^2] If `kubeadm init` prints out a bogus argument, 
`--control-plane` as the 
last argument, ignore it, it's a bug. You've already specified the 
control plane node in the second argument. Don't include it in the
`kubeadm join` command.

#### Deploying the CNI DHCP relay

Multus requires IP address management (ipam) to be specified for the second
interface in pods. The yaml manifest for deploying the 
BACnet gateway pod on the gateway node
uses DHCP for ipam to obtain an address on the site local network. 
The CNI DHCP relay must be running
on the node (not in the Kubernetes cluster) to connect with the local
subnet DHCP server. This section describes how to deploy the CNI DHCP
relay as a `systemctl` service so the relay is restarted when the node
reboots. Although we only need an address on the gateway site network,
we install the relay on both the central node and gateway node, in case
a central node pod also needs an address on the local network.

The first step is to copy the shell script 
`cleanstart-cni-dhcpd.sh`, which cleans up any old sockets and starts the daemon, to `/usr/local/bin`:

	sudo cp cleanstart-cni-dhcpd.sh /usr/local/bin

Then change the permissions on `/run/cni` so the daemon can access it:

	sudo chmod a+rx /run/cni

The next step is to create a `systemctl` unit for the service and enable and start it, which starts the daemon, as follows:

	sudo cp cni-dhcpd-relay.service /lib/systemd/system
	sudo systemctl daemon-reload
	sudo systemctl enable cni-dhcpd-relay.service
	
After the last command, you should see the following output:

	Created symlink /etc/systemd/system/multi-user.target.wants/cni-dhcpd-relay.service → /lib/systemd/system/cni-dhcpd-relay.service.
	
Then start the service:

	sudo systemctl start cni-dhcpd-relay.service
	
You can check on the status of the service with:

	sudo systemctl status cni-dhcpd-relay.service
	
which should print out something like this:

	● cni-dhcpd-relay.service - CNI DHCP Relay Daemon
		Loaded: loaded (/lib/systemd/system/cni-dhcpd-relay.service; enabled; vendor preset: enabled)
		Active: active (running) since Wed 2022-05-11 19:10:46 PDT; 7s ago
		Main PID: 83307 (dhcp)
			Tasks: 5 (limit: 9459)
		Memory: 956.0K
		CGroup: /system.slice/cni-dhcpd-relay.service
			    └─83307 /opt/cni/bin/dhcp daemon

	May 11 19:10:46 gateway-node systemd[1]: Started CNI DHCP Relay Daemon.
	May 11 19:10:46 gateway-node cleanstart-cni-dhcpd.sh[83308]: ++ ls -A /run/cni
	May 11 19:10:46 gateway-node cleanstart-cni-dhcpd.sh[83307]: + '[' -z dhcp.sock ']'
	May 11 19:10:46 gateway-node cleanstart-cni-dhcpd.sh[83307]: + rm -rf /run/cni/dhcp.sock
	May 11 19:10:46 gateway-node cleanstart-cni-dhcpd.sh[83307]: + exec /opt/cni/bin/dhcp daemon
	
You can double check whether the damon started by typing:

	ps -aux | grep dhcp
	
which should print out something like this:

	root       83307  0.0  0.0 110288  6540 ?        Ssl  19:10   0:00 /opt/cni/bin/dhcp daemon





	

	









	







