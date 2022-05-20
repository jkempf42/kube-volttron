# What is kube-volttron?

`Kube-volttron` is a collection of yaml manifests and other files that deploy a version of
the [Volttron](https://volttron.readthedocs.io/en/main/) energy management platform, rearchitected to be
built as a collection of microservices, into the Kubernetes cloud-native container orchestration environment. 
By default, the Volttron images deployed by `kube-volttron` are prepackaged collections of Volttron agents
built with the `microservice-volttron` github repo. The `microservice-volttron` github repo is not 
yet publically available; however demo microservices are downloaded from the 
`jkempf42/public-repo` Docker image repo by the deployment manifests. 
`Microservice-volttron` allows subsets of Volttron agents
to be packaged and preconfigured into redistributable binary container images, with
the final configuration being done in the deployment context. The result is a re-architecting of
Volttron from a legacy, monolithic, deploy and run on one machine application to a modern 
application with a modular, microservices 
architecture. Both `kube-volttron` and `microservice-volttron` have been built on ubuntu 20.04
and they are not guaranteed to and probably won't work on any other operating system.

The `kube-volttron` cluster is built as a cloud or on prem VM or server running a Volttron Central
central node connected to 
a node at a remote site, called the gateway node, through a VPN. The gateway node monitors a collection of
devices and using an IoT protocol ([BACnet](http://www.bacnet.org/) in the demo).
The repo was tested with VirtualBox for the gateway node
and and instructions are provided in the `cluster-config/README.md` file for that execution platform, but most
instructions should generalize to other platforms.

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

Note that the demo vcentral, vremote, and vbac images in `jkempf42/public-repo` have been build 
with an ubuntu 20.04 image loaded with
debugging tools, especially for network debugging (traceroute, ping, dig, etc.) and so may be too big for
production use. Once `microservice-volttron` is made public, you will probably want to modify the 
Dockerfiles at `microservice-volttron` to produce smaller 
images, maybe use a smaller base OS image like alpine, if you plan to use `kube-volttron` in production. 

The yaml manifests in the `central-node` and `gateway-node` subdirectories
pull demo prebuilt images from the Docker hub `jkempf42/public-repo`. 
If you decide to develop your own Volttron microservice containers, 
you will need to replace images with your own, you will need to replace
the name of the container image in the manifests under the 
`spec.template.containers.image` key, which is currently set to
`jkempf42/public-repo:<image type tag>`, with your own repository and image tag in the yaml manifests.


