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

resource "proxmox_virtual_environment_file" "file" {
  for_each = local.files

  datastore_id = lookup(each.value, "datastore_id", null)
  node_name    = lookup(each.value, "node_name", null)

  content_type   = lookup(each.value, "content_type", null)
  overwrite      = lookup(each.value, "overwrite", null)
  timeout_upload = lookup(each.value, "timeout_upload", null)

  dynamic "source_file" {
    for_each = lookup(each.value, "source_file", null) != null ? [lookup(each.value, "source_file", null)] : []
    content {
      checksum  = lookup(source_file.value, "checksum", null)
      file_name = lookup(source_file.value, "file_name", null)
      insecure  = lookup(source_file.value, "insecure", null)
      min_tls   = lookup(source_file.value, "min_tls", null)
      path      = lookup(source_file.value, "path", null)
    }
  }

  dynamic "source_raw" {
    for_each = lookup(each.value, "source_raw", null) != null ? [lookup(each.value, "source_raw", null)] : []
    content {
      data      = lookup(source_raw.value, "data", null)
      file_name = lookup(source_raw.value, "file_name", null)
      resize    = lookup(source_raw.value, "resize", null)
    }
  }
}
