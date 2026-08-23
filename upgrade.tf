# Copyright (c) 2024 BB Tech Systems LLC

# In-place upgrades. The talos provider has no upgrade resource -- a Talos
# upgrade is an imperative call to the machine API, which writes the new version
# to the node's inactive partition and reboots into it. So terraform declares the
# version and shells out to talosctl to apply it. Disks and node identity survive.
locals {
  upgrade_nodes = var.talos_upgrade_enabled ? {
    for name, ip in merge(
      { for k, v in proxmox_virtual_environment_vm.talos_control_vm : k => v.ipv4_addresses[7][0] },
      { for k, v in proxmox_virtual_environment_vm.talos_worker_vm : k => v.ipv4_addresses[7][0] },
    ) : name => ip
  } : {}

  upgrade_workers  = { for k, v in local.upgrade_nodes : k => v if contains(keys(var.worker_nodes), k) }
  upgrade_controls = { for k, v in local.upgrade_nodes : k => v if contains(keys(var.control_nodes), k) }

  upgrade_script = <<-EOT
    set -euo pipefail
    cfg=$(mktemp); trap 'rm -f "$cfg"' EXIT
    printf '%s' "$TALOSCONFIG_CONTENT" > "$cfg"
    tc="talosctl --talosconfig $cfg -n $NODE -e $ENDPOINT"
    # ponytail: parses the Server Tag out of `version`; --wait already fails loudly
    # if the node does not come back, so a fancier check buys nothing.
    current=$($tc version | awk '/Tag:/{v=$2} END{print v}')
    if [ "$current" = "v$TARGET" ]; then
      echo "$NODE already on $current, nothing to do"
      exit 0
    fi
    echo "$NODE: $current -> v$TARGET"
    $tc upgrade --image "$IMAGE" --wait
  EOT
}

# Workers first: if an upgrade is going to fail, fail before the control plane
# reboots and takes the API server with it.
resource "terraform_data" "talos_upgrade_worker" {
  for_each         = local.upgrade_workers
  triggers_replace = [var.talos_version, each.value]
  depends_on       = [talos_machine_configuration_apply.talos_worker_mc_apply, talos_machine_bootstrap.talos_bootstrap]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = local.upgrade_script
    environment = {
      TALOSCONFIG_CONTENT = data.talos_client_configuration.talos_client_config.talos_config
      NODE                = each.value
      ENDPOINT            = local.primary_control_node_ip
      TARGET              = var.talos_version
      IMAGE               = "factory.talos.dev/metal-installer/${var.talos_schematic_id}:v${var.talos_version}"
    }
  }
}

resource "terraform_data" "talos_upgrade_control" {
  for_each         = local.upgrade_controls
  triggers_replace = [var.talos_version, each.value]
  depends_on       = [terraform_data.talos_upgrade_worker, talos_machine_configuration_apply.talos_control_mc_apply]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = local.upgrade_script
    environment = {
      TALOSCONFIG_CONTENT = data.talos_client_configuration.talos_client_config.talos_config
      NODE                = each.value
      ENDPOINT            = each.value
      TARGET              = var.talos_version
      IMAGE               = "factory.talos.dev/metal-installer/${var.talos_schematic_id}:v${var.talos_version}"
    }
  }
}
