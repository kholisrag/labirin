locals {
  user_tokens = {
    for i, user_token in var.user_tokens : i => merge(
      {
        user_token_id = i
      },
      user_token
    )
  }
}

resource "proxmox_virtual_environment_user_token" "user_token" {
  for_each = local.user_tokens

  user_id    = lookup(each.value, "user_id", null)
  token_name = lookup(each.value, "token_name", null)

  comment               = lookup(each.value, "comment", null)
  expiration_date       = lookup(each.value, "expiration_date", null)
  privileges_separation = lookup(each.value, "privileges_separation", false)
}
