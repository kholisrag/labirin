output "proxmox_virtual_environment_vm_output" {
  description = "Proxmox VE VM Outputs"
  value       = proxmox_virtual_environment_vm.vm
  sensitive   = true
}

output "cloud_init_user_data_files" {
  description = "Cloud-init user data snippet files"
  value       = proxmox_virtual_environment_file.user_data_snippet
  sensitive   = true
}

output "cloud_init_network_data_files" {
  description = "Cloud-init network data snippet files"
  value       = proxmox_virtual_environment_file.network_data_snippet
  sensitive   = true
}

output "cloud_init_meta_data_files" {
  description = "Cloud-init meta data snippet files"
  value       = proxmox_virtual_environment_file.meta_data_snippet
  sensitive   = true
}

output "cloud_init_vendor_data_files" {
  description = "Cloud-init vendor data snippet files"
  value       = proxmox_virtual_environment_file.vendor_data_snippet
  sensitive   = true
}
