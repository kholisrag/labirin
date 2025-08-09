locals {
  roles = {
    for i, role in var.roles : i => merge(
      {
        role_id = i
      },
      role
    )
  }
}

resource "proxmox_virtual_environment_role" "role" {
  for_each = local.roles

  role_id    = lookup(each.value, "role_id", null)
  privileges = lookup(each.value, "privileges", null)
}
