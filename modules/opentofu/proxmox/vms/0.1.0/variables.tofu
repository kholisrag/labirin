variable "pve_vms" {
  description = <<-EOT
    Map of Proxmox VMs with their configurations.
    See Proxmox documentation for complete details:
    https://github.com/Telmate/terraform-provider-proxmox/blob/master/docs/resources/vm_qemu.md
    https://github.com/Telmate/terraform-provider-proxmox/blob/master/docs/resources/cloud_init_disk.md
  EOT
  type        = any
  default     = {}
}
