locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  network_yaml = {
    for idx, mac_addresses in yamldecode(sops_decrypt_file(format("%s/network.enc.yaml", get_terragrunt_dir()))).mac_addresses :
    mac_addresses.name => mac_addresses
  }

  # ------------------------------------------------------------------
  # Fireactions hosts
  # ------------------------------------------------------------------
  # A Fireactions pool is host-local: each host independently maintains its own
  # `replicas` count and there is no cross-host scheduler. Several hosts form
  # one logical pool purely by sharing the same runner labels, so scaling out is
  # "add an entry here, add it to the Ansible inventory, re-run the playbook".
  #
  # Adding a host requires a matching entry in network.enc.yaml for the MAC.
  #
  # MEMORY BUDGET - petruk-pve0 is currently OVERCOMMITTED on allocation.
  #   Physical 251.5 GiB, allocated 274.0 GiB (+22.5 GiB) with these two hosts.
  #   Only ~83 GiB is actually touched today, so nothing is hurting yet - guest
  #   RAM is faulted in lazily, and "allocated" is the commitment, not the
  #   usage.
  #
  #   The swing factor is cantrik-01/02/03: 120 GiB allocated, ~9 GiB touched,
  #   and balloon=0 so none of it can be reclaimed as Talos takes on workload.
  #   1panel is NOT slack either - it holds all 64 GiB and its guest genuinely
  #   uses ~49 GiB. If the node needs headroom back, shrink cantrik (or give it
  #   a balloon), not these hosts.
  #
  #   NOTE: shrinking the Fireactions pools does NOT relieve host memory
  #   pressure. floating = 0 means Proxmox commits the full `vm_memory_mib`
  #   regardless of how many microVMs are running inside. Only this value moves
  #   the host-level number.
  #
  #   Note also that two hosts on the SAME Proxmox node add no throughput -
  #   they partition the same cores. They buy blast-radius isolation and
  #   rolling upgrades. Real scale-out needs a second node.
  hosts = {
    "fireactions-01" = { vm_id = 109 }
    "fireactions-02" = { vm_id = 110 }
  }

  # 4 cores x 2 sockets = 8 vCPU per host.
  vm_cpu_cores   = 4
  vm_cpu_sockets = 2
  vm_memory_mib  = 32768

  # Root device.
  vm_root_disk_size = 50

  # Dedicated device for the Containerd devmapper thin pool. Thin-provisioned,
  # so this is a ceiling rather than an upfront allocation. Addressed in the
  # guest as /dev/disk/by-id/scsi-SQEMU_QEMU_HARDDISK_<serial> (note the "S"
  # prefix for a user-set serial), which is stable across reboots unlike
  # /dev/sdb.
  vm_containerd_disk_size   = 200
  vm_containerd_disk_serial = "containerd"

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
    tags                = ["ci", "fireactions"]

    startup = [
      {
        order      = 4
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
    # `type = "host"` is REQUIRED: Firecracker needs /dev/kvm inside the guest,
    # which only works when the host CPU virtualization extensions are passed
    # through. petruk-pve0 already runs with kvm_intel.nested=Y; the playbook
    # live/ansible/playbooks/pve/enable-nested-virtualization.yaml makes that
    # persistent and verifiable.
    cpu = [
      {
        cores   = local.vm_cpu_cores
        type    = "host"
        sockets = local.vm_cpu_sockets
        numa    = true
        flags   = ["+aes"]
      }
    ]
    # Ballooning is disabled (floating = 0) on purpose. Firecracker microVMs
    # claim real memory, so letting the host reclaim it under pressure would
    # kill in-flight CI jobs. This is what makes these VMs hard-committed
    # against the node's memory budget.
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
        backup       = true
        iothread     = true
        ssd          = true
      },
      # Excluded from backups: every byte on it is a reproducible container
      # image layer, and it is wiped into an LVM thin pool by Ansible.
      {
        interface    = "scsi1"
        datastore_id = "local-lvm"
        size         = local.vm_containerd_disk_size
        serial       = local.vm_containerd_disk_serial
        cache        = "none"
        discard      = "on"
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
    description = format("Fireactions GitHub Actions Runner Orchestrator VM (%s)", name)

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
        queues      = 8
      }
    ]
  }) }
}
