locals {
  vms = {
    for i, vm in var.vms : i => merge(
      {
        vm_id = i
      },
      vm
    )
  }

  # Extract VMs that have custom cloud-init configuration
  vms_with_cloudinit = {
    for vm_name, vm_config in local.vms : vm_name => vm_config if try(vm_config.cloud_init, null) != null
  }
}

# Cloud-init snippet files
# This creates custom cloud-init snippet files for VMs with custom cloud-init config
resource "proxmox_virtual_environment_file" "user_data_snippet" {
  for_each = local.vms_with_cloudinit

  content_type = "snippets"
  datastore_id = try(each.value.cloud_init.datastore_id, "ssd")
  node_name    = each.value.node_name

  source_raw {
    data      = sensitive(try(each.value.cloud_init.user_data, ""))
    file_name = format("tf-%s-%s-user-data.yaml", each.value.node_name, each.value.name)
  }
}

resource "proxmox_virtual_environment_file" "network_data_snippet" {
  for_each = {
    for vm_name, vm_config in local.vms_with_cloudinit : vm_name => vm_config
    if try(vm_config.cloud_init.network_data, null) != null
  }

  content_type = "snippets"
  datastore_id = try(each.value.cloud_init.datastore_id, "ssd")
  node_name    = each.value.node_name

  source_raw {
    data      = sensitive(each.value.cloud_init.network_data)
    file_name = format("tf-%s-%s-network-data.yaml", each.value.node_name, each.value.name)
  }
}

resource "proxmox_virtual_environment_file" "meta_data_snippet" {
  for_each = {
    for vm_name, vm_config in local.vms_with_cloudinit : vm_name => vm_config
    if try(vm_config.cloud_init.meta_data, null) != null
  }

  content_type = "snippets"
  datastore_id = try(each.value.cloud_init.datastore_id, "ssd")
  node_name    = each.value.node_name

  source_raw {
    data      = sensitive(each.value.cloud_init.meta_data)
    file_name = format("tf-%s-%s-meta-data.yaml", each.value.node_name, each.value.name)
  }
}

