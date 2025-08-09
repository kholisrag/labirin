locals {
  pools = {
    for i, pool in var.pools : i => merge(
      {
        pool_id = i
      },
      pool
    )
  }
}

resource "proxmox_virtual_environment_pool" "pool" {
  for_each = local.pools

  pool_id = lookup(each.value, "pool_id", null)
  comment = lookup(each.value, "comment", null)
}
