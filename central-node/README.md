# Deploying the kube-volttron cloud site

Kube-volttron uses the [k3s](https://rancher.com/docs/k3s/latest/en/) Kubernetes distro, which was specifically designed for IoT use cases, and the [Wireguard VPN](https://www.wireguard.com/) for point to point encrypted communication
between the cloud VM and the on-site gateway nodes. 

## Installing and configuring the Volttron Central cloud VM.

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

## Installing and configuring the Wireguard VPN

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

Note that these instructions work best if you have a VM or bare metal device running Ubuntu 20.4 
from which you can work back into the cloud using `ssh`. You can 
open one window and `ssh` into your cloud VM and have the other on the gateway 
machine. Both sides need to have Wireguard installed and configured.

### Installing Wireguard and related packages

Update/upgrade on both the gateway node and VM with:

	sudo apt update
	sudo apt upgrade
	
After the upgrade is complete, install Wireguard:

	sudo apt install wiregard

`apt` will suggest you install one of `openresolv` or `resolvconf`, the
following instructions are based on installing `resolvconf`:

	sudo apt install resolveconf
	
You should also install your favorite editor on the cloud VM if it isn't there, and packages containing network debugging tools including `net-tools` and `inetutils-traceroute` (for `ifconfig` and `traceroute`) just in case you need them.

### Configuring the Wireguard VPN

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
[here](https://whatsmyip.org.) from the gateway node. Be sure the 
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

#### Creating the wg0 interface and installing a system service

Now with the configuration complete, you can create the wg0 interface
and install a system service so it is recreated when your VM and gateway
node reboot. 

The one time command for enabling the interface is:

	sudo wg-quick up

This will create a virtual interface for each configuration file in
`/etc/wireguard` and configure it to route over the VPN.

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
for the gateway node `wg0` interface in the `10.8.0.0/16` range, incrementing
the last number by one each time you configure a new node. Create a 
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

## Installing and configuring k3s

K3s calls the Kubernetes control node the server and worker nodes the agent.
K3s supports two deployment architectures, a single-server 
architecture and a high 
availability architecture. The instructions below are for the single server
architecture. The figure below, from the Rancher 
[deployemnt architecture page](https://rancher.com/docs/k3s/latest/en/architecture/) shows a high level view of the single-server 
deployment architecture. The single-server deployment uses SQLite as its 
database rather than etcd which is the default database for Kubernetes.

![Single server architecture](https://rancher.com/docs/img/rancher/k3s-architecture-single-server.png) 

### Installing the k3s server node (control node)

To install k3s, follow the instructions for installing to use Docker as the container runtime on the 
[Advanced Options and Configuration Options](https://rancher.com/docs/k3s/latest/en/advanced/#using-docker-as-the-container-runtime)
to install the server, since  by default, k3s installs with `containerd` for the container runtime.
As installed, k3s does not allow nonroot users `kubectl`
access to the cluster. In order to avoid having to type `sudo` every time
you want to access the cluster, you need to shut down the k3s `systemctl`
service, edit the configuration file to indicate that access to the 
`kubeconfig` file at `/etc/rancher/k3s/k3s.yaml` should be allowed for
non-root users, then restart the service. 

Start by shutting down the service:

	sudo systemctl stop k3s.service
	sudo systemctl disable k3s.service
	
Next, `sudo` start your favorite editor on the file 
`/etc/systemd/system/k3s.service`. Scroll down to the bottom of the 
file to the `ExecStart` key and add `--write-kubeconfig-mode 777` 
to the value:

	ExecStart=/usr/local/bin/k3s \
		server \
		'--docker' \
		'--write-kubeconfig-mode 777' \

Save the file and restart the system service:

	sudo systemctl enable k3s.service
	sudo systemctl start k3s.service

You should now be able to use `kubectl` without root access.

## K3s networking

Use `kubectl` to list the pods in the `kube-system` namespace:

	kubectl get -n kube-system pods -o wide
	
You should see something like:

	NAME                                      READY   STATUS      RESTARTS   AGE   IP          NODE          NOMINATED NODE   READINESS GATES
	local-path-provisioner-6c79684f77-kqbh4   1/1     Running     0          13h   10.42.0.2   k3s-central   <none>           <none>
	helm-install-traefik-crd-7jkkf            0/1     Completed   0          13h   10.42.0.6   k3s-central   <none>           <none>
	helm-install-traefik-bjbtv                0/1     Completed   1          13h   10.42.0.4   k3s-central   <none>           <none>
	svclb-traefik-5pnx8                       2/2     Running     0          13h   10.42.0.7   k3s-central   <none>           <none>
	coredns-d76bd69b-cl7jx                    1/1     Running     0          13h   10.42.0.5   k3s-central   <none>           <none>
	traefik-df4ff85d6-446vt                   1/1     Running     0          13h   10.42.0.8   k3s-central   <none>           <none>
	metrics-server-7cd5fcb6b7-qfd5p           1/1     Running     0          13h   10.42.0.3   k3s-central   <none>           <none>

K3s uses the CoreDNS DNS server which is the default for Kubernetes, the Traefik ingress controller, and Flannel for networking.
Notice, however, that a pod for the Flannel CNI provider is not listed. 
K3s incorporates Flannel into the k3s server/agent rather than deploying
it as a separate CNI service. You can substitute another CNI provider for Flannel, [this page](https://rancher.com/docs/k3s/latest/en/installation/network-options/) tells you how. 

However, we need need to install Multus so we can create multi-interface pods in the gateway agents. Some IoT protocols use
broadcast to find devices or other protocols that won't work through the Kubernetes proxies. To accommodate these protocols,
the Volttron IoT gateway agent pods need to create a second interface directly on the site local area network. The Flannel
network is used as the intra-cluster network between pods. Please see the README.md file n the gateway-node directory for
more details and an architectural diagram. 

First clone the Multus git repo in the `cluster-config` directory:


	git clone https://github.com/k8snetworkplumbingwg/multus-cni

We need to modify the default deployment manifest. [This link](https://gist.github.com/janeczku/ab5139791f28bfba1e0e03cfc2963ecf) describes the edits to make in the manifest. The manifest can be found in `multus-cni/deployments`. Change into the directy and copy the `multus-daemonset.yml` manifest into `multus-k3s-daemonset.yml` and make the edits
in that. 

To install Multus, use the following command:

	cat ./deployments/multus-k3s-daemonset.yml | kubectl apply -f -
	
Then check if the pod is running:

	kubectl get -n kube-system pods | grep multus
	
You should see something like:


	kube-multus-ds-zrv4j           1/1     Running   10 (4h32m ago)   30d

### Installing a k3s agent node (worker node)
