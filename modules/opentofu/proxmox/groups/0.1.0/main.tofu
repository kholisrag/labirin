locals {
  groups = {
    for i, group in var.groups : i => merge(
      {
        group_id = i
      },
      group
    )
  }
}

resource "proxmox_virtual_environment_group" "group" {
  for_each = local.groups

  group_id = lookup(each.value, "group_id", null)
  comment  = lookup(each.value, "comment", null)
  dynamic "acl" {
    for_each = lookup(each.value, "acl", [])
    content {
      path      = acl.value.path
      propagate = acl.value.propagate
      role_id   = acl.value.role_id
    }
  }
}
