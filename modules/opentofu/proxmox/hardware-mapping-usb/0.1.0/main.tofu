resource "proxmox_virtual_environment_hardware_mapping_usb" "hardware_mapping_usb" {
  comment = lookup(var.hardware_mapping_usb, "comment", null)
  name    = lookup(var.hardware_mapping_usb, "name", null)

  dynamic "map" {
    for_each = lookup(var.hardware_mapping_usb, "map", [])
    content {
      id      = lookup(map.value, "id", null)
      node    = lookup(map.value, "node", null)
      path    = lookup(map.value, "path", null)
      comment = lookup(map.value, "comment", null)
    }
  }
}
