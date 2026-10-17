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

```
cp examplevars.tfvars terraform.tfvars

terraform init

terraform apply 
```

#### Get your kubeconfig
terraform output -raw kubeconfig > kubeconfig.yaml

-------
## ArgoCD 

#### Get ArgoCD password
```kubectl -n argocd-system get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo```

---

### Cloudflared tunnel

Because I haven't got openbao fully up I just manually push this to the cluster

```
read -rs CF_TOKEN   # paste the token, press Enter (nothing is echoed)

kubectl create secret generic cloudflare-credentials \
  --namespace cfgate-system \
  --from-literal=CLOUDFLARE_API_TOKEN="$CF_TOKEN"

unset CF_TOKEN
```

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
 
---
### OpenBao / ESO

1. Create OpenBao instance on your flavour of linux server

2. Save your secrets somewhere safe

3. Login to openbao

4. ```bao secrets enable -path=secret kv-v2```

5. Put a secret in (values live ONLY here)
```
bao kv put secret/staging/grafana \
  admin-user=admin \
  admin-password="$(openssl rand -base64 24)"
```

6. Read-only policy for ESO
```
bao policy write eso-read - <<'POL'
path "secret/data/staging/*"     { capabilities = ["read"] }
path "secret/metadata/staging/*" { capabilities = ["read", "list"] }
POL
```

7. AppRole for ESO (optionally lock to your cluster node CIDR)
```
bao auth enable approle
bao write auth/approle/role/eso \
  token_policies=eso-read token_ttl=1h token_max_ttl=4h \
  secret_id_ttl=0 \
  token_bound_cidrs=192.168.2.0/24
```

8. Grab the IDs to put into cluster/manifest under `infrastructure/base/eso/clustersecretstore-openbao.yaml`
```
bao read -field=role_id auth/approle/role/eso/role-id  
bao write -f -field=secret_id auth/approle/role/eso/secret-id 
```

9. Create namespace and put in your secret-id from the step above, if you expose this make a new one.

```
kubectl -n external-secrets create secret generic openbao-approle \
  --from-literal=secret-id='<secret_id>'
```