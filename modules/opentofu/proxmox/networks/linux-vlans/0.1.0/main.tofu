locals {
  vlans = {
    for i, vlan in var.vlans : i => merge(
      {
        vlan_id = i
      },
      vlan
    )
  }
}

resource "proxmox_virtual_environment_network_linux_vlan" "vlan" {
  for_each = local.vlans

  name      = lookup(each.value, "name", null)
  node_name = lookup(each.value, "node_name", null)

  address   = lookup(each.value, "address", null)
  address6  = lookup(each.value, "address6", null)
  autostart = lookup(each.value, "autostart", true)
  comment   = lookup(each.value, "comment", null)
  gateway   = lookup(each.value, "gateway", null)
  gateway6  = lookup(each.value, "gateway6", null)
  interface = lookup(each.value, "interface", null)
  mtu       = lookup(each.value, "mtu", null)
  vlan      = lookup(each.value, "vlan", null)
}
