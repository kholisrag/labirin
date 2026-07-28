locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  name  = "rustfs-01"
  vm_id = 112

  network_yaml = {
    for idx, mac_addresses in yamldecode(sops_decrypt_file(format("%s/network.enc.yaml", get_terragrunt_dir()))).mac_addresses :
    mac_addresses.name => mac_addresses
  }

  # ------------------------------------------------------------------
  # Sizing
  # ------------------------------------------------------------------
  # RustFS is a single static Rust binary - no Compose stack, no database, no
  # JVM - so the CPU here is for erasure-coding maths and TLS-less HTTP, not
  # for a fleet of sidecars. 2 cores x 2 sockets = 4 vCPU, matching Harbor,
  # which is generous for a single-volume deployment and leaves room for the
  # background scanner (RUSTFS_SCANNER_*) to do its bitrot sweeps without
  # starving request handling.
  vm_cpu_cores   = 2
  vm_cpu_sockets = 2

  # RustFS's own guidance is 2 GiB minimum for testing and 128 GiB for
  # production - a spread wide enough to be useless as a homelab input. 8 GiB
  # is chosen for what the memory is actually *for* here: RustFS does no
  # in-process caching of object data, so almost all of this ends up as page
  # cache in front of the data volume. More RAM means more of the hot object
  # set served without touching the SAS array.
  #
  # Ballooning IS enabled (floating < dedicated). Reclaiming page cache from an
  # object store costs latency on the next read, not correctness, and
  # petruk-pve0 is heavily allocated already (see the Harbor and Fireactions
  # units), so a VM that can hand memory back is worth more than one that pins
  # it.
  vm_memory_mib          = 8192
  vm_memory_floating_mib = 4096

  # Root device: OS only. The RustFS binary is ~100 MiB at /usr/local/bin and
  # its logs live at /var/log/rustfs with a 2 GiB total budget
  # (RUSTFS_OBS_LOG_MAX_TOTAL_SIZE_BYTES). Nothing else grows here - object
  # data is on the dedicated device below - so this is smaller than Harbor's
  # 50 GiB, which had to hold Docker images.
  vm_root_disk_size = 40

  # ------------------------------------------------------------------
  # Object data
  # ------------------------------------------------------------------
  # SNSD - Single Node, Single Disk. One volume, so RustFS does NOT erasure
  # code: RUSTFS_VOLUMES is a single path and the loss of this device is the
  # loss of the data. That is a deliberate trade, not an oversight:
  #
  #   * SNMD across 4 virtual disks would cost ~50% of raw capacity to parity
  #     while every one of those disks still sits on the same PVE datastore -
  #     the failure domain barely narrows, the capacity halves.
  #   * The redundancy that actually applies here is the array under `sas` plus
  #     the PVE backup below, not RustFS-level parity.
  #
  # Moving to SNMD later is a rebuild, not a resize: RustFS writes its erasure
  # layout at first format. Attach three more disks, wipe /data, and set
  # rustfs_volumes to "/data/rustfs{0...3}" in the Ansible vars.
  #
  # STORAGE PLACEMENT - `sas` rather than `local-lvm`. local-lvm is a thin pool
  # whose *allocation* is already the binding constraint on this node (see the
  # storage budget note in the Harbor unit, which is what shrank the Fireactions
  # disks), so it is the wrong place for a store meant to grow. `sas` is a
  # 1.07 TiB directory datastore with ~1.01 TiB free and almost nothing on it;
  # `ssd` has ~687 GiB free but also carries the cloud-init snippets and the ISO
  # library. The OS disk stays on local-lvm as instructed.
  #
  # 200 GiB is a starting allocation, not a ceiling. Growing it is:
  #   1. raise vm_data_disk_size here and apply
  #   2. `sudo xfs_growfs /data/rustfs0` in the guest
  # XFS grows online and cannot shrink, so starting small is the reversible
  # direction.
  vm_data_disk_size    = 200
  vm_data_disk_serial  = "rustfs-data0"
  vm_data_datastore_id = "sas"
}

terraform {
  source = "git::https://github.com/kholisrag/iac-modules.git?ref=proxmox-vms/v0.1.0"
}

prevent_destroy = false

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  vms = {
    "rustfs-01" = {
      cloud_init = {
        datastore_id = "ssd"
        user_data    = sops_decrypt_file(format("%s/user-data.enc.yaml", get_terragrunt_dir()))
        network_data = sops_decrypt_file(format("%s/network-config.enc.yaml", get_terragrunt_dir()))
        meta_data = yamlencode({
          "instance-id"    = local.name
          "vm-id"          = local.vm_id
          "vm-name"        = local.name
          "local-hostname" = format("%s.homelab", local.name)
        })
      }

      name                = local.name
      node_name           = local.node_vars.locals.node
      vm_id               = local.vm_id
      description         = "RustFS S3-compatible object storage (SNSD)"
      bios                = "ovmf"
      machine             = "q35"
      started             = true
      protection          = false
      on_boot             = true
      reboot_after_update = true
      scsi_hardware       = "virtio-scsi-single"
      pool_id             = "virtualmachines-pool"
      tags                = ["storage", "s3", "rustfs"]

      # Order 4, the same tier as Harbor. Both are infrastructure that the
      # order-5 workloads (Fireactions, cantrik-ci) may want to reach on a cold
      # boot of the node - an S3 endpoint that comes up after its consumers is
      # a pile of retry noise in someone's job log.
      startup = [
        {
          order      = 4
          up_delay   = 30
          down_delay = 30
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
      cpu = [
        {
          cores   = local.vm_cpu_cores
          type    = "x86-64-v2-AES"
          sockets = local.vm_cpu_sockets
          numa    = true
          flags   = ["+aes"]
        }
      ]
      memory = [
        {
          dedicated = local.vm_memory_mib
          floating  = local.vm_memory_floating_mib
        }
      ]

      vga = [
        {
          type = "serial0"
        }
      ]
      network_device = [
        {
          bridge      = "vmbr1"
          model       = "virtio"
          mac_address = local.network_yaml[local.name].mac_address
          queues      = 4
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
        # BACKED UP, unlike Harbor's data disk. Harbor's /data is a cache whose
        # every byte re-pulls from the internet on demand; this one holds the
        # only copy of whatever gets written to the buckets. With a single
        # volume there is no erasure coding to recover from, so the PVE backup
        # IS the durability story. If a bucket here ever becomes a mirror of
        # something else that is authoritative, revisit this - a 200 GiB job is
        # not free.
        #
        # Addressed in the guest as
        # /dev/disk/by-id/scsi-SQEMU_QEMU_HARDDISK_rustfs-data0 - note the "S"
        # prefix QEMU adds to a user-set serial - which is stable across
        # reboots in a way /dev/sdb is not.
        {
          interface    = "scsi1"
          datastore_id = local.vm_data_datastore_id
          size         = local.vm_data_disk_size
          serial       = local.vm_data_disk_serial
          cache        = "none"
          discard      = "on"
          aio          = "io_uring"
          backup       = true
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
}
