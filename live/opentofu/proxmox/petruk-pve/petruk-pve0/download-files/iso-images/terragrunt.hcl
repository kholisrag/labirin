locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  name         = basename(get_terragrunt_dir())
  datastore_id = "ssd"
  content_type = "iso"

  config_yaml = {
    for idx, iso_image in yamldecode(sops_decrypt_file(format("%s/iso_images.enc.yaml", get_terragrunt_dir()))).iso_images :
    iso_image.name => iso_image
  }
}

terraform {
  source = "git::https://github.com/kholisrag/iac-modules.git?ref=proxmox-download-files/v0.1.0"
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  proxmox_provider = local.provider_vars.locals.provider_id
  node_name        = local.node_vars.locals.node

  files = {
    opnsense = {
      content_type            = local.content_type
      datastore_id            = local.datastore_id
      node_name               = local.node_vars.locals.node
      url                     = local.config_yaml["opnsense"].url
      checksum                = local.config_yaml["opnsense"].checksum
      checksum_algorithm      = local.config_yaml["opnsense"].checksum_algorithm
      decompression_algorithm = local.config_yaml["opnsense"].decompression_algorithm
      file_name               = local.config_yaml["opnsense"].file_name
      overwrite_unmanaged     = true
    }
    "talos-v1.11.5" = {
      content_type        = local.content_type
      datastore_id        = local.datastore_id
      node_name           = local.node_vars.locals.node
      url                 = local.config_yaml["talos-v1.11.5"].url
      file_name           = local.config_yaml["talos-v1.11.5"].file_name
      overwrite_unmanaged = true
    }
    "talos-v1.12.0" = {
      content_type        = local.content_type
      datastore_id        = local.datastore_id
      node_name           = local.node_vars.locals.node
      url                 = local.config_yaml["talos-v1.12.0"].url
      file_name           = local.config_yaml["talos-v1.12.0"].file_name
      overwrite_unmanaged = true
    }
  }
}
