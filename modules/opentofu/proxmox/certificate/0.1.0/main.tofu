resource "proxmox_virtual_environment_certificate" "certificate" {
  node_name         = lookup(var.certificate, "node_name", null)
  certificate       = lookup(var.certificate, "certificate", null)
  certificate_chain = lookup(var.certificate, "certificate_chain", null)
  private_key       = lookup(var.certificate, "private_key", null)
}
