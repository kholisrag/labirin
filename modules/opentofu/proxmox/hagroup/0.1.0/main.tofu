resource "proxmox_virtual_environment_hagroup" "hagroup" {
  group       = lookup(var.hagroup, "group", null)
  nodes       = lookup(var.hagroup, "nodes", {})
  comment     = lookup(var.hagroup, "comment", null)
  no_failback = lookup(var.hagroup, "no_failback", false)
  restricted  = lookup(var.hagroup, "restricted", false)
}
