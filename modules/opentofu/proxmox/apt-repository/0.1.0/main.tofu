resource "proxmox_virtual_environment_apt_repository" "apt_repository" {
  file_path = lookup(var.apt_repository, "file_path", null)
  index     = lookup(var.apt_repository, "index", null)
  node      = lookup(var.apt_repository, "node", null)
  enabled   = lookup(var.apt_repository, "enabled", false)
}
