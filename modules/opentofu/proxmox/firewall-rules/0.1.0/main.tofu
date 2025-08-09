locals {
  firewall_rules = {
    for i, firewall_rule in var.firewall_rules : i => merge(
      {
        firewall_rule_id = i
      },
      firewall_rule
    )
  }
}

resource "proxmox_virtual_environment_firewall_rules" "firewall_rules" {
  for_each = local.firewall_rules

  node_name    = lookup(each.value, "node_name", null)
  vm_id        = lookup(each.value, "vm_id", null)
  container_id = lookup(each.value, "container_id", null)

  dynamic "rule" {
    for_each = lookup(each.value, "rules", [])
    content {
      action         = lookup(rule.value, "action", null)
      type           = lookup(rule.value, "type", null)
      comment        = lookup(rule.value, "comment", null)
      dest           = lookup(rule.value, "dest", null)
      dport          = lookup(rule.value, "dport", null)
      enabled        = lookup(rule.value, "enabled", false)
      iface          = lookup(rule.value, "iface", null)
      log            = lookup(rule.value, "log", null)
      macro          = lookup(rule.value, "macro", null)
      proto          = lookup(rule.value, "proto", null)
      source         = lookup(rule.value, "source", null)
      sport          = lookup(rule.value, "sport", null)
      security_group = lookup(rule.value, "security_group", null)
    }
  }
}
