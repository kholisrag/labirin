locals {
  files = {
    for i, file in var.files : i => merge(
      {
        file_id = i
      },
      file
    )
  }
}

resource "proxmox_virtual_environment_download_file" "file" {
  for_each = local.files

  content_type = lookup(each.value, "content_type", "iso")
  datastore_id = lookup(each.value, "datastore_id", null)
  node_name    = lookup(each.value, "node_name", null)
  url          = lookup(each.value, "url", null)

  checksum                = lookup(each.value, "checksum", null)
  checksum_algorithm      = lookup(each.value, "checksum_algorithm", null)
  decompression_algorithm = lookup(each.value, "decompression_algorithm", null)
  file_name               = lookup(each.value, "file_name", null)
  overwrite               = lookup(each.value, "overwrite", null)
  overwrite_unmanaged     = lookup(each.value, "overwrite_unmanaged", null)
  upload_timeout          = lookup(each.value, "upload_timeout", 600)
  verify                  = lookup(each.value, "verify", true)
}
