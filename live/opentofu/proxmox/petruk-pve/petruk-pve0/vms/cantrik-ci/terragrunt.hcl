locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  network_yaml = {
    for idx, mac_addresses in yamldecode(sops_decrypt_file(format("%s/network.enc.yaml", get_terragrunt_dir()))).mac_addresses :
    mac_addresses.name => mac_addresses
  }

  # ------------------------------------------------------------------
  # cantrik-ci - the ONE runner that is allowed to hold /dev/kvm
  # ------------------------------------------------------------------
  # <repo>'s CI has two tiers, split by what can host /dev/kvm rather than by
  # speed (<repo> ADR-0035):
  #
  #   Tier 0  builds, unit tests, `tofu validate`, and the kernel BUILD.
  #           Runs on fireactions, one ephemeral Firecracker microVM per job.
  #
  #   Tier 1  boot a real Machine on the Firecracker/jailer/kernel under test
  #           and SSH into it. This is the ONLY test that proves such a bump,
  #           and it cannot run on fireactions.
  #
  # Why it cannot: a fireactions job runs INSIDE a Firecracker microVM, and
  # Firecracker cannot expose VMX/SVM to its guest (<repo> ADR-0021). So a
  # fireactions runner has no /dev/kvm and cannot start a Machine. There is no
  # fireactions configuration that fixes this - it is a property of the VMM.
  #
  # Hence a plain, manually-installed GitHub Actions runner on a VM with
  # `cpu type = "host"`. No orchestrator, no microVM wrapper.
  #
  # SEPARATE FROM THE WORKERS, DELIBERATELY. A self-hosted runner executes
  # repository code as a privileged job on a box holding /dev/kvm. Putting that
  # on cantrik-01/02/03 would be a direct path from "a bot opened a PR" to root
  # beside other Users' Machines. This bounds the blast radius; it does not
  # eliminate it, because a breakout still lands on petruk-pve0, which <repo>
  # ADR-0026 already says the Workers share.
  #
  # MEMORY BUDGET - petruk-pve0 is ALREADY OVERCOMMITTED on allocation. The
  # fireactions unit records 251.5 GiB physical against 274.0 GiB allocated.
  # This VM adds 8 GiB, so read that comment before growing it.
  #
  # 8 GiB is deliberate and is why the split above matters: the kernel build is
  # the memory-hungry job and it does NOT need KVM, so it stays on fireactions
  # where the pool already has 32 GiB per host. What runs here is one Machine
  # boot at a time, and `design.md` §5.3 benchmarks a 4-Machine Playground at
  # 2,326 ms - this is a small, short job on a small box.
  hosts = {
    "cantrik-ci-01" = { vm_id = 111 }
  }

  # 2 cores x 2 sockets = 4 vCPU. Enough to boot a Machine and run its Checks;
  # not enough to tempt anyone into moving the kernel build here.
  vm_cpu_cores   = 2
  vm_cpu_sockets = 2
  vm_memory_mib  = 8192

  # Root holds the runner, its work directory, and whatever rootfs and vmlinux a
  # Tier 1 job pulls. Nothing here is precious - the whole VM is reproducible
  # from this file plus the playbook.
  vm_root_disk_size = 60

  vm_defaults = {
    node_name           = local.node_vars.locals.node
    bios                = "ovmf"
    machine             = "q35"
    started             = true
    protection          = false
    on_boot             = true
    reboot_after_update = true
    scsi_hardware       = "virtio-scsi-single"
    pool_id             = "virtualmachines-pool"
    tags                = ["ci", "cantrik-ci", "<org>"]

    # Starts after the fireactions hosts (order 4). Tier 1 is the rarer job and
    # nothing depends on this box being up first.
    startup = [
      {
        order      = 5
        up_delay   = 10
        down_delay = 10
      }
    ]
    agent = [
      {
        enabled = true
      }
    ]
    clone = [
      {
        vm_id = 9001 # ubuntu24-cloudinit
      }
    ]
    operating_system = [
      {
        type = "l26"
      }
    ]
    # `type = "host"` is REQUIRED and is the entire reason this VM exists.
    # Without CPU virtualization extensions passed through there is no /dev/kvm
    # in the guest, and every Tier 1 job fails at Machine start. petruk-pve0
    # runs kvm_intel.nested=Y; playbooks/pve/enable-nested-virtualization.yaml
    # makes that persistent and verifiable.
    cpu = [
      {
        cores   = local.vm_cpu_cores
        type    = "host"
        sockets = local.vm_cpu_sockets
        numa    = true
        flags   = ["+aes"]
      }
    ]
    # floating = 0, same reason as the fireactions hosts: a Firecracker Machine
    # claims real memory, and letting the host reclaim it mid-test would fail
    # jobs for a reason that looks like a Firecracker bug.
    memory = [
      {
        dedicated = local.vm_memory_mib
        floating  = 0
      }
    ]

    vga = [
      {
        type = "serial0"
      }
    ]
    efi_disk = [
      {
        datastore_id = "local-lvm"
        type         = "4m"
      }
    ]
    disk = [
      {
        interface    = "scsi0"
        datastore_id = "local-lvm"
        size         = local.vm_root_disk_size
        cache        = "none"
        aio          = "io_uring"
        backup       = false
        iothread     = true
        ssd          = true
      },
    ]
    serial_device = [
      {
        device = "socket"
      }
    ]
    rng = [
      {
        source    = "/dev/urandom"
        max_bytes = 1024
        period    = 1000
      }
    ]
  }
}

terraform {
  source = "git::https://github.com/kholisrag/iac-modules.git?ref=proxmox-vms/v0.1.0"
}

prevent_destroy = false

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  vms = { for name, host in local.hosts : name => merge(local.vm_defaults, {
    name        = name
    vm_id       = host.vm_id
    description = format("<repo> Tier 1 CI runner - the only runner with /dev/kvm (%s)", name)

    cloud_init = {
      datastore_id = "ssd"
      user_data    = sops_decrypt_file(format("%s/user-data.enc.yaml", get_terragrunt_dir()))
      network_data = sops_decrypt_file(format("%s/network-config.enc.yaml", get_terragrunt_dir()))
      meta_data = yamlencode({
        "instance-id"    = name
        "vm-id"          = host.vm_id
        "vm-name"        = name
        "local-hostname" = format("%s.homelab", name)
      })
    }

    network_device = [
      {
        bridge      = "vmbr1"
        model       = "virtio"
        mac_address = local.network_yaml[name].mac_address
        queues      = 4
      }
    ]
  }) }
}
