locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  name = basename(get_terragrunt_dir())
  config_yaml = {
    for idx, bridge in yamldecode(sops_decrypt_file(format("%s/bridges.enc.yaml", get_terragrunt_dir()))).bridges :
    bridge.name => bridge
  }
}

terraform {
  source = format("%s/modules/opentofu/proxmox/networks/linux-bridges//0.1.0", get_repo_root())
}

prevent_destroy = true

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  bridges = {
    # Note: vmbr0 is commented since its default bridge created by Proxmox VE installer
    # if we manage here, when there is a unintended destroy action, it will remove the main bridge
    # which cause network down on the Proxmox host itself.
    # vmbr0 = {
    #   name       = local.config_yaml["vmbr0"].name
    #   node_name  = local.node_vars.locals.node
    #   address    = local.config_yaml["vmbr0"].address
    #   autostart  = local.config_yaml["vmbr0"].autostart
    #   comment    = local.config_yaml["vmbr0"].comment
    #   gateway    = local.config_yaml["vmbr0"].gateway
    #   ports      = local.config_yaml["vmbr0"].ports
    #   vlan_aware = local.config_yaml["vmbr0"].vlan_aware
    # },
    vmbr1 = {
      name       = local.config_yaml["vmbr1"].name
      node_name  = local.node_vars.locals.node
      address    = local.config_yaml["vmbr1"].address
      autostart  = local.config_yaml["vmbr1"].autostart
      comment    = local.config_yaml["vmbr1"].comment
      ports      = local.config_yaml["vmbr1"].ports
      vlan_aware = local.config_yaml["vmbr1"].vlan_aware
    },
    vmbr2 = {
      name       = local.config_yaml["vmbr2"].name
      node_name  = local.node_vars.locals.node
      address    = local.config_yaml["vmbr2"].address
      autostart  = local.config_yaml["vmbr2"].autostart
      comment    = local.config_yaml["vmbr2"].comment
      ports      = local.config_yaml["vmbr2"].ports
      vlan_aware = local.config_yaml["vmbr2"].vlan_aware
    }
  }
}
