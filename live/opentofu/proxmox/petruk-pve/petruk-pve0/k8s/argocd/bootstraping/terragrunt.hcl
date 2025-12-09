locals {
  provider_vars   = read_terragrunt_config(find_in_parent_folders("provider.hcl"))
  datacenter_vars = read_terragrunt_config(find_in_parent_folders("datacenter.hcl"))
  node_vars       = read_terragrunt_config(find_in_parent_folders("node.hcl"))

  k8s = {
    config_path    = "~/.kube/config"
    config_context = "admin@main-talos-k8s-cluster"
  }

  argocd_image_repository = "ghcr.io/kholisrag/argocd-ksops-helm-secrets"
  argocd_image_tag        = "v3.2.1-669b755"
}

terraform {
  source = format("%s/modules/opentofu/kubernetes/manifests/talos//0.1.0", get_repo_root())
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

dependencies {
  paths = [
    "../../../vms/talos-k8s/master",
    "../../../vms/talos-k8s/worker",
  ]
}

inputs = {
  k8s = local.k8s

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
      set = [
        {
          name  = "global.image.repository"
          value = local.argocd_image_repository
        },
        {
          name  = "global.image.tag"
          value = local.argocd_image_tag
        }
      ]
    }
  }
}
