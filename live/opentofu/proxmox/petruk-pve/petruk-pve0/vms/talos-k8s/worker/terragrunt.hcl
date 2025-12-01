locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  name                = basename(get_terragrunt_dir())
  prefix_name         = "main-talos-k8s"
  prefix_description  = "Main Talos Kubernetes Worker Node"
  bios                = "ovmf"
  machine             = "q35"
  started             = true
  protection          = false
  on_boot             = true
  reboot_after_update = false
  scsi_hardware       = "virtio-scsi-pci"
  pool_id             = "k8s-worker-pool"
  tags = [
    "k8s-worker",
    "main-talos-worker",
  ]
  startup = [
    {
      order      = 5
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
      cores   = 2
      type    = "host"
      sockets = 2
      numa    = true
      flags   = ["+aes"]
    }
  ]
  memory = [
    {
      dedicated = 8192
      floating  = 8192
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
      datastore_id      = "local-lvm"
      type              = "4m"
      pre_enrolled_keys = false
    }
  ]
  boot_order = ["ide2", "scsi0"]
  disk = [
    {
      interface    = "scsi0"
      datastore_id = "local-lvm"
      size         = 50
      cache        = "none"
      discard      = "on"
      file_format  = "raw"
      aio          = "io_uring"
      backup       = true
      ssd          = true
    }
  ]
  cdrom_base = {
    interface = "ide2"
  }
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
    format("%s-%s-01", local.prefix_name, local.name) = {
      node_name           = local.node_vars.locals.node
      vm_id               = 106
      description         = format("%s 01", local.prefix_description)
      bios                = "ovmf"
      machine             = local.machine
      started             = local.started
      protection          = local.protection
      on_boot             = local.on_boot
      reboot_after_update = local.reboot_after_update
      scsi_hardware       = local.scsi_hardware
      pool_id             = local.pool_id
      tags                = local.tags
      startup             = local.startup
      agent               = local.agent
      operating_system    = local.operating_system
      cpu                 = local.cpu
      memory              = local.memory
      vga                 = local.vga
      network_device      = local.network_device
      efi_disk            = local.efi_disk
      boot_order          = local.boot_order
      disk                = local.disk
      cdrom = [
        merge(local.cdrom_base, {
          file_id = dependency.iso_images.outputs.download_file_output["talos"].id
        })
      ]
      serial_device = local.serial_device
      rng           = local.rng
    },
    format("%s-%s-02", local.prefix_name, local.name) = {
      node_name           = local.node_vars.locals.node
      vm_id               = 107
      description         = format("%s 02", local.prefix_description)
      bios                = local.bios
      machine             = local.machine
      started             = local.started
      protection          = local.protection
      on_boot             = local.on_boot
      reboot_after_update = local.reboot_after_update
      scsi_hardware       = local.scsi_hardware
      pool_id             = local.pool_id
      tags                = local.tags
      startup             = local.startup
      agent               = local.agent
      operating_system    = local.operating_system
      cpu                 = local.cpu
      memory              = local.memory
      vga                 = local.vga
      network_device      = local.network_device
      efi_disk            = local.efi_disk
      boot_order          = local.boot_order
      disk                = local.disk
      cdrom = [
        merge(local.cdrom_base, {
          file_id = dependency.iso_images.outputs.download_file_output["talos"].id
        })
      ]
      serial_device = local.serial_device
      rng           = local.rng
    },
    format("%s-%s-03", local.prefix_name, local.name) = {
      node_name           = local.node_vars.locals.node
      vm_id               = 108
      description         = format("%s 03", local.prefix_description)
      bios                = local.bios
      machine             = local.machine
      started             = local.started
      protection          = local.protection
      on_boot             = local.on_boot
      reboot_after_update = local.reboot_after_update
      scsi_hardware       = local.scsi_hardware
      pool_id             = local.pool_id
      tags                = local.tags
      startup             = local.startup
      agent               = local.agent
      operating_system    = local.operating_system
      cpu                 = local.cpu
      memory              = local.memory
      vga                 = local.vga
      network_device      = local.network_device
      efi_disk            = local.efi_disk
      boot_order          = local.boot_order
      disk                = local.disk
      cdrom = [
        merge(local.cdrom_base, {
          file_id = dependency.iso_images.outputs.download_file_output["talos"].id
        })
      ]
      serial_device = local.serial_device
      rng           = local.rng
    },
  }
}
