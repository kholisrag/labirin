resource "proxmox_virtual_environment_hardware_mapping_pci" "hardware_mapping_pci" {
  comment = lookup(var.hardware_mapping_pci, "comment", null)
  name    = lookup(var.hardware_mapping_pci, "name", null)

  dynamic "map" {
    for_each = lookup(var.hardware_mapping_pci, "map", [])
    content {
      id           = lookup(map.value, "id", null)
      node         = lookup(map.value, "node", null)
      path         = lookup(map.value, "path", null)
      comment      = lookup(map.value, "comment", null)
      iommu_group  = lookup(map.value, "iommu_group", null)
      subsystem_id = lookup(map.value, "subsystem_id", null)
    }
  }
}
