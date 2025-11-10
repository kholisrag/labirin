locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  name  = basename(get_terragrunt_dir())
  vm_id = 101
}

terraform {
  source = format("%s/modules/opentofu/proxmox/vms//0.2.0", get_repo_root())
}

prevent_destroy = true

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

dependency "iso_images" {
  config_path = format("%s/../../download-files/iso-images", get_terragrunt_dir())
}

inputs = {
  vms = {
    opnsense = {
      name                = local.name
      node_name           = local.node_vars.locals.node
      vm_id               = local.vm_id
      description         = "OPNSense Gateway VM"
      bios                = "ovmf"
      machine             = "q35"
      started             = true
      protection          = true
      on_boot             = true
      reboot_after_update = true
      scsi_hardware       = "virtio-scsi-single"
      pool_id             = "gateway-pool"
      tags                = ["gateway"]

      startup = [
        {
          order      = 2
          up_delay   = 10
          down_delay = 10
        }
      ]
      ## Notes:
      # - Agent Need to be Enabled after All OPNSense Installation + Configuration Done
      #   if not, the terragrunt will stuck indefinitely waiting for the agent to be connected
      #   `error waiting for network interfaces from QEMU agent`
      # - Need to install agent OPNSense Web GUI: System > Firmware > Plugins (✅ Show community plugins ) > os-qemu-guest-agent
      agent = [
        {
          enabled = false
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
          flags   = []
        }
      ]
      memory = [
        {
          dedicated = 16384
          floating  = 8192
        }
      ]

      vga = [
        {
          type   = "std"
          memory = 16
        }
      ]
      network_device = [
        {
          bridge = "vmbr0"
          model  = "virtio"
          queues = 8
        },
        {
          bridge = "vmbr1"
          model  = "virtio"
          queues = 8
        },
        {
          bridge = "vmbr2"
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
      ##- Notes:
      ## - Set boot_order to cdrom first for the installation process
      ##   After done OPNSense installation, change it to boot from disk only
      # boot_order = ["ide2","scsi0"]
      boot_order = ["scsi0"]
      disk = [
        {
          interface    = "scsi0"
          datastore_id = "local-lvm"
          size         = 120
          cache        = "none"
          aio          = "io_uring"
          backup       = true
          iothread     = true
          ssd          = true
        }
      ]
      ## Notes:
      # - Commented after done OPNSense installation
      # - Seem have a bug from the provider side when we comment cdrom block after done OPNSense installation
      #   Need to delete the cdrom device manually from Proxmox UI
      # - the protection need to be disabled first for use to remove the cdrom
      # cdrom = [
      #   {
      #     interface = "ide2"
      #     file_id   = dependency.iso_images.outputs.download_file_output["opnsense"].id
      #   }
      # ]
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
