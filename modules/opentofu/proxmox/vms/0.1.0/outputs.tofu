output "vms" {
  description = "Map of all VM resources"
  value       = proxmox_vm_qemu.vm
  sensitive   = true
}

output "vm_ids" {
  description = "Map of VM names to their VMIDs"
  value = {
    for name, vm in proxmox_vm_qemu.vm : name => vm.vmid
  }
  sensitive = false
}

output "vm_ips" {
  description = "Map of VM names to their default IP addresses"
  value = {
    for name, vm in proxmox_vm_qemu.vm : name => vm.default_ipv4_address
  }
  sensitive = false
}

output "vm_ssh_hosts" {
  description = "Map of VM names to their SSH host addresses"
  value = {
    for name, vm in proxmox_vm_qemu.vm : name => vm.ssh_host
  }
  sensitive = false
}

output "vm_nodes" {
  description = "Map of VM names to their current Proxmox nodes"
  value = {
    for name, vm in proxmox_vm_qemu.vm : name => vm.current_node
  }
  sensitive = false
}

output "cloud_init_disks" {
  description = "Map of custom Cloud Init disk resources for VMs with cloudinit configuration"
  value       = proxmox_cloud_init_disk.ci
  sensitive   = true
}

output "cloud_init_disk_ids" {
  description = "Map of VM names to their custom Cloud Init disk volume IDs"
  value = {
    for name, disk in proxmox_cloud_init_disk.ci : name => disk.id
  }
  sensitive = false
}
