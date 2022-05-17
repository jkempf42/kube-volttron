# Deploying a Kubernetes cluster for Volttron microservices

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

K3s calls the Kubernetes control node the "server" and worker nodes "agents".
K3s supports two deployment architectures, a single-server 
architecture and a high 
availability architecture. The instructions below are for the single server
architecture. The figure below, from the Rancher 
[deployment architecture page](https://rancher.com/docs/k3s/latest/en/architecture/) shows a high level view of the single-server 
deployment architecture. The single-server deployment uses SQLite as its 
database rather than etcd which is the default database for Kubernetes.

![Single server architecture](https://rancher.com/docs/img/rancher/k3s-architecture-single-server.png) 

### Installing the k3s server node (control node)

To install k3s on the cloud VM control node, the script `build-central-node.sh` is provided. You need to edit the file to customize it as follows:

- If you used a different addressing scheme for your Wireguard VPN,
then change the `--node-ip` value from  `10.8.0.1` to whatever address
you assigned to your cloud VM `wg0` interface.

- Using `ifconfig` or `ip a`, find the address on the interface having 
the lowest final digit in its name, for example, if you have a gateway node 
with two interfaces, `enp0s3` and
`enp0s8`, then use the IP address assigned to `enp0s3`. Substitute this
address for the address `192.168.0.129` after the key `--node-external-ip`.

In the script, the first command installs Docker and the second 
installs k3s with the `--docker` parameter since we want
to use Docker for our container runtime (k3s uses `containerd` by 
default). If Docker is already installed on your system, then remove it 
to prevent any conflicts. You can find out the package names with:

	sudo apt list --installed | grep docker
	sudo apt remove <list of package names for docker>

Once you have the edits complete, run the script with:

	sudo ./build-central-node.sh
	
After the script has run, type the following commands to change permissions 
on the Docker socket so that your username can access it:

	usermod -aG docker $USER
	su - $USER
	
The second command will prompt you for your superuser password.

After installing k3s, use `kubectl` to list the pods 
in the `kube-system` namespace:

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
it as a separate CNI service. You can substitute another CNI provider for Flannel if you want, [this page](https://rancher.com/docs/k3s/latest/en/installation/network-options/) tells you how. 

However, we still need need to install Multus so we can create 
multi-interface pods in the gateway agents. Some IoT protocols use
broadcast to find devices or other protocols that won't work through the 
Kubernetes proxies. To accommodate these protocols,
the Volttron IoT gateway agent pods may need to create a second 
interface directly on the site local area network using Multus, since
the Flannel
network has no
direct access to the local site network.
Please see the README.md file in the `gateway-node` directory for
more details and an architectural diagram. 

To install Multus, first clone the Multus git repo in the `cluster-config` 
directory:

	git clone https://github.com/k8snetworkplumbingwg/multus-cni

We need to modify the default deployment manifest. 
[This link](https://gist.github.com/janeczku/ab5139791f28bfba1e0e03cfc2963ecf) 
describes the edits to make in the manifest. 
The manifest can be found in `multus-cni/deployments`. Change into the 
directory and copy the `multus-daemonset.yml` manifest into 
`multus-k3s-daemonset.yml` and make the edits in that. 

To install Multus, change back into the parent `multus-cni` directory
and use the following command:

	cat ./deployments/multus-k3s-daemonset.yml | kubectl apply -f -
	
Then check if the pod is running:

	kubectl get -n kube-system pods | grep multus
	
You should see something like:


	kube-multus-ds-zrv4j           1/1     Running   10 (4h32m ago)   30d

### Installing a k3s agent node (worker node)

[This link](https://rancher.com/docs/k3s/latest/en/installation/install-options/agent-config/) points to the installation options for a k3s agent. But
there are no comprehensive instructions about how to get an agent running, 
so these are provided here.

The first 
step is to copy two files from the server node onto the client. 
The first file is `node-token` and is used by the k3s agent 
to authenticate with the server during installation. Copy the file 
from `/var/lib/rancher/k3s/server/node-token` on
your cloud VM server node to the gateway node in the `cluster-config`
directory using `scp`.

The second file is the `kubeconfig` yaml file that tells `kubectl`
where to find the API server (among other things). It is located your cloud
VM server node at `/etc/rancher/k3s/k3s.yaml`. Create the `~/.kube` 
subdirectory and copy the `k3s.yaml` file from your cloud VM to
`~/.kube/config` again using scp. 
Then edit the file and change the IP address of 
the `server:` from `127.0.0.1` to the address on the Wireguard `wg0` 
interface of your cloud VM server node. If you followed the numbering 
scheme above to configure Wireguard, it should be `10.8.0.1`.

The tested build script `build-gateway-node.sh` is provided in the 
`cluster-config` directory to install k3s as an agent on the gateway node,
but it needs some configuration for your system. Edit the file and
replace the IP address in the `K3S_URL` value with the address of your
cloud VM `wg0` interface if you didn't use `10.8.0.1`. Also change 
the value of the `--node-ip` parameter from `10.8.0.2` to the
address on the Wireguard `wg0` interface of the gateway node if you
used a different Wireguard numbering scheme. Finally, replace the
`node-external-ip` parameter with the IP address on the interface with
the lowest number as described in the previous section on configuring k3s
on the server. 

Note that that script interpolates any arguments into the command to install,
so you can add additional arguments from the k3s agent installation options
page. For example, you may  want to add a node label to your gateway node indicating its geographic location and function:

	--node-label location=International Widgets, Inc., 5601 Speedway Blvd, Tucson, AZ, USA, 85710
	--node-label service=electric car charger controller
	
After the script is done installing k3s, use the commands in the previous
section to add your username to the Docker group so you can access the
Docker socket without `sudo`.

Type:

	kubectl get nodes

in a shell window on the gateway node and if everything worked as expected,
you should see something like:

	NAME          STATUS   ROLES                  AGE   VERSION
	k3s-gateway   Ready    <none>                 97m   v1.23.6+k3s1
	k3s-central   Ready    control-plane,master   17h   v1.23.6+k3s1
	
indicating you now have an IoT cluster with a central cloud VM and an
onsite gateway node.

## Troubleshooting

For Wireguard troubleshooting, you should ensure that you have a collection of
basic Linux network connectivity tools installed, like `ping`, `ifconfig`,
and `traceroute`. These may also come in handy for the k3s installation.
You can use `systemctl status wg-quick@2w0.service` to find out the
status of the Wireguard interface service if something goes wrong, and
also start, stop, enable and disable the service using `systemctl`. 

For k3s, if the installation fails, the server or agent process will most
likely not start. You can use `systemctl status k3s.service`,
`journalctl -xe` or `journalctl -u k3s` to see
what happened. Check the `k3s.service` or `k3s-agent.service` file in 
`/etc/systemd/system` to ensure the command on the `ExecStart` key
is correct. You can also start the command by hand, changing the arguments.
Finally, if you need to start the installation from scratch, you
can use `/usr/local/bin/k3s-uninstall.sh` or 
`/usr/local/bin/k3s-agent-uninstall.sh` to completely remove it and
install again. If you want to use one of the `build-xx` scripts to
install, be sure to uninstall Docker with:

	sudo apt list --installed | grep docker
	sudo apt uninstall <Docker packages>
	
and also be sure to `autoremove` any packages that `apt` says you should,
otherwise there may be problem when you install Docker again.




	