resource "proxmox_virtual_environment_file" "vendor_data_snippet" {
  for_each = {
    for vm_name, vm_config in local.vms_with_cloudinit : vm_name => vm_config
    if try(vm_config.cloud_init.vendor_data, null) != null
  }

  content_type = "snippets"
  datastore_id = try(each.value.cloud_init.datastore_id, "ssd")
  node_name    = each.value.node_name

  source_raw {
    data      = sensitive(each.value.cloud_init.vendor_data)
    file_name = format("tf-%s-%s-vendor-data.yaml", each.value.node_name, each.value.name)
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = local.vms

  acpi                = lookup(each.value, "acpi", true)
  bios                = lookup(each.value, "bios", "seabios")
  boot_order          = lookup(each.value, "boot_order", [])
  description         = lookup(each.value, "description", null)
  keyboard_layout     = lookup(each.value, "keyboard_layout", "en-us")
  kvm_arguments       = lookup(each.value, "kvm_arguments", null)
  machine             = lookup(each.value, "machine", "pc")
  migrate             = lookup(each.value, "migrate", false)
  name                = lookup(each.value, "name", null)
  node_name           = lookup(each.value, "node_name", null)
  on_boot             = lookup(each.value, "on_boot", true)
  pool_id             = lookup(each.value, "pool_id", null)
  protection          = lookup(each.value, "protection", false)
  reboot              = lookup(each.value, "reboot", false)
  reboot_after_update = lookup(each.value, "reboot_after_update", true)
  scsi_hardware       = lookup(each.value, "scsi_hardware", "virtio-scsi-pci")
  started             = lookup(each.value, "started", true)
  tablet_device       = lookup(each.value, "tablet_device", true)
  tags                = lookup(each.value, "tags", [])
  template            = lookup(each.value, "template", false)
  stop_on_destroy     = lookup(each.value, "stop_on_destroy", false)
  timeout_clone       = lookup(each.value, "timeout_clone", 1800)
  timeout_create      = lookup(each.value, "timeout_create", 1800)
  timeout_migrate     = lookup(each.value, "timeout_migrate", 1800)
  timeout_reboot      = lookup(each.value, "timeout_reboot", 1800)
  timeout_shutdown_vm = lookup(each.value, "timeout_shutdown_vm", 1800)
  timeout_start_vm    = lookup(each.value, "timeout_start_vm", 1800)
  timeout_stop_vm     = lookup(each.value, "timeout_stop_vm", 300)
  vm_id               = lookup(each.value, "vm_id", null)
  hook_script_file_id = lookup(each.value, "hook_script_file_id", null)

  dynamic "amd_sev" {
    for_each = lookup(each.value, "amd_sev", null) != null ? lookup(each.value, "amd_sev") : []
    content {
      type           = lookup(amd_sev.value, "type", "std")
      allow_smt      = lookup(amd_sev.value, "allow_smt", true)
      kernel_hashes  = lookup(amd_sev.value, "kernel_hashes", false)
      no_debug       = lookup(amd_sev.value, "no_debug", false)
      no_key_sharing = lookup(amd_sev.value, "no_key_sharing", false)
    }
  }

  dynamic "agent" {
    for_each = lookup(each.value, "agent", null) != null ? lookup(each.value, "agent") : []
    content {
      enabled = lookup(agent.value, "enabled", false)
      timeout = lookup(agent.value, "timeout", "15m")
      trim    = lookup(agent.value, "trim", false)
      type    = lookup(agent.value, "type", "virtio")
    }
  }

  dynamic "audio_device" {
    for_each = lookup(each.value, "audio_device", null) != null ? lookup(each.value, "audio_device") : []
    content {
      device  = lookup(audio_device.value, "device", "intel-had")
      driver  = lookup(audio_device.value, "driver", "spice")
      enabled = lookup(audio_device.value, "enabled", true)
    }
  }

  dynamic "cdrom" {
    for_each = lookup(each.value, "cdrom", null) != null ? lookup(each.value, "cdrom") : []
    content {
      file_id   = lookup(cdrom.value, "file_id", "cdrom")
      interface = lookup(cdrom.value, "interface", "ide3")
    }
  }

  dynamic "clone" {
    for_each = lookup(each.value, "clone", null) != null ? lookup(each.value, "clone") : []
    content {
      datastore_id = lookup(clone.value, "datastore_id", null)
      node_name    = lookup(clone.value, "node_name", null)
      retries      = lookup(clone.value, "retries", null)
      vm_id        = lookup(clone.value, "vm_id", null)
      full         = lookup(clone.value, "full", true)
    }
  }

  dynamic "cpu" {
    for_each = lookup(each.value, "cpu", null) != null ? lookup(each.value, "cpu") : []
    content {
      architecture = lookup(cpu.value, "architecture", null)
      cores        = lookup(cpu.value, "cores", 1)
      flags        = lookup(cpu.value, "flags", null)
      hotplugged   = lookup(cpu.value, "hotplugged", 0)
      limit        = lookup(cpu.value, "limit", 0)
      numa         = lookup(cpu.value, "numa", false)
      sockets      = lookup(cpu.value, "sockets", 1)
      type         = lookup(cpu.value, "type", "qemu64")
      units        = lookup(cpu.value, "units", 1024)
      affinity     = lookup(cpu.value, "affinity", null)
    }
  }

  dynamic "disk" {
    for_each = lookup(each.value, "disk", [])
    content {
      aio               = lookup(disk.value, "aio", "io_uring")
      backup            = lookup(disk.value, "backup", true)
      cache             = lookup(disk.value, "cache", "none")
      datastore_id      = lookup(disk.value, "datastore_id", "local-lvm")
      path_in_datastore = lookup(disk.value, "path_in_datastore", null)
      discard           = lookup(disk.value, "discard", "ignore")
      file_format       = lookup(disk.value, "file_format", null)
      file_id           = lookup(disk.value, "file_id", null)
      import_from       = lookup(disk.value, "import_from", null)
      interface         = lookup(disk.value, "interface", null)
      iothread          = lookup(disk.value, "iothread", false)
      replicate         = lookup(disk.value, "replicate", true)
      serial            = lookup(disk.value, "serial", null)
      size              = lookup(disk.value, "size", 8)
      ssd               = lookup(disk.value, "ssd", false)

      dynamic "speed" {
        for_each = length(lookup(disk.value, "speed", [])) != 0 ? [lookup(disk.value, "speed", null)] : []
        content {
          iops_read            = lookup(speed.value, "iops_read", 0)
          iops_read_burstable  = lookup(speed.value, "iops_read_burstable", 0)
          iops_write           = lookup(speed.value, "iops_write", 0)
          iops_write_burstable = lookup(speed.value, "iops_write_burstable", 0)
          read                 = lookup(speed.value, "read", 0)
          read_burstable       = lookup(speed.value, "read_burstable", 0)
          write                = lookup(speed.value, "write", 0)
          write_burstable      = lookup(speed.value, "write_burstable", 0)
        }
      }
    }
  }

  dynamic "efi_disk" {
    for_each = lookup(each.value, "efi_disk", null) != null ? lookup(each.value, "efi_disk") : []
    content {
      datastore_id      = lookup(efi_disk.value, "datastore_id", "local-lvm")
      file_format       = lookup(efi_disk.value, "file_format", "raw")
      type              = lookup(efi_disk.value, "type", "2m")
      pre_enrolled_keys = lookup(efi_disk.value, "pre_enrolled_keys", false)
    }
  }

  dynamic "tpm_state" {
    for_each = lookup(each.value, "tpm_state", null) != null ? lookup(each.value, "tpm_state") : []
    content {
      datastore_id = lookup(tpm_state.value, "datastore_id", "local-lvm")
      version      = lookup(tpm_state.value, "version", "v2.0")
    }
  }

  dynamic "hostpci" {
    for_each = lookup(each.value, "hostpci", [])
    content {
      device   = lookup(hostpci.value, "device", null)
      id       = lookup(hostpci.value, "id", null)
      mapping  = lookup(hostpci.value, "mapping", null)
      mdev     = lookup(hostpci.value, "mdev", null)
      pcie     = lookup(hostpci.value, "pcie", null)
      rombar   = lookup(hostpci.value, "rombar", true)
      rom_file = lookup(hostpci.value, "rom_file", null)
      xvga     = lookup(hostpci.value, "xvga", null)
    }
  }

  dynamic "usb" {
    for_each = lookup(each.value, "usb", [])
    content {
      host    = lookup(usb.value, "host", null)
      mapping = lookup(usb.value, "mapping", null)
      usb3    = lookup(usb.value, "usb3", false)
    }
  }

  dynamic "initialization" {
    for_each = lookup(each.value, "initialization", null) != null || try(each.value.cloud_init, null) != null ? [1] : []
    content {
      datastore_id = try(
        lookup(each.value.initialization[0], "datastore_id", null),
        lookup(each.value.cloud_init, "datastore_id", null),
        "local-lvm"
      )
      interface = try(
        lookup(each.value.initialization[0], "interface", null),
        lookup(each.value.cloud_init, "interface", null),
        "ide2"
      )
      # Use snippet file IDs if cloud_init is configured, otherwise use explicit file_ids
      user_data_file_id = try(
        lookup(each.value.initialization[0], "user_data_file_id", null),
        try(each.value.cloud_init, null) != null ? proxmox_virtual_environment_file.user_data_snippet[each.key].id : null,
        null
      )
      network_data_file_id = try(
        lookup(each.value.initialization[0], "network_data_file_id", null),
        try(each.value.cloud_init.network_data, null) != null ? proxmox_virtual_environment_file.network_data_snippet[each.key].id : null,
        null
      )
      meta_data_file_id = try(
        lookup(each.value.initialization[0], "meta_data_file_id", null),
        try(each.value.cloud_init.meta_data, null) != null ? proxmox_virtual_environment_file.meta_data_snippet[each.key].id : null,
        null
      )
      vendor_data_file_id = try(
        lookup(each.value.initialization[0], "vendor_data_file_id", null),
        try(each.value.cloud_init.vendor_data, null) != null ? proxmox_virtual_environment_file.vendor_data_snippet[each.key].id : null,
        null
      )

      dynamic "dns" {
        for_each = try(lookup(each.value.initialization[0], "dns", null), null) != null ? lookup(each.value.initialization[0], "dns") : []
        content {
          domain  = lookup(dns.value, "domain", null)
          servers = lookup(dns.value, "servers", null)
        }
      }

      dynamic "ip_config" {
        for_each = try(lookup(each.value.initialization[0], "ip_configs", []), [])
        content {
          dynamic "ipv4" {
            for_each = lookup(ip_config.value, "ipv4", null) != null ? lookup(ip_config.value, "ipv4") : []
            content {
              address = lookup(ipv4.value, "address", null)
              gateway = lookup(ipv4.value, "gateway", null)
            }
          }

          dynamic "ipv6" {
            for_each = lookup(ip_config.value, "ipv6", null) != null ? lookup(ip_config.value, "ipv6") : []
            content {
              address = lookup(ipv6.value, "address", null)
              gateway = lookup(ipv6.value, "gateway", null)
            }
          }
        }
      }

      dynamic "user_account" {
        for_each = try(lookup(each.value.initialization[0], "user_account", null), null) != null ? lookup(each.value.initialization[0], "user_account") : []
        content {
          keys     = lookup(user_account.value, "keys", null)
          password = lookup(user_account.value, "password", null)
          username = lookup(user_account.value, "username", null)
        }
      }
    }
  }

  dynamic "memory" {
    for_each = lookup(each.value, "memory", null) != null ? lookup(each.value, "memory") : []
    content {
      dedicated      = lookup(memory.value, "dedicated", 512)
      floating       = lookup(memory.value, "floating", 0)
      shared         = lookup(memory.value, "shared", 0)
      hugepages      = lookup(memory.value, "hugepages", null)
      keep_hugepages = lookup(memory.value, "keep_hugepages", false)
    }
  }

  dynamic "numa" {
    for_each = lookup(each.value, "numa", null) != null ? lookup(each.value, "numa") : []
    content {
      device    = lookup(numa.value, "device", null)
      cpus      = lookup(numa.value, "cpus", null)
      memory    = lookup(numa.value, "memory", null)
      hostnodes = lookup(numa.value, "hostnodes", null)
      policy    = lookup(numa.value, "policy", "preferred")
    }
  }

  dynamic "network_device" {
    for_each = lookup(each.value, "network_device", [])
    content {
      bridge       = lookup(network_device.value, "bridge", "vmbr0")
      disconnected = lookup(network_device.value, "disconnected", false)
      enabled      = lookup(network_device.value, "enabled", true)
      firewall     = lookup(network_device.value, "firewall", false)
      mac_address  = lookup(network_device.value, "mac_address", null)
      model        = lookup(network_device.value, "model", "virtio")
      mtu          = lookup(network_device.value, "mtu", null)
      queues       = lookup(network_device.value, "queues", null)
      rate_limit   = lookup(network_device.value, "rate_limit", null)
      vlan_id      = lookup(network_device.value, "vlan_id", null)
      trunks       = lookup(network_device.value, "trunks", null)
    }
  }

  dynamic "operating_system" {
    for_each = lookup(each.value, "operating_system", null) != null ? lookup(each.value, "operating_system") : []
    content {
      type = lookup(operating_system.value, "type", "other")
    }
  }

  dynamic "serial_device" {
    for_each = lookup(each.value, "serial_device", [])
    content {
      device = lookup(serial_device.value, "device", "socket")
    }
  }

  dynamic "smbios" {
    for_each = lookup(each.value, "smbios", null) != null ? lookup(each.value, "smbios") : []
    content {
      family       = lookup(smbios.value, "family", null)
      manufacturer = lookup(smbios.value, "manufacturer", null)
      product      = lookup(smbios.value, "product", null)
      serial       = lookup(smbios.value, "serial", null)
      sku          = lookup(smbios.value, "sku", null)
      uuid         = lookup(smbios.value, "uuid", null)
      version      = lookup(smbios.value, "version", null)
    }
  }

  dynamic "startup" {
    for_each = lookup(each.value, "startup", null) != null ? lookup(each.value, "startup") : []
    content {
      order      = lookup(startup.value, "order", null)
      up_delay   = lookup(startup.value, "up_delay", null)
      down_delay = lookup(startup.value, "down_delay", null)
    }
  }

  dynamic "vga" {
    for_each = lookup(each.value, "vga", null) != null ? lookup(each.value, "vga") : []
    content {
      clipboard = lookup(vga.value, "clipboard", null)
      memory    = lookup(vga.value, "memory", 16)
      type      = lookup(vga.value, "type", "std")
    }
  }

  dynamic "virtiofs" {
    for_each = lookup(each.value, "virtiofs", [])
    content {
      mapping      = lookup(virtiofs.value, "mapping", null)
      cache        = lookup(virtiofs.value, "cache", null)
      direct_io    = lookup(virtiofs.value, "direct_io", null)
      expose_acl   = lookup(virtiofs.value, "expose_acl", null)
      expose_xattr = lookup(virtiofs.value, "expose_xattr", null)
    }
  }

  dynamic "rng" {
    for_each = lookup(each.value, "rng", null) != null ? lookup(each.value, "rng") : []
    content {
      source    = lookup(rng.value, "source", "/dev/urandom")
      max_bytes = lookup(rng.value, "max_bytes", 1024)
      period    = lookup(rng.value, "period", 1000)
    }
  }

  dynamic "watchdog" {
    for_each = lookup(each.value, "watchdog", null) != null ? lookup(each.value, "watchdog") : []
    content {
      enabled = lookup(watchdog.value, "enabled", false)
      model   = lookup(watchdog.value, "model", "i6300esb")
      action  = lookup(watchdog.value, "action", "none")
    }
  }
}
