variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}
variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}
variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.30"
}
variable "environment" {
  description = "Environment"
  type        = string
  default     = "dev"
}

variable "addons" {
  description = "Kubernetes addons"
  type        = any
  default = {
    enable_aws_load_balancer_controller = true
    enable_aws_ebs_csi_resources        = false # generate gp2 and gp3 storage classes for ebs-csi
    enable_metrics_server               = true
    enable_gatekeeper                   = false
    enable_karpenter                    = false
    enable_argocd                       = false
  }
}
# Addons Git
variable "gitops_addons_org" {
  description = "Git repository org/user contains for addons"
  type        = string
  default     = "https://github.com/markoskandylis/"
}
variable "gitops_addons_repo" {
  description = "Git repository contains for addons"
  type        = string
  default     = "gitops-bridge"
}
variable "gitops_addons_revision" {
  description = "Git repository revision/branch/ref for addons"
  type        = string
  default     = "gitops-v2"
}
variable "gitops_addons_basepath" {
  description = "Git repository base path for addons"
  type        = string
  default     = "argocd/iac/terraform/examples/eks/multi-cluster/hub-spoke-v2/addons/"
}
variable "gitops_addons_path" {
  description = "Git repository path for addons"
  type        = string
  default     = ""
}

variable "platform_stack_version" {
  description = "Platform stack version"
  type        = string
  default     = "v1.30-v1.0.1"
}