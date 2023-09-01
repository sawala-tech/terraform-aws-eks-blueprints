locals {
  # AMI was built using https://github.com/clowdhaus/amazon-eks-gpu-ami
  # Command used: packer build -var-file=gpu.pkrvars.hcl -var "eks_version=1.23" .
  ami_id = "ami-0d1486b9a5f805151"
}

################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.16"

  cluster_name    = local.name
  cluster_version = "1.23"

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

    p5-gpu = {
      create = true

      ami_id                     = local.ami_id
      enable_bootstrap_user_data = true

      instance_types = ["p5.48xlarge"]
      capacity_type  = "SPOT"

      min_size     = 1
      max_size     = 2
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
      # --filters Name=instance-type,Values=p5.48xlarge \
      # --region <REGION> --output table
      subnet_ids = [element(module.vpc.private_subnets, 0)]

      # # p5.48xlarge has 32 network cards
      # network_interfaces = [
      #   for i in range(32) : {
      #     associate_public_ip_address = false
      #     delete_on_termination       = true
      #     device_index                = i == 0 ? 0 : 1
      #     network_card_index          = i
      #     interface_type              = "efa"
      #   }
      # ]

      # placement = {
      #   group_name = aws_placement_group.this.name
      # }

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
