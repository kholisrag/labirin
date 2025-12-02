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

  name             = basename(get_terragrunt_dir())
  eks_cluster_name = "kloia-test"
  tags = {
    name        = local.name
    environment = local.environment
    region      = local.aws_region
    account     = local.aws_account_name
    opentofu    = "true"
  }
}

terraform {
  source = format("%s/modules/opentofu/aws/eks-pod-identity//2.5.0", get_repo_root())
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

prevent_destroy = false

inputs = {
  create = true
  name   = local.name
  region = local.aws_region
  tags   = local.tags

  attach_aws_ebs_csi_policy = true
  associations = {
    this = {
      cluster_name    = local.eks_cluster_name
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
    }
  }
}
