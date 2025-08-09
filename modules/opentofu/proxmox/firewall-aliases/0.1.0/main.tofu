locals {
  firewall_aliases = {
    for i, firewall_alias in var.firewall_aliases : i => merge(
      {
        firewall_alias_id = i
      },
      firewall_alias
    )
  }
}

resource "proxmox_virtual_environment_firewall_alias" "firewall_alias" {
  for_each = local.firewall_aliases

  name = lookup(each.value, "name", null)
  cidr = lookup(each.value, "cidr", null)

  node_name    = lookup(each.value, "node_name", null)
  vm_id        = lookup(each.value, "vm_id", null)
  container_id = lookup(each.value, "container_id", null)
  comment      = lookup(each.value, "comment", null)
}
