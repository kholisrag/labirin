locals {
  provider_vars    = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  account_vars     = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  region_vars      = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  environment_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  provider_id      = local.provider_vars.locals.provider_id
  aws_account_id   = local.account_vars.locals.creds_yaml.aws_account_id
  aws_account_name = local.account_vars.locals.creds_yaml.aws_account_name
  aws_region       = local.region_vars.locals.region
  environment      = local.environment_vars.locals.environment
}

terraform {
  source = format("%s/modules/opentofu/kubernetes/manifests/eks//0.1.0", get_repo_root())
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

dependency "eks" {
  config_path = format("%s/../../../eks/cluster/kloia-test", get_terragrunt_dir())
}

dependencies {
  paths = [
    "../bootstraping",
  ]
}

inputs = {
  eks_cluster_name = dependency.eks.outputs.eks.cluster_name
  kubectl_manifest_files = {
    "repository"   = sops_decrypt_file(format("%s/repository.enc.yaml", get_terragrunt_dir())),
    "app_project"  = sops_decrypt_file(format("%s/app_project.enc.yaml", get_terragrunt_dir())),
    "applications" = sops_decrypt_file(format("%s/applications.enc.yaml", get_terragrunt_dir())),
  }
}
