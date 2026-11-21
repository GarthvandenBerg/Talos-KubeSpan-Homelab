variable "proxmox_api_url" { 
  type = string 
}

variable "proxmox_api_token_id" { 
  type = string 
}

variable "proxmox_api_token_secret" { 
  type      = string
  sensitive = true 
}

variable "K8SSERVICEHOST" { 
  type = string 
}

variable "GIT_NAME" { 
  type      = string
}

variable "GIT_PASS" { 
  type      = string
  sensitive = true 
}

variable "OPEN_BAO_SECRET_ID" { 
  type      = string
  sensitive = true 
}

# --- Provider ---
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.106.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.19.0"
    }
  }
}


provider "proxmox" {
  endpoint = var.proxmox_api_url
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure = true
}

locals {
  node_data       = yamldecode(file("${path.module}/nodes.yaml"))
  system_path     = "${path.root}/../infrastructure/base"
  ctl_list        = [for n in local.node_data.nodes : n if n.type == "controlplane"]
  work_list       = [for n in local.node_data.nodes : n if n.type == "worker"]
  cluster_name    = local.node_data.cluster_name
  factory_id      = local.node_data.factory_id
  talos_version   = local.node_data.talos_version
  kube_version    = local.node_data.kube_version
  talos_image     = "factory.talos.dev/nocloud-installer/${local.factory_id}:${local.talos_version}"

  # Generate a map of the controlplanes and define disk, memory and CPU for them.
  ctl_map = {
    for idx, node in local.ctl_list : node.name => {
      type         = "CTL"
      id           = 800 + idx
      ip           = node.ip 
      platform     = node.platform
      target_node  = try(node.nodename, null)
      storage_pool = try(node.storage_pool, null) 
      mac          = try(node.mac, null)
      cores        = 2
      memory       = 5120
      disk         = "50G" 
      talos_image  = "factory.talos.dev/nocloud-installer/${local.factory_id}:${local.talos_version}"
    }
  }

  work_map = {
    for idx, node in local.work_list : node.name => {
      type         = "WORK"
      id           = 820 + idx
      ip           = node.ip 
      platform     = node.platform
      target_node  = try(node.nodename, null) 
      storage_pool = try(node.storage_pool, null) 
      mac          = try(node.mac, null) 
      cores        = node.nodename == "picard" ? 4 : 6
      memory       = node.nodename == "picard" ? 10240 : 16384
      disk         = "200G"
      talos_image  = "factory.talos.dev/nocloud-installer/${local.factory_id}:${local.talos_version}"
    }
  }
  all_nodes = merge(local.ctl_map, local.work_map)
}

resource "proxmox_virtual_environment_vm" "vm_instance" {
  for_each = nonsensitive({ for k, v in local.all_nodes : k => v if v.platform == "proxmox" })
  
  bios       = "ovmf"
  machine    = "q35"
  on_boot    = true
  boot_order = ["scsi0", "ide2"]
  scsi_hardware = "virtio-scsi-single"
  operating_system {
    type     = "l26"
  }
  agent {
    enabled  = false
  }

  startup {
    order      = "3"
    up_delay   = "60"
    down_delay = "60"
  }

  dynamic "hostpci" {
    for_each = lookup(each.value, "pci_devices", [])
    content {
      device   = "hostpci${hostpci.key}"
      mapping  = hostpci.value.device_map_name
      pcie     = hostpci.value.pcie
      rombar   = hostpci.value.rombar
    }
  }

  name          = each.key
  vm_id         = each.value.id
  node_name     = each.value.target_node

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
    floating  = 0 
  }

  # --- EFI Disk ---
  efi_disk {
    datastore_id = each.value.storage_pool
    file_format  = "raw"
    type         = "4m"
  }
  
  # --- Talos ISO (CDROM) ---
  cdrom {
    file_id   = "mediaserver:iso/nocloud-amd64.iso"      # Shared storage between the Proxmox cluster (SMB share)
    interface = "ide2"
  }

  # --- Primary Boot Disk ---
  disk {
    datastore_id = each.value.storage_pool
    file_format  = "raw"
    interface    = "scsi0"
    size         = tonumber(replace(each.value.disk, "G", "")) # expects an integer in GB
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  network_device {
    bridge      = "VLAN2"
    model       = "virtio"
    mac_address = each.value.mac
  }
}

