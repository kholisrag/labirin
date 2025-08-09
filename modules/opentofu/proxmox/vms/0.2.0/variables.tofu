
variable "vms" {
  description = <<-EOT
    Map of VM objects to create.

    Each VM can optionally include a `cloud_init` block with the following structure:
    cloud_init = {
      datastore_id = "local"  # Optional, defaults to "local"
      interface    = "ide2"   # Optional, defaults to "ide2"
      user_data    = "..."    # Required: cloud-config YAML content
      network_data = "..."    # Optional: network config YAML content
      meta_data    = "..."    # Optional: metadata YAML content
      vendor_data  = "..."    # Optional: vendor data YAML content
    }

    When cloud_init is provided, snippet files will be automatically created
    and referenced in the VM's initialization block.
  EOT
  type        = any
}
