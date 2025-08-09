locals {
  containers = {
    for i, container in var.containers : i => merge(
      {
        container_id = i
      },
      container
    )
  }
}

resource "proxmox_virtual_environment_container" "container" {
  for_each = local.containers

  description         = lookup(each.value, "description", null)
  node_name           = lookup(each.value, "node_name", null)
  pool_id             = lookup(each.value, "pool_id", null)
  started             = lookup(each.value, "started", false)
  start_on_boot       = lookup(each.value, "start_on_boot", true)
  tags                = lookup(each.value, "tags", [])
  template            = lookup(each.value, "template", false)
  timeout_create      = lookup(each.value, "timeout_create", 1800)
  timeout_clone       = lookup(each.value, "timeout_clone", 1800)
  timeout_delete      = lookup(each.value, "timeout_delete", 60)
  timeout_update      = lookup(each.value, "timeout_update", 1800)
  unprivileged        = lookup(each.value, "unprivileged", false)
  vm_id               = lookup(each.value, "vm_id", null)
  hook_script_file_id = lookup(each.value, "hook_script_file_id", null)

  dynamic "clone" {
    for_each = length(lookup(each.value, "clone", [])) != 0 ? [lookup(each.value, "clone", null)] : []
    content {
      datastore_id = lookup(clone.value, "datastore_id", null)
      node_name    = lookup(clone.value, "node_name", null)
      vm_id        = lookup(clone.value, "vm_id", null)
    }
  }

  dynamic "console" {
    for_each = length(lookup(each.value, "console", [])) != 0 ? [lookup(each.value, "console", null)] : []
    content {
      enabled   = lookup(console.value, "enabled", true)
      type      = lookup(console.value, "type", "tty")
      tty_count = lookup(console.value, "tty_count", 2)
    }
  }

  dynamic "cpu" {
    for_each = length(lookup(each.value, "cpu", [])) != 0 ? [lookup(each.value, "cpu", null)] : []
    content {
      architecture = lookup(cpu.value, "architecture", "amd64")
      cores        = lookup(cpu.value, "cores", 1)
      units        = lookup(cpu.value, "units", 1024)
    }
  }

  dynamic "disk" {
    for_each = length(lookup(each.value, "disk", [])) != 0 ? [lookup(each.value, "disk", null)] : []
    content {
      datastore_id = lookup(disk.value, "datastore_id", "local")
      size         = lookup(disk.value, "size", 8)
    }
  }

  dynamic "initialization" {
    for_each = length(lookup(each.value, "initialization", [])) != 0 ? [lookup(each.value, "initialization", null)] : []
    content {
      hostname = lookup(initialization.value, "hostname", null)

      dynamic "dns" {
        for_each = length(lookup(initialization.value, "dns", [])) != 0 ? [lookup(initialization.value, "dns", null)] : []
        content {
          domain  = lookup(dns.value, "domain", null)
          servers = lookup(dns.value, "servers", null)
          server  = lookup(dns.value, "server", null)
        }
      }

      dynamic "ip_config" {
        for_each = lookup(initialization.value, "ip_configs", [])
        content {
          dynamic "ipv4" {
            for_each = lookup(ip_config.value, "ipv4", []) != null ? [lookup(ip_config.value, "ipv4", null)] : []
            content {
              address = lookup(ipv4.value, "address", null)
              gateway = lookup(ipv4.value, "gateway", null)
            }
          }

          dynamic "ipv6" {
            for_each = lookup(ip_config.value, "ipv6", []) != null ? [lookup(ip_config.value, "ipv6", null)] : []
            content {
              address = lookup(ipv6.value, "address", null)
              gateway = lookup(ipv6.value, "gateway", null)
            }
          }
        }
      }

      dynamic "user_account" {
        for_each = length(lookup(initialization.value, "user_account", [])) != 0 ? [lookup(initialization.value, "user_account", null)] : []
        content {
          keys     = lookup(user_account.value, "keys", null)
          password = lookup(user_account.value, "password", null)
        }
      }
    }
  }

  dynamic "memory" {
    for_each = length(lookup(each.value, "memory", [])) != 0 ? [lookup(each.value, "memory", null)] : []
    content {
      dedicated = lookup(memory.value, "dedicated", 512)
      swap      = lookup(memory.value, "swap", 0)
    }
  }

  dynamic "mount_point" {
    for_each = length(lookup(each.value, "mount_point", [])) != 0 ? [lookup(each.value, "mount_point", null)] : []
    content {
      acl           = lookup(mount_point.value, "acl", null)
      backup        = lookup(mount_point.value, "backup", null)
      mount_options = lookup(mount_point.value, "mount_options", [])
      path          = lookup(mount_point.value, "path", null)
      quota         = lookup(mount_point.value, "quota", null)
      read_only     = lookup(mount_point.value, "read_only", false)
      replicate     = lookup(mount_point.value, "replicate", null)
      shared        = lookup(mount_point.value, "shared", null)
      size          = lookup(mount_point.value, "size", null)
      volume        = lookup(mount_point.value, "volume", null)
    }
  }

  dynamic "network_interface" {
    for_each = lookup(each.value, "network_interfaces", [])
    content {
      bridge      = lookup(network_interface.value, "bridge", "vmbr0")
      enabled     = lookup(network_interface.value, "enabled", true)
      firewall    = lookup(network_interface.value, "firewall", false)
      mac_address = lookup(network_interface.value, "mac_address", null)
      mtu         = lookup(network_interface.value, "mtu", null)
      name        = lookup(network_interface.value, "name", null)
      rate_limit  = lookup(network_interface.value, "rate_limit", null)
      vlan_id     = lookup(network_interface.value, "vlan_id", null)
    }
  }

  dynamic "operating_system" {
    for_each = length(lookup(each.value, "operating_system", [])) != 0 ? [lookup(each.value, "operating_system", null)] : []
    content {
      template_file_id = lookup(operating_system.value, "template_file_id", null)
      type             = lookup(operating_system.value, "type", "unmanaged")
    }
  }

  dynamic "startup" {
    for_each = length(lookup(each.value, "startup", [])) != 0 ? [lookup(each.value, "startup", null)] : []
    content {
      order      = lookup(startup.value, "order", null)
      up_delay   = lookup(startup.value, "up_delay", null)
      down_delay = lookup(startup.value, "down_delay", null)
    }
  }

  dynamic "features" {
    for_each = length(lookup(each.value, "features", [])) != 0 ? [lookup(each.value, "features", null)] : []
    content {
      nesting = lookup(features.value, "nesting", false)
      fuse    = lookup(features.value, "fuse", false)
      keyctl  = lookup(features.value, "keyctl", false)
      mount   = lookup(features.value, "mount", null)
    }
  }
}
