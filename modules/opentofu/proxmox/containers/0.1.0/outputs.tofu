output "proxmox_virtual_environment_container_output" {
  description = "Proxmox VE Container Outputs"
  value       = proxmox_virtual_environment_container.container
  sensitive   = true
}
