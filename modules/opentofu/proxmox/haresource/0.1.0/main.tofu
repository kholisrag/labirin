resource "proxmox_virtual_environment_haresource" "haresource" {
  resource_id  = lookup(var.haresource, "resource_id", null)
  comment      = lookup(var.haresource, "comment", null)
  group        = lookup(var.haresource, "group", null)
  max_relocate = lookup(var.haresource, "max_relocate", null)
  max_restart  = lookup(var.haresource, "max_restart", null)
  state        = lookup(var.haresource, "state", null)
  type         = lookup(var.haresource, "type", null)
}
