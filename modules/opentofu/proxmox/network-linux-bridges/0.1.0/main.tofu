locals {
  bridges = {
    for i, bridge in var.bridges : i => merge(
      {
        bridge_id = i
      },
      bridge
    )
  }
}

resource "proxmox_virtual_environment_network_linux_bridge" "bridge" {
  for_each = local.bridges

  name      = lookup(each.value, "name", null)
  node_name = lookup(each.value, "node_name", null)

  address    = lookup(each.value, "address", null)
  address6   = lookup(each.value, "address6", null)
  autostart  = lookup(each.value, "autostart", true)
  comment    = lookup(each.value, "comment", null)
  gateway    = lookup(each.value, "gateway", null)
  gateway6   = lookup(each.value, "gateway6", null)
  mtu        = lookup(each.value, "mtu", null)
  ports      = lookup(each.value, "ports", null)
  vlan_aware = lookup(each.value, "vlan_aware", false)
}
