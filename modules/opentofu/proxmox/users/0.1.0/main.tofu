locals {
  users = {
    for i, user in var.users : i => merge(
      {
        user_id = i
      },
      user
    )
  }
}

resource "proxmox_virtual_environment_user" "user" {
  for_each = local.users

  user_id         = lookup(each.value, "user_id", null)
  comment         = lookup(each.value, "comment", null)
  email           = lookup(each.value, "email", null)
  enabled         = lookup(each.value, "enabled", null)
  expiration_date = lookup(each.value, "expiration_date", null)
  first_name      = lookup(each.value, "first_name", null)
  groups          = lookup(each.value, "groups", null)
  keys            = lookup(each.value, "keys", null)
  last_name       = lookup(each.value, "last_name", null)
  password        = lookup(each.value, "password", null)

  dynamic "acl" {
    for_each = lookup(each.value, "acl", [])
    content {
      path      = acl.value.path
      propagate = acl.value.propagate
      role_id   = acl.value.role_id
    }
  }
}
