resource "proxmox_virtual_environment_time" "time" {
  node_name = lookup(var.time, "node_name", null)
  time_zone = lookup(var.time, "time_zone", "UTC")
}