resource "talos_machine_secrets" "machine_secrets" {
  talos_version = local.node_data.talos_version
}

data "talos_client_configuration" "talosconfig" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  endpoints = [for node in local.ctl_list : node.ip]
}

output "talosconfig" {
  value     = data.talos_client_configuration.talosconfig.talos_config
  sensitive = true
}

# blueprint for the cloud "baremetal" node (NO VIP)
data "talos_machine_configuration" "controlplane_cloud" {
  cluster_name       = local.cluster_name
  cluster_endpoint   = "https://localhost:7445"
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.machine_secrets.machine_secrets
  talos_version      = local.node_data.talos_version
  kubernetes_version = local.node_data.kube_version
  config_patches     = [
    file("${path.module}/../.talos/patches/shared-patch.yaml"),
    file("${path.module}/../.talos/patches/ctl-patch.yaml"),
    file("${path.module}/../.talos/patches/dns-patch.yaml"),
    yamlencode({
      machine = {
        install = {
          image = local.talos_image
        }
      }
    })
  ]
}

# blueprint strictly for Proxmox nodes
data "talos_machine_configuration" "controlplane_proxmox" {
  cluster_name       = local.cluster_name
  cluster_endpoint   = "https://localhost:7445"
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.machine_secrets.machine_secrets
  talos_version      = local.node_data.talos_version
  kubernetes_version = local.node_data.kube_version
  config_patches     = [
    file("${path.module}/../.talos/patches/shared-patch.yaml"),
    file("${path.module}/../.talos/patches/ctl-patch.yaml"),
    file("${path.module}/../.talos/patches/vip-patch.yaml"),
    file("${path.module}/../.talos/patches/dns-patch.yaml"),
    yamlencode({
      machine = {
        install = {
          image = local.talos_image
        }
      }
    })
  ]
}

data "talos_machine_configuration" "worker" {
  cluster_name       = local.cluster_name
  cluster_endpoint   = "https://localhost:7445"
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.machine_secrets.machine_secrets
  talos_version      = local.node_data.talos_version
  kubernetes_version = local.node_data.kube_version
  config_patches   = [
    file("${path.module}/../.talos/patches/shared-patch.yaml"),
    file("${path.module}/../.talos/patches/worker-patch.yaml"),
    file("${path.module}/../.talos/patches/dns-patch.yaml"),
    yamlencode({
      machine = {
        install = {
          image = local.talos_image
        }
      }
    })
  ]
}

resource "talos_machine_configuration_apply" "cp" {
  for_each             = nonsensitive(local.ctl_map)
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = each.value.ip
  depends_on           = [proxmox_virtual_environment_vm.vm_instance]
  # Selects the pre-hashed configuration
  machine_configuration_input = each.value.platform == "proxmox" ? data.talos_machine_configuration.controlplane_proxmox.machine_configuration : data.talos_machine_configuration.controlplane_cloud.machine_configuration

  config_patches = [
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = each.key
      auto       = "off"
    })
  ]
}

resource "talos_machine_configuration_apply" "worker" {
  for_each                    = nonsensitive(local.work_map)
  client_configuration        = talos_machine_secrets.machine_secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value.ip
  depends_on                  = [proxmox_virtual_environment_vm.vm_instance]

  config_patches = [
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = each.key
      auto       = "off"
    })
  ]
}

resource "talos_machine_bootstrap" "bootstrap" {
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = local.ctl_list[0].ip 
  depends_on           = [talos_machine_configuration_apply.cp]
}

resource "talos_cluster_kubeconfig" "kubeconfig" {
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = var.K8SSERVICEHOST
  depends_on           = [talos_machine_bootstrap.bootstrap]
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.kubeconfig.kubeconfig_raw
  sensitive = true
}

resource "local_sensitive_file" "talosconfig_temp" {
  content  = data.talos_client_configuration.talosconfig.talos_config
  filename = "${path.module}/talosconfig.temp"
}

resource "local_sensitive_file" "kubeconfig_yaml" {
  content  = replace(
    talos_cluster_kubeconfig.kubeconfig.kubeconfig_raw,
    "https://localhost:7445",
    "https://${var.K8SSERVICEHOST}:6443"
  )
  filename = "${path.module}/kubeconfig.yaml"
}

