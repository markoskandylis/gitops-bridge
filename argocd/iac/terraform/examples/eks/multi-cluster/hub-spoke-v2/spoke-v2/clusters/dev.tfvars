vpc_cidr = "10.1.0.0/16"
region = "us-west-2"
kubernetes_version = "1.30"
addons = {
  enable_aws_load_balancer_controller = true
  enable_metrics_server               = true
  enable_argocd = true
  enable_karpenter = true
}