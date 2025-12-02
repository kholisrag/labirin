locals {
  datacenter = basename(get_terragrunt_dir())
  creds_yaml = yamldecode(sops_decrypt_file("${get_repo_root()}/${get_path_from_repo_root()}/creds.enc.yaml"))
}
