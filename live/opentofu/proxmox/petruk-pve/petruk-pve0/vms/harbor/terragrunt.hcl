locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  name  = "harbor-01"
  vm_id = 103

  network_yaml = {
    for idx, mac_addresses in yamldecode(sops_decrypt_file(format("%s/network.enc.yaml", get_terragrunt_dir()))).mac_addresses :
    mac_addresses.name => mac_addresses
  }

  # ------------------------------------------------------------------
  # Sizing
  # ------------------------------------------------------------------
  # Harbor's own hardware guidance is 2 vCPU / 4 GiB / 40 GiB minimum and
  # 4 vCPU / 8 GiB / 160 GiB recommended. This box sits at the recommended
  # tier: the VM runs Postgres, Redis, the registry, the jobservice and nginx.
  #
  # 2 cores x 2 sockets = 4 vCPU.
  vm_cpu_cores   = 2
  vm_cpu_sockets = 2

  # 8 GiB is the recommended tier and NOT the 16 GiB a full Harbor deployment
  # wants, because Trivy is not deployed here - robertdebock.harbor runs
  # `./install.sh` with no flags, and Trivy only ships when it is invoked as
  # `./install.sh --with-trivy`. Scanning a pull-through cache would mean
  # scanning the whole internet, so that is the right default; adding it later
  # means raising this number.
  #
  # Ballooning IS enabled here (floating < dedicated), unlike the Fireactions
  # hosts. Harbor is a cache in front of the internet - a stalled pull is a
  # slow CI job, not a destroyed one - so letting the node reclaim memory from
  # it under pressure is the right trade. petruk-pve0 is overcommitted on
  # allocation (see the Fireactions unit), so a VM that can give memory back is
  # worth more here than a VM that holds it.
  vm_memory_mib          = 8192
  vm_memory_floating_mib = 4096

  # Root device: OS, Docker engine, and the Harbor component images
  # (~4 GiB of them). The Harbor install tree lives at /home/harbor.
  vm_root_disk_size = 50

  # Dedicated device for /data - registry blobs, Postgres, Redis, the Trivy
  # vulnerability DB and the job logs. Thin-provisioned, so this is a ceiling
  # rather than an upfront allocation. Addressed in the guest as
  # /dev/disk/by-id/scsi-SQEMU_QEMU_HARDDISK_<serial> (note the "S" prefix for
  # a user-set serial), which is stable across reboots unlike /dev/sdb.
  #
  # 300 GiB is sized for the proxy-cache workload rather than for Harbor's
  # 160 GiB recommendation: every layer any homelab CI job pulls from Docker
  # Hub or ghcr.io lands here and is held for the project's retention window.
  # Proxy-cache projects get a 7-day retention policy by default, so this is a
  # working set, not an archive - but a week of runner images plus whatever a
  # `docker build` drags in adds up faster than the recommendation assumes.
  #
  # STORAGE BUDGET - local-lvm is a 1.71 TiB thin pool, ~30% actually used but
  # heavily *allocated*. Adding these two disks costs 350 GiB of allocation,
  # which is why the Fireactions containerd disks were cut from 200 GiB to
  # 100 GiB in the same change (they measured 1.36% used across 4 microVMs).
  # Net allocation after both: ~1.49 TiB of 1.71 TiB.
  vm_data_disk_size   = 300
  vm_data_disk_serial = "harbor-data"
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
    "harbor-01" = {
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
      description         = "Harbor Container Registry / pull-through proxy cache VM"
      bios                = "ovmf"
      machine             = "q35"
      started             = true
      protection          = false
      on_boot             = true
      reboot_after_update = true
      scsi_hardware       = "virtio-scsi-single"
      pool_id             = "virtualmachines-pool"
      tags                = ["registry", "harbor"]

      # Starts BEFORE the Fireactions hosts (order 5). Those hosts now pull
      # their microVM runner image through this registry's ghcr.io proxy cache,
      # so a cold boot of the node has to bring Harbor up first or the pools
      # spend their first minutes failing to refill.
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
        # Excluded from backups. Almost every byte is a cached upstream image
        # layer that re-pulls on demand, and a 300 GiB job would dwarf every
        # other backup on the node. The rest - projects, registry endpoints,
        # retention policies, robot accounts - is declared in
        # live/ansible/playbooks/harbor/vars/main.yaml and re-applied by the
        # playbook, so the reproducible path is "re-run Ansible", not "restore".
        {
          interface    = "scsi1"
          datastore_id = "local-lvm"
          size         = local.vm_data_disk_size
          serial       = local.vm_data_disk_serial
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
}
