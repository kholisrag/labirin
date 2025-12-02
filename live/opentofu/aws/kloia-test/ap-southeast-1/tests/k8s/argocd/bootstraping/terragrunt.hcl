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

  name = basename(get_terragrunt_dir())
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

inputs = {
  eks_cluster_name = dependency.eks.outputs.eks.cluster_name

  kubectl_manifest_files = {
    "argocd_prerequisites" = sops_decrypt_file(format("%s/argocd_prerequisites.enc.yaml", get_terragrunt_dir()))
  }

  helm_releases = {
    "argocd" = {
      name             = "argocd"
      chart            = "argo-cd"
      repository       = "https://argoproj.github.io/argo-helm"
      namespace        = "argocd"
      version          = "9.0.5"
      create_namespace = true
      timeout          = "180"
      values = [
        file(format("%s/values.yaml", get_terragrunt_dir())),
        sops_decrypt_file(format("%s/secrets.enc.yaml", get_terragrunt_dir())),
      ]
    }
  }
}
