# Deploying a Kubernetes cluster for Volttron microservices

Kube-volttron uses [Wireguard VPN](https://www.wireguard.com/) 
for point to point encrypted communication
between the central node VM and the gateway node
and [`kubeadm`](https://kubernetes.io/docs/reference/setup-tools/kubeadm/) 
to configure and administer the cluster. While there
are simpler Kubernetes distros to install, they generally are 
opinionated about networking in ways that make setting up and 
maintaining multi-interface pods difficult. These directions walk you 
through:

- Installing and configuring a Wireguard VPN running through a `wg0` 
interface on a central node and a gateway node VM. 

- Installing and configuring the basic Kubernetes services
on both nodes and `kubeadm` on both nodes, and the Flannel and Multus CNI 
plugins on the central node. Flannel 
is used for the intra-cluster, pod-to-pod network, and Multus is used to
provide a second interface for pods running in the gateway nodes that 
have special networking needs, like, for example, using broadcast to discover
devices in the site's local area network. Pods can't access the site 
local network through Flannel.[^1]

- Creating a cluster with `kubeadm` in which the gateway node is 
connected to the central node and listed as a worker.

The instructions were developed on a configuration consisting of
VirtualBox on an Ubuntu 20.04 host, with two Ubuntu 20.04 VMs on the same host, one for the central node and one for the 
gateway node. It will also probably work for two bare metal hosts or two VMs
running in the local network. 
If you try a cloud VM, since
the Volttron Central dashboard is exposed in by using the `externalIPs` 
key in the `vcentral-service.yml`, it will run afoul of the cloud
virtual networking. You will need to set up a load balancer with the 
cloud provider and expose the `vcentral` service as a `LoadBalancer` 
service.

[^1] Some CNI plugins that do not use overlays ("flat" drivers) 
may allow broadcast and direct access to the host network, 
this is an area for future work.

## Installing and configuring the central and gateway base nodes with a Wireguard VPN.

### Installing and configuring the central node.

The first step is to bring up a VM running Ubuntu 20.04 on a VirtualBox VM.
A central node VM
with 2 VCPUs and 4 GB RAM is recommended. After installing the VM, you should configure the network to open port 51820 for incoming traffic if necessary, 
since this
is the port Wireguard uses, in addition to port 22 for `ssh` access
Also, write down the public IP address assigned to the VM and reserve 
the address if necessary
so that the VM will get the same address every time it boots. If you are
using a VirtualBox VM for both your central node and gateway node, you
should follow the directions in the next section for creating a central 
node.

### Installing and configuring a VirtualBox VM

You will need a base VM or operating system with one interface for the 
central node and two 
network interfaces to support
a two interface gateway pod. How you configure an additional 
interface depends on what 
operating system and/or VM manager you are using. 
Kube-volttron was developed on 
Ubuntu 20.04 using the VirtualBox VMM. 

The next sections 
describe how to create a VM on VirtualBox. If you are using a VM for
both your central node and gateway node, you should follow the directions
in these sections twice.

#### Clone a VM or import an ISO for a new one.
Clone an existing VM using VirtualBox by right clicking on the VM in the left side menu bar and choosing *Clone* from the VM menu. The VM should have
the same memory and disk as for the central node.
In the *MAC Address Policy* pulldown, scroll down to the setting *Generate new MAC addresses for all network adaptors*. It is important that each VM
have a unique MAC address because Kubernetes uses the MAC address as part
of its algorithm to name pods.

#### Bring up the Network Settings tab
After the clone finishes, 
right click on the new VM in the left side menu bar of the VirtualBox app
to bring up the VM menu, then click on *Settings*. When
the *Settings* tab is up, click on *Network* in the left side menu bar. You should get a tab that looks like this:

![Network Settings tab](image/vb-net-settings.png)

Set your first interface to *Bridged Adaptor*.

#### Configure the second interface on the gateway node

Click on the *Adaptor 2* tab then
click the check box marked *Enable Network Adaptor*. Select the 
*Bridged Adaptor* for the network type. Click on the *Advanced* arrow and make sure the *Cable Connected* 
checkbox is checked. 

#### Save the configuration

Save the configuration by clicking on the *OK* button on the bottom right.

Start the gateway node VM  by bringing up the VM menu again and clicking
on *Start*->*Normal Start* to start the gateway node VM.

### Preinstallation host config, node uniqueness check, and routing configuration

Prior to installing Wireguard, be sure to set the hostname on both
nodes:

	hostnamectl set-hostname <new-hostname>
	
and confirm the change with:

	hostnamectl

I named my central node `central-node` and my gateway node `gateway-node`.
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
will be accessing is the Volttron Central service running on the central node. 
The best guide I've found is at [this link](https://www.digitalocean.com/community/tutorials/how-to-set-up-wireguard-on-ubuntu-20-04). The author notes 
where you can skip configuration instructions for deploying Wireguard as 
a VPN server, and includes instructions for configuring with IPv6 which
are nice if you have IPv6 available but only increase the complexity. Below,
I've summarized the instructions for installing and configurating Wireguard
specifically for the kube-volttron use case using IPv4.

#### Installing Wireguard and related packages

Update/upgrade on both the gateway node and central node with:

	sudo apt update
	
After the update is complete, install Wireguard:

	sudo apt install wireguard

`apt` will suggest you install one of `openresolv` or `resolvconf`, the
following instructions are based on installing `resolvconf`:

	sudo apt install resolvconf
	
You should also install your favorite editor if it isn't there, and packages containing network debugging tools including `net-tools` and `inetutils-traceroute` (for `ifconfig` and `traceroute`) just in case you need them.

#### Configuring the Wireguard VPN

Wireguard creates a virtual interface on a node called the server
across which a UDP VPN to other
peers. The interface has a public and private key associated with it that
is used for encrypting the packets. The link between one peer and another 
is point to point. Wireguard comes with two utilities:

- `wg`: the full command line utility for setting up a Wireguard interface.

- `wg-quick`: a simpler command line utility that summarizes frequently 
used collections of command arguments under a single command. 

The configuration file and public and private key files for the 
Wireguard are kept in the directory
`/etc/wireguard`. 

#### Configuring the central node as a Wireguard server

##### Generating public and private keys 

Starting on your central node, generate a private and public key using the 
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

##### Choosing an IP address range for your VPN subnet

The next step is to choose an IP address range for the VPN subnet on which
your gateway nodes will run. You have a choice of three different ranges 
having the following CIDRs:

    10.0.0.0/8
    172.16.0.0/12
    192.168.0.0/16
                                                                                                     	
We'll use `10.8.0.0/24`, with the central node server 
having address `10.8.0.1` and the first
gateway node having `10.8.0.2`. Note that these addresses are only
the address of the Wireguard point to point VPN interface, and have nothing
to do with the IP addresses of other interfaces in your gateway node or 
central node.

##### Creating the `wg0` interface configuration file on the central node

The next step is to create a configuration file for the central node
which acts as the Wireguard server. 
Using your favorite editor, open a new file `/etc/wireguard/wg0.conf` 
(running as `sudo`). Edit the file to insert the following configuration:

	[Interface]
	PrivateKey = <insert private key of central node here>
	Address = 10.8.0.1/24
	ListenPort = 51820
	SaveConfig = true

Save the file and exit the editor.

##### Installing a system service for the `wg0` interface

We'll use `systemctl` to create a service that creates and configures
the Wireguard `wg0` interface when the node boots. To enable a system 
service, use:

	sudo systemctl enable wg-quick@wg0.service
	
start the service with:

	sudo systemctl start wg-quick@wg0.service
	
and check on it with:

	sudo systemctl status wg-quick@wg0.service

to see the service status. This should show something like:

	 wg-quick@wg0.service - WireGuard via wg-quick(8) for wg0
     Loaded: loaded (/lib/systemd/system/wg-quick@.service; enabled; vendor preset: enabled)
     Active: active (exited) since Fri 2022-05-20 15:17:27 PDT; 12s ago
       Docs: man:wg-quick(8)
             man:wg(8)
             https://www.wireguard.com/
             https://www.wireguard.com/quickstart/
             https://git.zx2c4.com/wireguard-tools/about/src/man/wg-quick.8
             https://git.zx2c4.com/wireguard-tools/about/src/man/wg.8
    Process: 2904 ExecStart=/usr/bin/wg-quick up wg0 (code=exited, status=0/SUCCESS)
	Main PID: 2904 (code=exited, status=0/SUCCESS)

	May 20 15:17:27 central-node systemd[1]: Starting WireGuard via wg-quick(8) for wg0...
	May 20 15:17:27 central-node wg-quick[2904]: [#] ip link add wg0 type wireguard
	May 20 15:17:27 central-node wg-quick[2904]: [#] wg setconf wg0 /dev/fd/63
	May 20 15:17:27 central-node wg-quick[2904]: [#] ip -4 address add 10.8.0.1/24 dev wg0
	May 20 15:17:27 central-node wg-quick[2904]: [#] ip link set mtu 1420 up dev wg0
	May 20 15:17:27 central-node systemd[1]: Finished WireGuard via wg-quick(8) for wg0.
	
Notice that the status prints out the `ip` commands that were used to
create the interface.

#### Configuring the gateway node as a Wireguard peer

Next, we'll configure Wireguard on the gateway node. 

##### Generating the public and private keys on the gateway node

Follow the directions in the section above about how to generate the
keys on the central node.

##### Creating the `wg0` interface configuration file on the gateway node

As on the central node, edit the file `/etc/wireguard/wg0.conf`:

	[Interface]
	PrivateKey = <insert gateway node private key here>
	Address = 10.8.0.2/24

	[Peer]
	PublicKey = <insert central node public key here>
	AllowedIPs = 10.8.0.0/24
	Endpoint = <insert public IP address of your central node here>:51820
	PersistentKeepalive = 21

Add the private key of the gateway node, public key of the central node,
and public IP address of the central node where indicated. The public
IP address could also just be a DHCP address on the local subnet if
you are using a local VM for the central node. Save the file and exit the editor.

#### Adding the gateway node public key to the central node `wg0` interface

On the central node, run the following command:

	sudo wg set wg0 peer <insert gateway node public key here> allowed-ips 10.8.0.0/24
	
This enables the VPN to run any IP address in the `10.8.0.x` range, in
case you want to add additional gateway nodes.

Check the status of the tunnel:

	sudo wg
	
	interface: wg0
	public key: EpaLTQqJTCvpf4cUMcFNWjy8BGszKwaGGHRIN0dCrEM=
	private key: (hidden)
	listening port: 51820

	peer: j6wKBbuAFxwELVBgW+brAMDyWZ3JUseVcP+i+3IN2W8=
		allowed ips: 10.8.0.0/24
		
#### Connecting the gateway node to the tunnel

Follow the same steps as in the section on installing a system service on 
the central node to start the system service on the gateway.

#### Checking for bidirectional connectivity

Check for bidirectional connectivity by pinging first on the central node:

	ping 10.8.0.2
	
then on the gateway node:

	ping 10.8.0.1

#### Configuring additional gateway nodes.

To configure additional gateway nodes, install Wireguard on the node and 
generate
a public and private key as described above. Then select an IP address
for the gateway node `wg0` interface in the `10.8.0.0/24` range, incrementing
the last number by one each time you configure a new node. You can
have a maximum of 254 gateway nodes on the VPN. Create a 
configuration file for `wg0` in `/etc/wireguard/wg0.conf` on
the gateway node, being sure
to add the appropriate keys and IP address as described above. You can copy
the file above and change the configuration key values as appropriate. Use
the `systemctl` commands above for starting the Wireguard service on the new 
gateway node.

You should not need to configure the central node as it should recognize IP
addresses in the `10.8.0.0/24` range. Test the configuration with `ping`.

## Creating the Kubenetes cluster

These instructions are a condensation of the `kubeadm` installation
instructions [here](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/) and cluster configuration instructions
[here](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)

### Preparing the operating system on both nodes

First, turn off swap:

	sudo swapoff -a
	sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
	
Next, enable the bridge net filter driver `br_netfilter`:

	sudo modprobe br_netfilter

### Installing the `containerd` container runtime and configuring a system service

Instructions for installing the latest version of `containerd` and 
configuring can be found 
[here](https://github.com/containerd/containerd/blob/main/docs/getting-started.md),
but they are slightly different for Ubuntu 20.04, so we use the easier
path of installing the `apt` package:

	sudo apt install containerd
	
This will install the package and configure and a `systemd` service
with properly formatted unit file, start the service, and
install a container runtime socket in the right place, which has the
added advantage of installing the default `systemd` 
[cgroup driver](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/configure-cgroup-driver/).

### Installing the Kubernetes services and `kubeadm`

#### Check whether the nodes have the Kubernetes `apt` repo.

The next step is to install `kubeadm`, `kubelet`, and `kubectl` on both
nodes. First check whether you already have access to the repository with:

	sudo apt policy | grep kubernetes
	
If you see something like:

	500 https://apt.kubernetes.io kubernetes-xenial/main amd64 Packages
     release o=kubernetes-xenial,a=kubernetes-xenial,n=kubernetes-xenial,l=kubernetes-xenial,c=main,b=amd64
     origin apt.kubernetes.io

Skip forward to the next section. If not, then do the following.

Update the apt package index and install packages needed to use the Kubernetes apt repository:

	sudo apt-get update
	sudo apt-get install -y apt-transport-https ca-certificates curl

Download the Google Cloud public signing key:

	sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg

Add the Kubernetes apt repository:

	echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
	
#### Installing the Kubernetes system utilities

To install the Kubernetes utilities type the following commands:

	sudo apt-get update
	sudo apt-get install -y kubelet kubeadm kubectl
	sudo apt-mark hold kubelet kubeadm kubectl

This installs `kubelet` as a systemd service and marks the Kubernetes 
utilites so that they are not automatically updated.

## Creating a cluster with `kubedm`

#### Configuring the central node as the control node

First step is to run `kubeadm` with arguments specific to central node
host on the central node. The following arguments need to be set:

- Since we are using Flannel, we need to reserve the pod CIDR using 
`--pod-network-cidr=10.244.0.0/16`. This reserves
IP address space for the inter-pod, intra-cluster network.

- We need to advertise the API server and the central node
on the `wg0` interface so all
traffic between the central node 
and the gateway nodes is encrypted.
If you followed the Wireguard numbering scheme above, 
then use `--apiserver-advertise-address=10.8.0.1` 
`--control-plane-endpoint=10.8.0.1`, otherwise,
substitute the address you assigned to the `wg0` interface on the control
node.

-- The `containerd` socket should be specified using the argument 
`--cri-socket=unix:///var/run/containerd/containerd.sock` in case
there are any other container runtime sockets lying about.

Run `kubeadm init` on the central node:

	sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=10.8.0.1 --control-plane-endpoint=10.8.0.1 --cri-socket=unix:///var/run/containerd/containerd.sock
	
When `kubeadm` is finished, it will print out:

	Your Kubernetes control-plane has initialized successfully!
	
	You should now deploy a Pod network to the cluster.
	Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
	/docs/concepts/cluster-administration/addons/

	You can now join any number of machines by running the following on each node
	as root:

	kubeadm join <control-plane-host>:<control-plane-port> --token <token> --discovery-token-ca-cert-hash sha256:<hash>


To start using your cluster as a nonroot user, 
you need to run the following as a regular user:

	mkdir -p $HOME/.kube
	sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	sudo chown $(id -u):$(id -g) $HOME/.kube/config

Copy down the final `kubeadm join` command since we will use this shortly to
join the gateway node to the central node control plane.

#### Installing the CNI networking plugins on the central node

The following steps should be done on the central control node _only_.

To install Flannel:

	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
	
To install Multus, first clone the Multus git repo:

	git clone https://github.com/k8snetworkplumbingwg/multus-cni
	
Then change into the `multus-cni` directory apply the yaml manifest:

	cat ./deployments/multus-daemonset-thick-plugin.yml | kubectl apply -f -
	
You can check if Flannel and Multus are running with:

	kubectl get -n kube-system pods | grep flannel

which should print:

	kube-flannel-ds-t5k5b                 1/1     Running   0          8m6s
	
And:

	kubectl get -n kube-system pods | grep multus

which should print:

	kube-multus-ds-r9mg8                  1/1     Running   0          2m41s
	
#### Removing the taint on the control node prohibiting application workload deployment.

As installed out of the box, `kubeadm` places a taint on the control node
disallowing deployment of application workloads. Since we want to deploy the
Volttron Central pod `vcentral` here, we need to remove the taint:

	kubectl taint node <central node hostname> node-role.kubernetes.io/master-
	
which should print out:

	node/<central node hostname> untainted

and also run the command:

	kubectl taint node <central node hostname> node-role.kubernetes.io/control-plane-
	
You can check if the node is untainted with:

	kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints --no-headers
	
which should show `<none>` for both on the central node.

#### Configuring the gateway node as a worker node

To join the gateway node to the cluster as a worker node, use the
`kubeadm join` command that `kubadm init` printed out just before
it finished adding on the argument for the CRI socket, [^2] for example:

	sudo kubeadm join 10.8.0.1:6443 --token <your token> \
	--discovery-token-ca-cert-hash <your discovery hash> --cri-socket=unix:///var/run/containerd/containerd.sock
	
The token is only good for a day, if you need to install more gateway nodes,
use this command on the control node to create a new one:

	kubeadm token create

If you don't have the value of `--discovery-token-ca-cert-hash` you can find by running this command on the control node:

	openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | \
	openssl dgst -sha256 -hex | sed 's/^.* //'

	
Finally, to use `kubectl` on the gateway node to deploy pods, you need
to copy the config file over from the control node to the gateway node. 
You should copy the file to your VirtualBox shared folder on the central
node and from there to the gateway node.
VM on the same host as the gateway node: 
Also copy the file into `/etc/kubernetes/admin.conf` as root on the 
gateway node so other users have access to it.
	
Check if everything is running OK by running `kubectl` on the gateway:

	kubectl get -n kube-system pods --output wide

	NAME                                   READY   STATUS    RESTARTS   AGE     IP              NODE           NOMINATED NODE   READINESS GATES
	coredns-6d4b75cb6d-9qbq4               1/1     Running   0          32m     10.244.0.2      central-node   <none>           <none>
	coredns-6d4b75cb6d-gkklf               1/1     Running   0          32m     10.244.0.3      central-node   <none>           <none>
	etcd-central-node                      1/1     Running   0          32m     192.168.0.128   central-node   <none>           <none>
	kube-apiserver-central-node            1/1     Running   0          32m     192.168.0.128   central-node   <none>           <none>
	kube-controller-manager-central-node   1/1     Running   0          32m     192.168.0.128   central-node   <none>           <none>
	kube-flannel-ds-q66n8                  1/1     Running   0          21m     192.168.0.128   central-node   <none>           <none>
	kube-flannel-ds-rfgpb                  1/1     Running   0          5m11s   192.168.0.122   gateway-node   <none>           <none>
	kube-multus-ds-jm49z                   1/1     Running   0          5m11s   192.168.0.122   gateway-node   <none>           <none>
	kube-multus-ds-vx26w                   1/1     Running   0          19m     192.168.0.128   central-node   <none>           <none>
	kube-proxy-7hr8p                       1/1     Running   0          32m     192.168.0.128   central-node   <none>           <none>
	kube-proxy-f9vhp                       1/1     Running   0          5m11s   192.168.0.122   gateway-node   <none>           <none>
	kube-scheduler-central-node            1/1     Running   0          32m     192.168.0.128   central-node   <none>           <none>

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
`cleanstart-cni-dhcpd.sh`, which cleans up any old sockets and starts the daemon, from `cluster-config` to `/usr/local/bin`:

	sudo cp cleanstart-cni-dhcpd.sh /usr/local/bin

Then create `/run/cni` and 
change the permissions on it so the daemon can access it:

	sudo mkdir /run/cni
	sudo chmod a+rx /run/cni

The next step is to copy the `systemd` unit file in `cluster-config`
into create a `systemctl` unit for the service and enable and start it, which starts the 
daemon, as follows:

	sudo cp cni-dhcpd-relay.service /etc/systemd/system
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
	
Your cluster should now be ready to deploy the microservice-volttron services!

## Troubleshooting

If something goes wrong with the above procedure, you should check the links
which have more detailed instructions including links to troubleshooting
pages. One for kubeadm is [here](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/troubleshooting-kubeadm/). You may need to fall
back on Linux networking and sysadmin documentation. You can watch the progress
on pod deployment with:

	ku get --watch -n <namespace> pods
	
and events with:

	ku get --watch events
	
Pod logs can be viewed with:

	ku logs --watch -n <namespace> <pod name>
	
Without the `--watch` argument, it prints out the latest and you 
can leave off the namespace argument if the item of interest is in
the default namespace. 





	

	









	







