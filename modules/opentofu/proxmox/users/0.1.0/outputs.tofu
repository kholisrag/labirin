output "proxmox_virtual_environment_user_output" {
  description = "Proxmox VE User Outputs"
  value       = proxmox_virtual_environment_user.user
  sensitive   = true
}
