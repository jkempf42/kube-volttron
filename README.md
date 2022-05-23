# What is kube-volttron?

`Kube-volttron` is a collection of yaml manifests and other files that deploy a version of
the [Volttron](https://volttron.readthedocs.io/en/main/) energy management platform, rearchitected 
as a collection of microservices, into the Kubernetes cloud-native container orchestration environment. 
It was build as an experiment to show how Kubernetes could be used to deploy an energy management service
consisting of a central node that stores data and provides web access and nodes on remote sites where
IoT protocols are used to communicate state and control to energy control devices.
By default, the Volttron images deployed by `kube-volttron` are prepackaged collections of Volttron agents
built with the `microservice-volttron` github repo. The `microservice-volttron` github repo is not 
yet publically available; however demo microservices are downloaded from the 
`jkempf42/public-repo` Docker image repo by the deployment manifests. 
`Microservice-volttron` allows subsets of Volttron agents
to be packaged and preconfigured into redistributable binary container images, with
the final configuration being done in the deployment context. The result is a re-architecting of
Volttron from a legacy, monolithic, deploy and run on one machine application to a modern 
application with a modular, microservices 
architecture. 

The `kube-volttron` cluster is built from a central node running in a cloud or on prem VM or server 
connected to 
a node at a remote site, called the gateway node, through a VPN. The central node runs the Volttron Central
agent which handles the Web UI and an SQL-lite historian. The gateway node monitors a collection of
devices using an IoT protocol ([BACnet](http://www.bacnet.org/) in the demo), an Actuator agent to handle commands
to the devices, and a forwarding historian to send data to the central node.
The repo was tested with VirtualBox for both the control and gateway nodes
and and instructions are provided in the `cluster-config/README.md` file for setting up the cluster base on that 
execution platform, but most instructions should generalize to other platforms.

Follow these steps (performed in the order specified here) to get `kube-volttron` up and running:

- Read the `cluster-config/README.md` file for instructions about how to create the central and gateway nodes,
then create the nodes and clone this git repo into the two nodes. On each node, change to
the `cluster-config` directory and follow the instructions in the `README.md` file to build your cluster.

- Change to the `central-node` directory and follow the instructions in the `README.md` file to deploy 
Volttron Central with SQL-lite historian on your
central node. Note that the default central node deployment stores the SQL-lite database in a file on the 
central node VM. Manifests are provided in the `central-node` directory and the `postgres` 
subdirectory for deploying with Postgres but since
the default `vcentral` container image does not have Postgres built in, they can't be used
and are not discussed in the deployment instructions. Adding Postgres
is a future enhancement.

- Once your Volttron Central is deployed, move to your gateway node and follow the directions in the 
`README.md` file to deploy the gateway node.

## Versions

The following versions of software packages were used to build kube-volttron. Your mileage may vary if you
choose to use different versions:

- operating system: Ubuntu 20.04 
- wireguard: wireguard-tools 1.0.20200513
- kubeadm: 1.24.0
- kubectl: 1.24.0 
- kubelet: 1.24.0
- kubernetes-cni:  0.8.7
- cri-tools: 1.23.0
- containerd: 1.5.9
- flannel: 0.17.0
- multus: 3.8


## Notes on the suitability of kube-volttron for production deployment.

The yaml manifests in the `central-node` and `gateway-node` subdirectories
pull demo prebuilt images from the Docker hub `jkempf42/public-repo`. 
If you decide to develop your own Volttron microservice containers, 
you will need to replace
the name of the container image in the manifests under the 
`spec.template.containers.image` key in the `Deployment` manifests, which is currently set to
`jkempf42/public-repo:<image type tag>`, with your own repository and image tag.

The demo `vcentral`, `vremote`, and `vbac` images in `jkempf42/public-repo` have been build 
with an ubuntu 20.04 image loaded with
debugging tools, especially for network debugging (traceroute, ping, dig, etc.). 
Once `microservice-volttron` is made public, you should modify the 
Dockerfiles at `microservice-volttron` to produce smaller 
images, and maybe use a smaller base OS image like alpine, if you plan to use `kube-volttron` in production. 

Finally, kube-volttron was developed with ease of deployability in mind
and not with security. If you decide to deploy kube-volttron for real, you
should go through the directions in this repo with a fine toothed comb,
ensuring file and directory permissions are properly set. Some effort 
was made to set file permissions for security but it was not consistent. Also, you
should make use of the powerful Kubernetes security tools like `Secret`
objects, RBAC control, and using separate namespaces for different tenants to 
ensure that only entites that are allowed can access their services in the cluster.
Finally, the demo images have self-signed certs built in, and they are not
appropriate for production use. So let me repeat: _kube-volttron is for
demo purposes only, it is not for production deployment!_ 
It was built as an experiment only. 
You will need to do some additional work before you can deploy 
it in production. 


