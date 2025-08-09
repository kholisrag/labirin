resource "proxmox_virtual_environment_cluster_firewall" "firewall" {
  enabled       = lookup(var.firewall, "enabled", false)
  ebtables      = lookup(var.firewall, "ebtables", false)
  input_policy  = lookup(var.firewall, "input_policy", "DROP")
  output_policy = lookup(var.firewall, "output_policy", "ACCEPT")

  dynamic "log_ratelimit" {
    for_each = length(lookup(var.firewall, "log_ratelimit", [])) != 0 ? [lookup(var.firewall, "log_ratelimit", {})] : []
    content {
      enabled = lookup(log_ratelimit.value, "enabled", false)
      burst   = lookup(log_ratelimit.value, "burst", 5)
      rate    = lookup(log_ratelimit.value, "rate", "1/second")
    }
  }
}
