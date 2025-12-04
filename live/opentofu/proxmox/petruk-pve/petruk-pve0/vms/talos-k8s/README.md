# Talos Proxmox VMs

This directory contains the Terragrunt configuration files for managing Talos Kubernetes nodes on Proxmox VE using OpenTofu.

## Known Issues

1. After initializing the Talos cluster, the ISO image is no longer needed for the worker nodes. Therefore, the `cdrom` configuration has been commented out to prevent booting from the ISO again and the boot order has been adjusted to prioritize the disk, as you can see in the ansible playbook [talos-cluster-init.yaml](../../../../../../ansible/playbooks/talos-k8s/talos-cluster-init.yaml#L315). But there is strange behavior when I want to sync the changes using `terragrunt apply` command, basically what we need is to change the `cdrom.file_id` to `none` first, then apply the changes, and after that we need to change the `boot_order` to only boot from the disk (`scsi0`), and apply the changes again. Still don't know why it can't be done in a single `terragrunt apply` command.
