################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.16"

  cluster_name    = local.name
  cluster_version = "1.27"

  cluster_endpoint_public_access = true

  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_group_defaults = {
    iam_role_additional_policies = {
      # Not required, but used in the example to access the nodes to inspect drivers and devices
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }

  eks_managed_node_groups = {
    # This nodegroup is for core addons such as CoreDNS
    default = {
      instance_types = ["m5.large"]

      min_size     = 1
      max_size     = 2
      desired_size = 2
    }

    g5-gpu = {
      create = true

      # Note: this is the standard AMI, non-GPU
      ami_type       = "AL2_x86_64"
      instance_types = ["g5.4xlarge"]

      min_size     = 1
      max_size     = 1
      desired_size = 1

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_type = "gp3"
            volume_size = 128
          }
        }
      }

      # Use the availability zone that supports the instance
      # aws ec2 describe-instance-type-offerings --location-type availability-zone  \
      # --filters Name=instance-type,Values=g5.2xlarge \
      # --region eu-central-1 --output table
      subnet_ids = [element(module.vpc.private_subnets, 1)]

      placement = {
        group_name = aws_placement_group.this.name
      }

      pre_bootstrap_user_data = templatefile("${path.module}/user_data.sh", {
        install_cuda_toolkit             = true
        install_nvidia_container_toolkit = false # Using GPU operator to install/manage
        install_nccl_tests               = false
      })

      taints = {
        # Ensure only GPU workloads are scheduled on this nodegroup
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }

    p4-gpu = {
      create = true

      # Note: this is the standard AMI, non-GPU
      ami_type       = "AL2_x86_64"
      instance_types = ["p4d.24xlarge"]

      min_size     = 1
      max_size     = 5
      desired_size = 1

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_type = "gp3"
            volume_size = 128
          }
        }
      }

      # Use the availability zone that supports the instance
      # aws ec2 describe-instance-type-offerings --location-type availability-zone  \
      # --filters Name=instance-type,Values=p4d.24xlarge,p5.48xlarge \
      # --region eu-central-1 --output table
      subnet_ids = [element(module.vpc.private_subnets, 1)]

      # p4d.24xlarge has 4 network cards
      network_interfaces = [
        for i in range(4) : {
          associate_public_ip_address = false
          delete_on_termination       = true
          device_index                = i
          network_card_index          = i
          interface_type              = "efa"
        }
      ]

      placement = {
        group_name = aws_placement_group.this.name
      }

      pre_bootstrap_user_data = templatefile("${path.module}/user_data.sh", {
        install_cuda_toolkit             = true
        install_nvidia_container_toolkit = false # Using GPU operator to install/manage
        install_nccl_tests               = false
      })

      taints = {
        # Ensure only GPU workloads are scheduled on this nodegroup
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }

    # This nodegroup is for GPU workloads
    p5-gpu = {
      create = false

      # Note: this is the standard AMI, non-GPU
      ami_type       = "AL2_x86_64"
      instance_types = ["p5.48xlarge"]

      min_size     = 1
      max_size     = 5
      desired_size = 1

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_type = "gp3"
            volume_size = 128
          }
        }
      }

      # Use the availability zone that supports the instance
      # aws ec2 describe-instance-type-offerings --location-type availability-zone  \
      # --filters Name=instance-type,Values=p4d.24xlarge,p5.48xlarge \
      # --region eu-central-1 --output table
      subnet_ids = [element(module.vpc.private_subnets, 1)]

      # p5.48xlarge has 32 network cards
      network_interfaces = [
        for i in range(32) : {
          associate_public_ip_address = false
          delete_on_termination       = true
          device_index                = i == 0 ? 0 : 1
          network_card_index          = i
          interface_type              = "efa"
        }
      ]

      placement = {
        group_name = aws_placement_group.this.name
      }

      pre_bootstrap_user_data = templatefile("${path.module}/user_data.sh", {
        install_cuda_toolkit             = true
        install_nvidia_container_toolkit = true
        install_nccl_tests               = true
      })

      taints = {
        # Ensure only GPU workloads are scheduled on this nodegroup
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  tags = local.tags
}

################################################################################
# Placement group
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start.html#efa-start-instances
################################################################################

resource "aws_placement_group" "this" {
  name     = local.name
  strategy = "cluster"
}

module "ebs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name_prefix = "${module.eks.cluster_name}-ebs-csi-driver-"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}
