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
  tags = {
    environment = local.environment
    region      = local.aws_region
    account     = local.aws_account_name
    opentofu    = "true"
  }
  instance_types = [
    "m6a.large",
    "m6a.xlarge",
    "m6i.large",
    "m6i.xlarge",
  ]
}

terraform {
  source = format("%s/modules/opentofu/aws/eks//21.10.1", get_repo_root())
}

include "parent" {
  path = find_in_parent_folders("root.hcl")
}

dependency "vpc" {
  config_path = format("%s/../../../vpc/kloia-test", get_terragrunt_dir())
}

dependency "aws_ebs_csi_driver_eks_pod_identity" {
  config_path = format("%s/../../eks-pod-identity/aws-ebs-csi-driver", get_terragrunt_dir())
}

prevent_destroy = false

inputs = {
  name               = local.name
  region             = local.aws_region
  tags               = local.tags
  kubernetes_version = "1.34"

  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true
  control_plane_scaling_config = {
    tier = "standard"
  }
  compute_config = {
    enabled = false
  }
  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    metrics-server = {}
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = dependency.aws_ebs_csi_driver_eks_pod_identity.outputs.eks_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }
  vpc_id                   = dependency.vpc.outputs.vpc.vpc_id
  subnet_ids               = dependency.vpc.outputs.vpc.private_subnets
  control_plane_subnet_ids = dependency.vpc.outputs.vpc.intra_subnets

  create_security_group          = true
  security_group_use_name_prefix = true
  create_node_security_group     = true

  enable_irsa          = true
  create_iam_role      = true
  create_node_iam_role = true

  self_managed_node_groups = {
    kloia-test-ng = {
      ami_type = "AL2023_x86_64_STANDARD"

      min_size = 2
      max_size = 5
      # This value is ignored after the initial creation
      # https://github.com/bryantbiggs/eks-desired-size-hack
      desired_size = 2

      create_launch_template                 = true
      launch_template_use_name_prefix        = true
      launch_template_name                   = format("lt-%s", local.name)
      update_launch_template_default_version = true

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 3
      }

      autoscaling_group_tags = {
        "k8s.io/cluster-autoscaler/enabled"                = "true"
        format("k8s.io/cluster-autoscaler/%s", local.name) = "owned"
      }

      use_mixed_instances_policy = true
      mixed_instances_policy = {
        instances_distribution = {
          on_demand_percentage_above_base_capacity = 0
        }
        spot_allocation_strategy = "lowest-price"
        launch_template = {
          override = [
            for it in local.instance_types : tomap({
              instance_type = it
            })
          ]
        }

      }

      block_device_mappings = {
        "/dev/sda1" = {
          device_name = "/dev/sda1"
          no_device   = "0"
          ebs = {
            delete_on_termination = true
            encrypted             = false
            volume_size           = "20"
            volume_type           = "gp3"
          }
        }
      }
    }
  }
}
