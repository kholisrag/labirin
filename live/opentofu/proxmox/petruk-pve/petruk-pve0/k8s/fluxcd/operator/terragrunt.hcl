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
    "../../../vms/talos-k8s/master",
    "../../../vms/talos-k8s/worker",
  ]
}

inputs = {
  k8s = local.k8s

  kubectl_manifest_files = {}

  helm_releases = {
    "flux-operator" = {
      name             = "flux-operator"
      namespace        = "flux-system"
      repository       = "oci://ghcr.io/controlplaneio-fluxcd/charts"
      chart            = "flux-operator"
      create_namespace = true
      timeout          = "180"
      version          = "0.38.1"
    }
  }
}
