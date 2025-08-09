locals {
  vms = {
    for vm_name, vm_config in var.pve_vms : vm_name => merge(
      {
        name = coalesce(vm_config.name, vm_name)
      },
      vm_config
    )
  }

  # Extract VMs that have custom cloud-init configuration
  vms_with_cloudinit = {
    for vm_name, vm_config in local.vms : vm_name => vm_config if try(vm_config.cloudinit, null) != null
  }

  # Determine the last slot for cloud-init disk based on disk_type
  # ide: ide0-ide3 (last = ide3)
  # sata: sata0-sata5 (last = sata5)
  # scsi: scsi0-scsi30 (last = scsi30)
  cloudinit_slot_map = {
    "ide"  = "ide3"
    "sata" = "sata5"
    "scsi" = "scsi30"
  }

  # Process VMs to append cloud-init cdrom disk when cloudinit config exists
  vms_with_disks = {
    for vm_name, vm_config in local.vms : vm_name => merge(
      vm_config,
      {
        disk = try(vm_config.cloudinit, null) != null ? concat(
          lookup(vm_config, "disk", []),
          [
            {
              type = "cdrom"
              slot = local.cloudinit_slot_map[try(vm_config.cloudinit.disk_type, "scsi")]
              iso  = proxmox_cloud_init_disk.ci[vm_name].id
            }
          ]
        ) : lookup(vm_config, "disk", [])
      }
    )
  }
}

# Cloud Init Disk Resource
# This creates custom cloud-init ISO images for VMs with custom cloud-init config
resource "proxmox_cloud_init_disk" "ci" {
  for_each = local.vms_with_cloudinit

  name           = "${each.value.name}-ci"
  pve_node       = try(each.value.cloudinit.pve_node, try(each.value.target_node, each.value.target_nodes[0]))
  storage        = each.value.cloudinit.storage
  meta_data      = sensitive(try(each.value.cloudinit.meta_data, ""))
  user_data      = sensitive(try(each.value.cloudinit.user_data, ""))
  vendor_data    = sensitive(try(each.value.cloudinit.vendor_data, ""))
  network_config = sensitive(try(each.value.cloudinit.network_config, ""))
}

