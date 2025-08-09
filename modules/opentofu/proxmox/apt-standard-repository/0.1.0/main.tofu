resource "proxmox_virtual_environment_apt_standard_repository" "apt_standard_repository" {
  handle = lookup(var.apt_standard_repository, "handle", null)
  node   = lookup(var.apt_standard_repository, "node", null)
}
