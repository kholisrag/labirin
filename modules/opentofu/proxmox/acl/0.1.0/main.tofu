resource "proxmox_virtual_environment_acl" "acl" {
  path      = lookup(var.acl, "path", null)
  role_id   = lookup(var.acl, "role_id", null)
  group_id  = lookup(var.acl, "group_id", null)
  propagate = lookup(var.acl, "propagate", false)
  token_id  = lookup(var.acl, "token_id", null)
  user_id   = lookup(var.acl, "user_id", null)
}
