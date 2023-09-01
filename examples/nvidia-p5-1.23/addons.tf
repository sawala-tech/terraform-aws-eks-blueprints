################################################################################
# Addons
################################################################################

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.5"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # Wait for compute to be available
  create_delay_dependencies = [for group in module.eks.eks_managed_node_groups : group.node_group_arn if group.node_group_arn != null]

  helm_releases = {
    gpu-operator = {
      description      = "A Helm chart for NVIDIA GPU operator"
      namespace        = "gpu-operator"
      create_namespace = true
      chart            = "gpu-operator"
      chart_version    = "v23.6.0"
      repository       = "https://nvidia.github.io/gpu-operator"
      values = [
        <<-EOT
          dcgmExporter:
            enabled: false
          driver:
            enabled: false
          toolkit:
            version: v1.13.5-centos7
          validator:
            driver:
              env:
                # https://github.com/NVIDIA/gpu-operator/issues/569
                - name: DISABLE_DEV_CHAR_SYMLINK_CREATION
                  value: "true"
        EOT
      ]
    }
  }

  tags = local.tags
}
