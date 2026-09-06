# Copyright (c) 2024 BB Tech Systems LLC

locals {
  # What NEW nodes install with. Defaults to the version the cluster runs.
  talos_image_version = coalesce(var.talos_image_version, var.talos_version)

  primary_control_node_ip = proxmox_virtual_environment_vm.talos_control_vm[keys(var.control_nodes)[0]].ipv4_addresses[7][0]
  control_node_ips        = [for vm in keys(var.control_nodes) : proxmox_virtual_environment_vm.talos_control_vm[vm].ipv4_addresses[7][0]]
  worker_node_ips         = [for vm in keys(var.worker_nodes) : proxmox_virtual_environment_vm.talos_worker_vm[vm].ipv4_addresses[7][0]]
  node_ips = concat(
    local.control_node_ips,
    local.worker_node_ips
  )
}

# Boot media only. The VM installs Talos onto its own blank disk from this ISO,
# so the running version is NOT a property of the VM and a version bump does not
# rebuild anything. Upgrades of a running node are done by talos_upgrade below.
resource "proxmox_download_file" "talos_image" {
  content_type = "iso"
  datastore_id = var.proxmox_iso_datastore
  node_name    = values(var.control_nodes)[0]
  url          = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${local.talos_image_version}/metal-${var.talos_arch}.iso"
  file_name    = "${var.talos_cluster_name}-talos_linux-${var.talos_schematic_id}-${local.talos_image_version}-${var.talos_arch}.iso"
  overwrite    = false
}

resource "proxmox_virtual_environment_vm" "talos_control_vm" {
  for_each  = var.control_nodes
  name      = each.key
  node_name = each.value
  pool_id   = var.proxmox_control_pool_id
  agent {
    enabled = true
  }
  cpu {
    cores = var.proxmox_control_vm_cores
    type  = var.proxmox_vm_type
  }
  memory {
    dedicated = var.proxmox_control_vm_memory
    floating  = var.proxmox_control_vm_memory
  }
  # Blank disk: Talos installs itself here on first boot. No file_id, so the
  # image version never forces VM replacement.
  disk {
    datastore_id = var.proxmox_image_datastore
    interface    = "virtio0"
    file_format  = "raw"
    iothread     = true
    discard      = "on"
    size         = var.proxmox_control_vm_disk_size
  }
  cdrom {
    file_id   = proxmox_download_file.talos_image.id
    interface = "ide3"
  }
  # Disk first: it is empty on the very first boot, so the BIOS falls through to
  # the ISO, Talos installs, and every later boot comes off the disk.
  boot_order = ["virtio0", "ide3"]
  network_device {
    vlan_id     = var.proxmox_network_vlan_id
    bridge      = var.proxmox_network_bridge
    mac_address = lookup(var.control_plane_mac_addresses, each.key, null)
    queues      = var.proxmox_network_queues
  }
  operating_system {
    type = "l26"
  }
  lifecycle {
    # Nodes provisioned before the cdrom-boot rework still carry the image as
    # their boot disk. Ignoring file_id keeps them in place; they pick up the
    # blank-disk shape whenever they are next rebuilt. The cdrom itself must NOT
    # be ignored -- boot_order references ide3, and Proxmox rejects a boot order
    # naming a device that was never attached.
    ignore_changes = [disk[0].file_id]
  }
}

