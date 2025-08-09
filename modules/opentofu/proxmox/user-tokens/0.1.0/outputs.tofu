output "proxmox_virtual_environment_user_token_output" {
  description = "Proxmox VE User Token Outputs"
  value       = proxmox_virtual_environment_user_token.user_token
  sensitive   = true
}
