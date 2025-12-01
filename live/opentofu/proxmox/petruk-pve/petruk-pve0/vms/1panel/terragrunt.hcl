locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  name  = basename(get_terragrunt_dir())
  vm_id = 102
}

terraform {
  source = format("%s/modules/opentofu/proxmox/vms//0.2.0", get_repo_root())
}

prevent_destroy = false

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  vms = {
    "1panel" = {
      cloud_init = {
        datastore_id = "ssd"
        user_data    = sops_decrypt_file(format("%s/user-data.enc.yaml", get_terragrunt_dir()))
        network_data = sops_decrypt_file(format("%s/network-config.enc.yaml", get_terragrunt_dir()))
        meta_data = yamlencode({
          "instance-id"    = local.name
          "vm-id"          = local.vm_id
          "vm-name"        = local.name
          "local-hostname" = format("%s.homelab", local.name)
        })
      }

      name                = local.name
      node_name           = local.node_vars.locals.node
      vm_id               = local.vm_id
      description         = "1Panel Hosting Platform VM"
      bios                = "ovmf"
      machine             = "q35"
      started             = true
      protection          = false
      on_boot             = true
      reboot_after_update = true
      scsi_hardware       = "virtio-scsi-single"
      pool_id             = "virtualmachines-pool"
      tags                = ["hosting"]

      startup = [
        {
          order      = 3
          up_delay   = 10
          down_delay = 10
        }
      ]
      agent = [
        {
          enabled = true
        }
      ]
      clone = [
        {
          vm_id = 9001 # ubuntu24-cloudinit
        }
      ]
      operating_system = [
        {
          type = "l26"
        }
      ]
      cpu = [
        {
          cores   = 2
          type    = "x86-64-v2-AES"
          sockets = 2
          numa    = true
          flags   = ["+aes"]
        }
      ]
      memory = [
        {
          dedicated = 8192
          floating  = 4096
        }
      ]

      vga = [
        {
          type = "serial0"
        }
      ]
      network_device = [
        {
          bridge = "vmbr1"
          model  = "virtio"
          queues = 8
        }
      ]
      efi_disk = [
        {
          datastore_id = "local-lvm"
          type         = "4m"
        }
      ]
      disk = [
        {
          interface    = "scsi0"
          datastore_id = "local-lvm"
          size         = 50
          cache        = "none"
          aio          = "io_uring"
          backup       = true
          iothread     = true
          ssd          = true
        }
      ]
      serial_device = [
        {
          device = "socket"
        }
      ]
      rng = [
        {
          source    = "/dev/urandom"
          max_bytes = 1024
          period    = 1000
        }
      ]
    }
  }
}
