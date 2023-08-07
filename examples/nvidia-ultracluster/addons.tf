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

  enable_metrics_server        = true
  enable_kube_prometheus_stack = false
  kube_prometheus_stack = {
    values = [
      <<-EOT
        prometheus:
          prometheusSpec:
            serviceMonitorSelectorNilUsesHelmValues: false
      EOT
    ]
  }

  helm_releases = {
    prometheus-adapter = {
      chart            = "prometheus-adapter"
      chart_version    = "4.2.0"
      repository       = "https://prometheus-community.github.io/helm-charts"
      description      = "A Helm chart for k8s prometheus adapter"
      namespace        = "prometheus-adapter"
      create_namespace = true
    }
    gpu-operator = {
      description      = "A Helm chart for NVIDIA GPU operator"
      namespace        = "gpu-operator"
      create_namespace = true
      chart            = "gpu-operator"
      chart_version    = "v23.6.0"
      repository       = "https://nvidia.github.io/gpu-operator"
      values = [
        <<-EOT
          driver:
            enabled: false
          toolkit:
            version: v1.13.5-centos7
          operator:
            defaultRuntime: containerd
        EOT
      ]
    }
  }

  tags = local.tags
}