resource "proxmox_virtual_environment_vm" "talos_worker_vm" {
  for_each  = var.worker_nodes
  name      = each.key
  node_name = each.value
  pool_id   = var.proxmox_worker_pool_id
  agent {
    enabled = true
  }
  cpu {
    cores = var.proxmox_worker_vm_cores
    type  = var.proxmox_vm_type
  }
  memory {
    dedicated = var.proxmox_worker_vm_memory
    floating  = var.proxmox_worker_vm_memory
  }
  # Blank disk: Talos installs itself here on first boot. No file_id, so the
  # image version never forces VM replacement.
  disk {
    datastore_id = var.proxmox_image_datastore
    interface    = "virtio0"
    file_format  = "raw"
    iothread     = true
    discard      = "on"
    size         = var.proxmox_worker_vm_disk_size
  }
  cdrom {
    file_id   = proxmox_download_file.talos_image.id
    interface = "ide3"
  }
  # Disk first: it is empty on the very first boot, so the BIOS falls through to
  # the ISO, Talos installs, and every later boot comes off the disk.
  boot_order = ["virtio0", "ide3"]
  network_device {
    vlan_id     = var.proxmox_network_vlan_id
    bridge      = var.proxmox_network_bridge
    mac_address = lookup(var.worker_mac_addresses, each.key, null)
    queues      = var.proxmox_network_queues
  }
  dynamic "disk" {
    for_each = lookup(var.worker_extra_disks, each.key, [])
    content {
      datastore_id = disk.value.datastore_id
      file_format  = disk.value.file_format
      file_id      = disk.value.file_id
      interface    = "virtio${disk.key + 1}"
      iothread     = true
      discard      = "on"
      size         = disk.value.size
    }
  }
  operating_system {
    type = "l26"
  }
  lifecycle {
    # Nodes provisioned before the cdrom-boot rework still carry the image as
    # their boot disk. Ignoring file_id keeps them in place; they pick up the
    # blank-disk shape whenever they are next rebuilt. The cdrom itself must NOT
    # be ignored -- boot_order references ide3, and Proxmox rejects a boot order
    # naming a device that was never attached.
    ignore_changes = [disk[0].file_id]
  }
}

resource "talos_machine_secrets" "talos_secrets" {}

data "talos_machine_configuration" "control_mc" {
  cluster_name = var.talos_cluster_name
  machine_type = "controlplane"
  # TODO - Should we allow the user to override this?
  # This is a single point of failure but without a proxy or load balancer
  # it is required to be a single point of failure.
  cluster_endpoint = "https://${local.primary_control_node_ip}:6443"
  machine_secrets  = talos_machine_secrets.talos_secrets.machine_secrets
}

data "talos_machine_configuration" "worker_mc" {
  cluster_name = var.talos_cluster_name
  machine_type = "worker"
  # TODO - Should we allow the user to override this?
  # This is a single point of failure but without a proxy or load balancer
  # it is required to be a single point of failure.
  cluster_endpoint = "https://${local.primary_control_node_ip}:6443"
  machine_secrets  = talos_machine_secrets.talos_secrets.machine_secrets
}

data "talos_client_configuration" "talos_client_config" {
  cluster_name         = var.talos_cluster_name
  client_configuration = talos_machine_secrets.talos_secrets.client_configuration
  endpoints            = local.control_node_ips
  nodes                = local.node_ips
}

resource "talos_machine_configuration_apply" "talos_control_mc_apply" {
  for_each                    = var.control_nodes
  client_configuration        = talos_machine_secrets.talos_secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_mc.machine_configuration
  node                        = proxmox_virtual_environment_vm.talos_control_vm[each.key].ipv4_addresses[7][0]
  config_patches              = var.control_machine_config_patches
}

resource "talos_machine_configuration_apply" "talos_worker_mc_apply" {
  for_each                    = var.worker_nodes
  client_configuration        = talos_machine_secrets.talos_secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker_mc.machine_configuration
  node                        = proxmox_virtual_environment_vm.talos_worker_vm[each.key].ipv4_addresses[7][0]
  config_patches              = var.worker_machine_config_patches
}

# You only need to bootstrap 1 control node, we pick the first one
resource "talos_machine_bootstrap" "talos_bootstrap" {
  node                 = local.primary_control_node_ip
  client_configuration = talos_machine_secrets.talos_secrets.client_configuration
}

resource "talos_cluster_kubeconfig" "talos_kubeconfig" {
  depends_on = [
    talos_machine_bootstrap.talos_bootstrap
  ]
  client_configuration = talos_machine_secrets.talos_secrets.client_configuration
  node                 = local.primary_control_node_ip
}