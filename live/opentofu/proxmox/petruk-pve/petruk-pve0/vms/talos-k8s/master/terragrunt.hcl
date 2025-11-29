locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  name = basename(get_terragrunt_dir())
  network_yaml = {
    for idx, mac_addresses in yamldecode(sops_decrypt_file(format("%s/network.enc.yaml", get_terragrunt_dir()))).mac_addresses :
    mac_addresses.name => mac_addresses
  }
}

terraform {
  source = format("%s/modules/opentofu/proxmox/vms//0.2.0", get_repo_root())
}

prevent_destroy = false

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

dependency "iso_images" {
  config_path = format("%s/../../../download-files/iso-images", get_terragrunt_dir())
}

inputs = {
  vms = {
    format("talos-k8s-%s-01", local.name) = {
      node_name           = local.node_vars.locals.node
      vm_id               = 103
      description         = "Talos Kubernetes Master Node 01"
      bios                = "ovmf"
      machine             = "q35"
      started             = true
      protection          = false
      on_boot             = true
      reboot_after_update = false
      scsi_hardware       = "virtio-scsi-pci"
      pool_id             = "k8s-master-pool"
      tags                = ["k8s-master", "talos-master"]
      startup = [
        {
          order      = 4
          up_delay   = 10
          down_delay = 10
        }
      ]
      agent = [
        {
          enabled = true
        }
      ]
      operating_system = [
        {
          type = "l26"
        }
      ]
      cpu = [
        {
          cores   = 1
          type    = "host"
          sockets = 2
          numa    = true
          flags   = ["+aes"]
        }
      ]
      memory = [
        {
          dedicated = 4096
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
          bridge      = "vmbr1"
          model       = "virtio"
          mac_address = local.network_yaml[format("talos-k8s-%s-01", local.name)].mac_address
          queues      = 8
        }
      ]
      efi_disk = [
        {
          datastore_id      = "local-lvm"
          type              = "4m"
          pre_enrolled_keys = false
        }
      ],
      boot_order = ["ide2", "scsi0"]
      disk = [
        {
          interface    = "scsi0"
          datastore_id = "local-lvm"
          size         = 20
          cache        = "none"
          discard      = "on"
          file_format  = "raw"
          aio          = "io_uring"
          backup       = true
          ssd          = true
        }
      ]
      cdrom = [
        {
          interface = "ide2"
          file_id   = dependency.iso_images.outputs.download_file_output["talos"].id
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
    },
    format("talos-k8s-%s-02", local.name) = {
      node_name           = local.node_vars.locals.node
      vm_id               = 104
      description         = "Talos Kubernetes Master Node 02"
      bios                = "ovmf"
      machine             = "q35"
      started             = true
      protection          = false
      on_boot             = true
      reboot_after_update = false
      scsi_hardware       = "virtio-scsi-pci"
      pool_id             = "k8s-master-pool"
      tags                = ["k8s-master", "talos-master"]
      startup = [
        {
          order      = 4
          up_delay   = 10
          down_delay = 10
        }
      ]
      agent = [
        {
          enabled = true
        }
      ]
      operating_system = [
        {
          type = "l26"
        }
      ]
      cpu = [
        {
          cores   = 1
          type    = "host"
          sockets = 2
          numa    = true
          flags   = ["+aes"]
        }
      ]
      memory = [
        {
          dedicated = 4096
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
          bridge      = "vmbr1"
          model       = "virtio"
          mac_address = local.network_yaml[format("talos-k8s-%s-02", local.name)].mac_address
          queues      = 8
        }
      ]
      efi_disk = [
        {
          datastore_id      = "local-lvm"
          type              = "4m"
          pre_enrolled_keys = false
        }
      ],
      boot_order = ["ide2", "scsi0"]
      disk = [
        {
          interface    = "scsi0"
          datastore_id = "local-lvm"
          size         = 20
          cache        = "none"
          discard      = "on"
          file_format  = "raw"
          aio          = "io_uring"
          backup       = true
          ssd          = true
        }
      ]
      cdrom = [
        {
          interface = "ide2"
          file_id   = dependency.iso_images.outputs.download_file_output["talos"].id
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
    },
    format("talos-k8s-%s-03", local.name) = {
      node_name           = local.node_vars.locals.node
      vm_id               = 105
      description         = "Talos Kubernetes Master Node 03"
      bios                = "ovmf"
      machine             = "q35"
      started             = true
      protection          = false
      on_boot             = true
      reboot_after_update = false
      scsi_hardware       = "virtio-scsi-pci"
      pool_id             = "k8s-master-pool"
      tags                = ["k8s-master", "talos-master"]
      startup = [
        {
          order      = 4
          up_delay   = 10
          down_delay = 10
        }
      ]
      agent = [
        {
          enabled = true
        }
      ]
      operating_system = [
        {
          type = "l26"
        }
      ]
      cpu = [
        {
          cores   = 1
          type    = "host"
          sockets = 2
          numa    = true
          flags   = ["+aes"]
        }
      ]
      memory = [
        {
          dedicated = 4096
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
          bridge      = "vmbr1"
          model       = "virtio"
          mac_address = local.network_yaml[format("talos-k8s-%s-03", local.name)].mac_address
          queues      = 8
        }
      ]
      efi_disk = [
        {
          datastore_id      = "local-lvm"
          type              = "4m"
          pre_enrolled_keys = false
        }
      ],
      boot_order = ["ide2", "scsi0"]
      disk = [
        {
          interface    = "scsi0"
          datastore_id = "local-lvm"
          size         = 20
          cache        = "none"
          discard      = "on"
          file_format  = "raw"
          aio          = "io_uring"
          backup       = true
          ssd          = true
        }
      ]
      cdrom = [
        {
          interface = "ide2"
          file_id   = dependency.iso_images.outputs.download_file_output["talos"].id
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
    },
  }
}
