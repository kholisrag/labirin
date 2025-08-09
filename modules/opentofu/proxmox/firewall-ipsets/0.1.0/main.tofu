locals {
  firewall_ipsets = {
    for i, firewall_ipset in var.firewall_ipsets : i => merge(
      {
        firewall_ipset_id = i
      },
      firewall_ipset
    )
  }
}

resource "proxmox_virtual_environment_firewall_ipset" "firewall_ipset" {
  for_each = local.firewall_ipsets

  name = lookup(each.value, "name", null)

  node_name    = lookup(each.value, "node_name", null)
  vm_id        = lookup(each.value, "vm_id", null)
  container_id = lookup(each.value, "container_id", null)
  comment      = lookup(each.value, "comment", null)

  dynamic "cidr" {
    for_each = lookup(each.value, "cidr", [])
    content {
      name    = lookup(cidr.value, "name", null)
      comment = lookup(cidr.value, "comment", null)
      nomatch = lookup(cidr.value, "nomatch", null)
    }
  }
}
