locals {
  datacenter = basename(get_terragrunt_dir())
  creds      = yamldecode(sops_decrypt_file("${path_relative_from_include()}/creds.enc.yaml"))
}