resource "proxmox_vm_qemu" "vm" {
  for_each = local.vms_with_disks

  name                        = lookup(each.value, "name", each.key)
  target_node                 = lookup(each.value, "target_node", null)
  target_nodes                = lookup(each.value, "target_nodes", null)
  vmid                        = lookup(each.value, "vmid", null)
  description                 = lookup(each.value, "description", null)
  define_connection_info      = lookup(each.value, "define_connection_info", true)
  bios                        = lookup(each.value, "bios", "seabios")
  onboot                      = lookup(each.value, "onboot", false)
  startup                     = lookup(each.value, "startup", "")
  vm_state                    = lookup(each.value, "vm_state", "running")
  protection                  = lookup(each.value, "protection", false)
  tablet                      = lookup(each.value, "tablet", true)
  boot                        = lookup(each.value, "boot", null)
  bootdisk                    = lookup(each.value, "bootdisk", null)
  agent                       = lookup(each.value, "agent", 1)
  pxe                         = lookup(each.value, "pxe", null)
  clone                       = lookup(each.value, "clone", null)
  clone_id                    = lookup(each.value, "clone_id", null)
  full_clone                  = lookup(each.value, "full_clone", true)
  hastate                     = lookup(each.value, "hastate", null)
  hagroup                     = lookup(each.value, "hagroup", null)
  qemu_os                     = lookup(each.value, "qemu_os", "l26")
  machine                     = lookup(each.value, "machine", null)
  memory                      = lookup(each.value, "memory", 512)
  balloon                     = lookup(each.value, "balloon", null)
  hotplug                     = lookup(each.value, "hotplug", "network,disk,usb")
  scsihw                      = lookup(each.value, "scsihw", "virtio-scsi-single")
  pool                        = lookup(each.value, "pool", null)
  tags                        = lookup(each.value, "tags", null)
  force_create                = lookup(each.value, "force_create", false)
  os_type                     = lookup(each.value, "os_type", null)
  force_recreate_on_change_of = lookup(each.value, "force_recreate_on_change_of", null)
  os_network_config           = lookup(each.value, "os_network_config", null)
  ssh_forward_ip              = lookup(each.value, "ssh_forward_ip", null)
  ssh_user                    = lookup(each.value, "ssh_user", null)
  ssh_private_key             = lookup(each.value, "ssh_private_key", null)
  ci_wait                     = lookup(each.value, "ci_wait", 30)
  ciuser                      = lookup(each.value, "ciuser", null)
  cipassword                  = lookup(each.value, "cipassword", null)
  cicustom                    = lookup(each.value, "cicustom", null)
  ciupgrade                   = lookup(each.value, "ciupgrade", false)
  searchdomain                = lookup(each.value, "searchdomain", null)
  nameserver                  = lookup(each.value, "nameserver", null)
  sshkeys                     = lookup(each.value, "sshkeys", null)
  ipconfig0                   = lookup(each.value, "ipconfig0", "")
  ipconfig1                   = lookup(each.value, "ipconfig1", null)
  ipconfig2                   = lookup(each.value, "ipconfig2", null)
  ipconfig3                   = lookup(each.value, "ipconfig3", null)
  ipconfig4                   = lookup(each.value, "ipconfig4", null)
  ipconfig5                   = lookup(each.value, "ipconfig5", null)
  ipconfig6                   = lookup(each.value, "ipconfig6", null)
  ipconfig7                   = lookup(each.value, "ipconfig7", null)
  ipconfig8                   = lookup(each.value, "ipconfig8", null)
  ipconfig9                   = lookup(each.value, "ipconfig9", null)
  ipconfig10                  = lookup(each.value, "ipconfig10", null)
  ipconfig11                  = lookup(each.value, "ipconfig11", null)
  ipconfig12                  = lookup(each.value, "ipconfig12", null)
  ipconfig13                  = lookup(each.value, "ipconfig13", null)
  ipconfig14                  = lookup(each.value, "ipconfig14", null)
  ipconfig15                  = lookup(each.value, "ipconfig15", null)
  automatic_reboot            = lookup(each.value, "automatic_reboot", true)
  skip_ipv4                   = lookup(each.value, "skip_ipv4", null)
  skip_ipv6                   = lookup(each.value, "skip_ipv6", null)
  agent_timeout               = lookup(each.value, "agent_timeout", 90)

  # CPU Block
  dynamic "cpu" {
    for_each = lookup(each.value, "cpu", null) != null ? lookup(each.value, "cpu") : []
    content {
      affinity = lookup(cpu.value, "affinity", "")
      cores    = lookup(cpu.value, "cores", 1)
      limit    = lookup(cpu.value, "limit", 0)
      numa     = lookup(cpu.value, "numa", false)
      sockets  = lookup(cpu.value, "sockets", 1)
      type     = lookup(cpu.value, "type", "host")
      units    = lookup(cpu.value, "units", 0)
      vcores   = lookup(cpu.value, "vcores", 0)

      dynamic "flags" {
        for_each = lookup(cpu.value, "flags", null) != null ? [1] : []
        content {
          md_clear    = contains(lookup(cpu.value, "flags", []), "md_clear") ? "on" : null
          pcid        = contains(lookup(cpu.value, "flags", []), "pcid") ? "on" : null
          spec_ctrl   = contains(lookup(cpu.value, "flags", []), "spec_ctrl") ? "on" : null
          ssbd        = contains(lookup(cpu.value, "flags", []), "ssbd") ? "on" : null
          ibpb        = contains(lookup(cpu.value, "flags", []), "ibpb") ? "on" : null
          virt_ssbd   = contains(lookup(cpu.value, "flags", []), "virt_ssbd") ? "on" : null
          amd_ssbd    = contains(lookup(cpu.value, "flags", []), "amd_ssbd") ? "on" : null
          amd_no_ssb  = contains(lookup(cpu.value, "flags", []), "amd_no_ssb") ? "on" : null
          hv_tlbflush = contains(lookup(cpu.value, "flags", []), "hv_tlbflush") ? "on" : null
          hv_evmcs    = contains(lookup(cpu.value, "flags", []), "hv_evmcs") ? "on" : null
          aes         = contains(lookup(cpu.value, "flags", []), "aes") ? "on" : null
        }
      }
    }
  }

  # VGA Block
  dynamic "vga" {
    for_each = lookup(each.value, "vga", null) != null ? lookup(each.value, "vga") : []
    content {
      type   = lookup(vga.value, "type", "serial0")
      memory = lookup(vga.value, "memory", null)
    }
  }

  # Network Block
  dynamic "network" {
    for_each = lookup(each.value, "network", [])
    content {
      id        = lookup(network.value, "id")
      model     = lookup(network.value, "model")
      macaddr   = lookup(network.value, "macaddr", null)
      bridge    = lookup(network.value, "bridge", "nat")
      tag       = lookup(network.value, "tag", 0)
      firewall  = lookup(network.value, "firewall", false)
      mtu       = lookup(network.value, "mtu", null)
      rate      = lookup(network.value, "rate", 0)
      queues    = lookup(network.value, "queues", 1)
      link_down = lookup(network.value, "link_down", false)
    }
  }

  # Disk Block
  # Includes regular disks and cloud-init cdrom (if cloudinit config exists)
  dynamic "disk" {
    for_each = lookup(each.value, "disk", [])
    content {
      slot                 = lookup(disk.value, "slot", null)
      type                 = lookup(disk.value, "type", "disk")
      storage              = lookup(disk.value, "storage", null)
      size                 = lookup(disk.value, "size", null)
      format               = lookup(disk.value, "format", "raw")
      cache                = lookup(disk.value, "cache", null)
      backup               = lookup(disk.value, "backup", true)
      iothread             = lookup(disk.value, "iothread", false)
      replicate            = lookup(disk.value, "replicate", false)
      discard              = lookup(disk.value, "discard", false)
      emulatessd           = lookup(disk.value, "emulatessd", false)
      passthrough          = lookup(disk.value, "passthrough", false)
      disk_file            = lookup(disk.value, "disk_file", null)
      iso                  = lookup(disk.value, "iso", null)
      readonly             = lookup(disk.value, "readonly", false)
      asyncio              = lookup(disk.value, "asyncio", null)
      serial               = lookup(disk.value, "serial", null)
      wwn                  = lookup(disk.value, "wwn", null)
      mbps_r_burst         = lookup(disk.value, "mbps_r_burst", 0.0)
      mbps_r_concurrent    = lookup(disk.value, "mbps_r_concurrent", 0.0)
      mbps_wr_burst        = lookup(disk.value, "mbps_wr_burst", 0.0)
      mbps_wr_concurrent   = lookup(disk.value, "mbps_wr_concurrent", 0.0)
      iops_r_burst         = lookup(disk.value, "iops_r_burst", 0)
      iops_r_burst_length  = lookup(disk.value, "iops_r_burst_length", 0)
      iops_r_concurrent    = lookup(disk.value, "iops_r_concurrent", 0)
      iops_wr_burst        = lookup(disk.value, "iops_wr_burst", 0)
      iops_wr_burst_length = lookup(disk.value, "iops_wr_burst_length", 0)
      iops_wr_concurrent   = lookup(disk.value, "iops_wr_concurrent", 0)
    }
  }

  # EFI Disk Block
  dynamic "efidisk" {
    for_each = lookup(each.value, "efidisk", null) != null ? lookup(each.value, "efidisk") : []
    content {
      efitype           = lookup(efidisk.value, "efitype", "4m")
      storage           = lookup(efidisk.value, "storage", null)
      pre_enrolled_keys = lookup(efidisk.value, "pre_enrolled_keys", false)
    }
  }

  # PCI Block
  dynamic "pci" {
    for_each = lookup(each.value, "pci", null) != null ? lookup(each.value, "pci") : []
    content {
      id            = lookup(pci.value, "id", null)
      mapping_id    = lookup(pci.value, "mapping_id", null)
      raw_id        = lookup(pci.value, "raw_id", null)
      pcie          = lookup(pci.value, "pcie", false)
      primary_gpu   = lookup(pci.value, "primary_gpu", false)
      rombar        = lookup(pci.value, "rombar", true)
      device_id     = lookup(pci.value, "device_id", null)
      vendor_id     = lookup(pci.value, "vendor_id", null)
      sub_device_id = lookup(pci.value, "sub_device_id", null)
      sub_vendor_id = lookup(pci.value, "sub_vendor_id", null)
      mdev          = lookup(pci.value, "mdev", null)
    }
  }

  # Serial Block
  dynamic "serial" {
    for_each = lookup(each.value, "serial", null) != null ? lookup(each.value, "serial") : []
    content {
      id   = lookup(serial.value, "id", null)
      type = lookup(serial.value, "type", "socket")
    }
  }

  # TPM Block
  dynamic "tpm_state" {
    for_each = lookup(each.value, "tpm_state", null) != null ? lookup(each.value, "tpm_state") : []
    content {
      storage = lookup(tpm_state.value, "storage")
      version = lookup(tpm_state.value, "version", null)
    }
  }

  # USB Block
  dynamic "usb" {
    for_each = lookup(each.value, "usb", null) != null ? lookup(each.value, "usb") : []
    content {
      id         = lookup(usb.value, "id", null)
      device_id  = lookup(usb.value, "device_id", null)
      mapping_id = lookup(usb.value, "mapping_id", null)
      port_id    = lookup(usb.value, "port_id", null)
      usb3       = lookup(usb.value, "usb3", false)
    }
  }

  # RNG Block
  dynamic "rng" {
    for_each = lookup(each.value, "rng", null) != null ? lookup(each.value, "rng") : []
    content {
      source = lookup(rng.value, "source", null)
      limit  = lookup(rng.value, "limit", null)
      period = lookup(rng.value, "period", null)
    }
  }

  # SMBIOS Block
  dynamic "smbios" {
    for_each = lookup(each.value, "smbios", null) != null ? lookup(each.value, "smbios") : []
    content {
      family       = lookup(smbios.value, "family", null)
      manufacturer = lookup(smbios.value, "manufacturer", null)
      serial       = lookup(smbios.value, "serial", null)
      product      = lookup(smbios.value, "product", null)
      sku          = lookup(smbios.value, "sku", null)
      uuid         = lookup(smbios.value, "uuid", null)
      version      = lookup(smbios.value, "version", null)
    }
  }
}