resource "time_sleep" "wait_first_boot" {
  depends_on = [talos_machine_bootstrap.bootstrap]
  create_duration = "90s"
}


resource "null_resource" "wait_for_api" {
  depends_on = [talos_cluster_kubeconfig.kubeconfig]
    provisioner "local-exec" {
      interpreter = ["bash", "-c"]
      command     = <<EOF
        IP="${var.K8SSERVICEHOST}"
        PORT=6443
        echo "Waiting for TCP handshake on $IP:$PORT..."

        while true; do
          if timeout 2 bash -c "</dev/tcp/$IP/$PORT" 2>/dev/null; then
            echo "TCP Port $PORT is OPEN. API is physically reachable. Proceeding!"
            break
          else
            echo "Port $PORT still closed (Connection Timeout). Retrying in 5s..."
            sleep 5
          fi
        done

        sleep 5
EOF
  }
}

data "http" "gateway_api_manifests" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.7.0/standard-install.yaml"
}

data "kubectl_file_documents" "gateway_crds" {
  content = data.http.gateway_api_manifests.response_body
}

resource "kubectl_manifest" "gateway_api_crds" {
  for_each  = data.kubectl_file_documents.gateway_crds.manifests
  yaml_body = each.value
  server_side_apply = true
  force_conflicts = true
  depends_on = [null_resource.wait_for_api]
}

data "kubectl_file_documents" "cilium_configs" {
  content = file("${local.system_path}/cilium/ip-pool-announcements.yaml")
}

provider "helm" {
  kubernetes = {
    host                   = "https://${var.K8SSERVICEHOST}:6443"
    client_certificate     = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.client_key)
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.ca_certificate)
  }
}

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.20.5"
  namespace  = "kube-system"
  
  wait          = false
  wait_for_jobs = false
  timeout       = 900 # Long timeout to ensure cilium pulls everything it needs and we don't get errors.
  
  values     = [file("${local.system_path}/cilium/cilium-values.yaml")]
  depends_on = [null_resource.wait_for_api, kubectl_manifest.gateway_api_crds]
}

# I had to add this in to ensure cilium was 100% up on all nodes... I am sure theres a better way but 5 mins is stable.
resource "time_sleep" "wait_for_cilium_crds" {
  depends_on = [helm_release.cilium]

  create_duration = "300s"
}

provider "kubernetes" {
  host                   = "https://${var.K8SSERVICEHOST}:6443"
  client_certificate     = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.ca_certificate)
}

provider "kubectl" {
  host                   = "https://${var.K8SSERVICEHOST}:6443"
  client_certificate     = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.ca_certificate)
  load_config_file       = false
}

resource "kubectl_manifest" "cilium_resources" {
  for_each  = data.kubectl_file_documents.cilium_configs.manifests
  yaml_body = each.value
  depends_on = [time_sleep.wait_for_cilium_crds]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd-system"
  create_namespace = true

  values = [
    file("${local.system_path}/argocd/argocd-values.yaml")
  ]
  depends_on = [kubectl_manifest.cilium_resources]
}

resource "kubernetes_secret_v1" "argocd_repo_creds" {
  metadata {
    name      = "github-repo-credentials"
    namespace = "argocd-system" 
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = "https://github.com/GarthvandenBerg/Talos-Proxmox-Homelab.git"
    username = var.GIT_NAME 
    password = var.GIT_PASS 
  }

  type = "Opaque"
  depends_on = [helm_release.argocd]
}

resource "kubectl_manifest" "argocd_root_app" {
  yaml_body = file("${path.module}/../clusters/homelab-cluster/argocd/bootstrap/root-app.yaml")
  depends_on = [
    helm_release.argocd,
    kubernetes_secret_v1.argocd_repo_creds
  ]
}

resource "kubectl_manifest" "external_secrets_namespace" {
  yaml_body = <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: external-secrets
YAML

  depends_on = [helm_release.argocd, kubernetes_secret_v1.argocd_repo_creds]
}

resource "kubectl_manifest" "openbao_secret" {
  sensitive_fields = ["data"]

  yaml_body = <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: openbao-approle
  namespace: external-secrets
type: Opaque
data:
  secret-id: ${base64encode(var.OPEN_BAO_SECRET_ID)}
YAML

  depends_on = [helm_release.argocd, kubernetes_secret_v1.argocd_repo_creds, kubectl_manifest.external_secrets_namespace]
}
