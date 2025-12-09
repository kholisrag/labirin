locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  k8s = {
    config_path    = "~/.kube/config"
    config_context = "admin@main-talos-k8s-cluster"
  }
}

terraform {
  source = format("%s/modules/opentofu/kubernetes/manifests/talos//0.1.0", get_repo_root())
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

dependencies {
  paths = [
    "../bootstrapping",
  ]
}

inputs = {
  k8s = local.k8s

  kubectl_manifest_files = {
    "repository"   = sops_decrypt_file(format("%s/repository.enc.yaml", get_terragrunt_dir())),
    "app_project"  = sops_decrypt_file(format("%s/app_project.enc.yaml", get_terragrunt_dir())),
    "applications" = sops_decrypt_file(format("%s/applications.enc.yaml", get_terragrunt_dir())),
  }
}
