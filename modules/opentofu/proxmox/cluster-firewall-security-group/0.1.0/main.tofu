resource "proxmox_virtual_environment_cluster_firewall_security_group" "firewall_security_group" {
  name    = lookup(var.firewall_security_group, "name", null)
  comment = lookup(var.firewall_security_group, "comment", null)

  dynamic "rule" {
    for_each = lookup(var.firewall_security_group, "rule", {})
    content {
      action  = lookup(rule.value, "action", null)
      type    = lookup(rule.value, "type", null)
      comment = lookup(rule.value, "comment", null)
      dest    = lookup(rule.value, "dest", null)
      enable  = lookup(rule.value, "enable", false)
      iface   = lookup(rule.value, "iface", null)
      log     = lookup(rule.value, "log", null)
      macro   = lookup(rule.value, "macro", null)
      proto   = lookup(rule.value, "proto", null)
      source  = lookup(rule.value, "source", null)
      sport   = lookup(rule.value, "sport", null)
    }
  }
}
