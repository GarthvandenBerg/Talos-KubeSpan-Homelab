# Terraform Proxmox Homelab

I use terraform to ensure a smooth replicatable build process.

Terraform providers used in this project so far:
- Kubectl
- Helm 
- Taloscl 
- Proxmox BPG

In the initial setup I install, Cilium as the networking layer, Longhorn for HA storage provider and then ArgoCD to build any other apps I need down the line.

I hard coded variables into the .yamls and helm values because this is for my homelab use.

My work projects uses variables in BASH or tfvars as it needs to be portable for different locations etc...

-------
## This is my attempt of the homelab before starting the Kubecraft homelab course.

#### This is the information I have learned homelabbing for 2 years.

- I dont have any applications actually running in the cluster yet and I plan to migrate some VM/LXC's I have in Proxmox into the cluster.
- I love to solve problems by trail and error using some AI help but mainly reading documentation.

-------
## Talos node definitions made in the nodes.yaml

I define the Mac addresses that the controlplanes and workers should use here that I already defined in my DHCP pool

If you want custom names for your nodes make sure you set that in your DHCP server, as Talos automatically picks up names like that.
- Best practice to use all lowercase because thats what Kubernetes will use anyways.
- If your DHCP server is not assigning the names you can also use YQ or JQ to strip the "controlplane.yaml" generated with ```talosctl gen config``` to only include the first document and then manually add hostnames.

---------
## Build terraform

CD into the Terraform folder then run:

terraform init

terraform apply 

#### Get your kubeconfig
terraform output -raw kubeconfig > kubeconfig.yaml

-------
## ArgoCD 

#### Get ArgoCD password
```kubectl -n argocd-system get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo```

#### Sync waves:
 - 1 Operators
 - 2 DB's
 - 3 Jobs to be run before applications can be up.
 - 5 Applications
 - 10 Jobs to be done after applications are up.

 -------
 ## Future plans:

 - Migrate existing VMS/LXC's into the cluster - With NFS share on my NAS
 - Safe upgrade process, I purposefully chose 1.12.7 for Talos so I can test and simulate a cluster upgrade.
 - Sealed secrets or SOPS+Age or External secrets providers
 - Blog
 - DevContainers
 
