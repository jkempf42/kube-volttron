# What is kube-volttron?

Kube-volttron is a collection of yaml manifests and other files that deploy
the [Volttron](https://volttron.readthedocs.io/en/main/) energy management platform
as a service in the Kubernetes cloud-native container orchestration environment. 
By default, the Volttron images deployed by kube-volttron are prepackaged collections of Volttron agents
built with the [microservice-volttron](ref) github repo, downloaded from the 
jkempf42/public-repo Docker image repo. Microservice-volttron allows subsets of Volttron agents
to be packaged into redistributable binary container images that are preconfigured, with
the final configuration being done in the deployment context. The result is a re-architecting of
Volttron from a monolithic, deploy and run on one machine application to a application with a  microservices 
architecture. If you want to build your own Volttron microservices images, check out the
microservice-volttron repo. Both kube-volttron and microservice-volttron have been built on ubuntu 20.04
and they are not guaranteed to and probably won't work on any other operating system.

There are two subdirectories:

- cloud-site: This contains code for deploying the Volttron central microservice (vcentral) and setting up a
distributed cluster consisting of gateway nodes at remote sites, like in buildings, at solar farms, or on car 
chargers connected to the cluster at the cloud site. The
distributed cluster is build using [ClusterAPI](https://cluster-api.sigs.k8s.io/) specifically the open source
[BYOH distro](https://github.com/vmware-tanzu/cluster-api-provider-bringyourownhost) from VMWare. The
remote nodes are connected to the cloud VM using the [Wireguard](https://www.wireguard.com/) VPN.

- gateway-node: This contains code for deploying a gateway node at a remote site. Two IoT "protocols", are supported
with microservices, the fake driver (not a real protocol) which comes with the Volttron distro 
(vremote microservice) and and BACnet (vbac
microservice). A simulated AHU device script is also provided for the vbac microservice. The configuration for
the AHU device is baked into the vbac service, so if you want to add any additional BACnet devices you will
have to build another container image. The gateway-node can be deployed standalone for testing purposes.

A caveat about vcentral, vremote, and vbac images: they have been build with an ubuntu 20.04 image loaded with
debugging tools, especially for network debugging (traceroute, ping, dig, etc.) and so may not be suitable for
production use. You will probably want to modify the Dockerfiles at microservice-volttron to produce smaller 
images, maybe use a smaller base OS image like alpine, if you plan to use kube-volttron in production. 

