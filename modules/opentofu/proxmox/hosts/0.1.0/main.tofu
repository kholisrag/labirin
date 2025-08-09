resource "proxmox_virtual_environment_hosts" "hosts" {
  node_name = lookup(var.hosts, "node_name", null)

  dynamic "entry" {
    for_each = lookup(var.hosts, "entry", [])
    content {
      address   = entry.value.address
      hostnames = entry.value.hostnames
    }
  }
}
