resource "proxmox_virtual_environment_dns" "dns" {
  domain    = lookup(var.dns, "domain", null)
  node_name = lookup(var.dns, "node_name", null)
  servers   = lookup(var.dns, "servers", [])
}
