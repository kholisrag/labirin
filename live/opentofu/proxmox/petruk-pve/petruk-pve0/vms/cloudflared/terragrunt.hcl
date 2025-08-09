locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  name  = basename(get_terragrunt_dir())
  vm_id = 100
}

terraform {
  source = format("%s/modules/opentofu/proxmox/vms/0.2.0", get_repo_root())
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  vms = {
    cloudflared = {
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

      name        = local.name
      node_name   = local.node_vars.locals.node
      vm_id       = local.vm_id
      description = "Cloudflared Tunnel VM"
      bios        = "ovmf"
      on_boot     = true
      startup = [
        {
          order      = 1
          up_delay   = 10
          down_delay = 10
        }
      ]
      started    = true
      protection = false
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
      machine = "q35"
      cpu = [
        {
          cores   = 1
          type    = "x86-64-v2-AES"
          sockets = 2
          numa    = true
          flags   = ["+aes"]
        }
      ]
      memory = [
        {
          dedicated = 2048
          floating  = 1024
        }
      ]
      scsi_hardware = "virtio-scsi-single"
      pool_id       = "gateway-pool"
      tags          = ["gateway"]

      vga = [
        {
          type = "serial0"
        }
      ]
      network_device = [
        {
          bridge = "vmbr0"
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
          size         = 4
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
