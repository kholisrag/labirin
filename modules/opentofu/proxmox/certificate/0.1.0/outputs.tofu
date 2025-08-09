output "proxmox_virtual_environment_certificate_output" {
  description = "Proxmox VE Certificate Outputs"
  value       = proxmox_virtual_environment_certificate.certificate
  sensitive   = true
}
