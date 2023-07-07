data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# This resource is used to provide a means of mapping an implicit dependency
# between the cluster and the addons.
resource "time_sleep" "this" {
  create_duration = var.create_delay_duration

  triggers = {
    cluster_endpoint  = var.cluster_endpoint
    cluster_name      = var.cluster_name
    custom            = join(",", var.create_delay_dependencies)
    oidc_provider_arn = var.oidc_provider_arn
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  dns_suffix = data.aws_partition.current.dns_suffix
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  # Threads the sleep resource into the module to make the dependency
  cluster_endpoint  = time_sleep.this.triggers["cluster_endpoint"]
  cluster_name      = time_sleep.this.triggers["cluster_name"]
  oidc_provider_arn = time_sleep.this.triggers["oidc_provider_arn"]

  iam_role_policy_prefix = "arn:${local.partition}:iam::aws:policy"

  # Used by Karpenter & AWS Node Termination Handler
  ec2_events = {
    health_event = {
      name        = "HealthEvent"
      description = "AWS health event"
      event_pattern = {
        source      = ["aws.health"]
        detail-type = ["AWS Health Event"]
      }
    }
    spot_interupt = {
      name        = "SpotInterrupt"
      description = "EC2 spot instance interruption warning"
      event_pattern = {
        source      = ["aws.ec2"]
        detail-type = ["EC2 Spot Instance Interruption Warning"]
      }
    }
    instance_rebalance = {
      name        = "InstanceRebalance"
      description = "EC2 instance rebalance recommendation"
      event_pattern = {
        source      = ["aws.ec2"]
        detail-type = ["EC2 Instance Rebalance Recommendation"]
      }
    }
    instance_state_change = {
      name        = "InstanceStateChange"
      description = "EC2 instance state-change notification"
      event_pattern = {
        source      = ["aws.ec2"]
        detail-type = ["EC2 Instance State-change Notification"]
      }
    }
  }
}


################################################################################
# EKS Addons
################################################################################

data "aws_eks_addon_version" "this" {
  for_each = var.eks_addons

  addon_name         = try(each.value.name, each.key)
  kubernetes_version = var.cluster_version
  most_recent        = try(each.value.most_recent, true)
}

resource "aws_eks_addon" "this" {
  for_each = var.eks_addons

  cluster_name = local.cluster_name
  addon_name   = try(each.value.name, each.key)

  addon_version               = try(each.value.addon_version, data.aws_eks_addon_version.this[each.key].version)
  configuration_values        = try(each.value.configuration_values, null)
  preserve                    = try(each.value.preserve, true)
  resolve_conflicts_on_create = try(each.value.resolve_conflicts, "OVERWRITE")
  resolve_conflicts_on_update = try(each.value.resolve_conflicts, "OVERWRITE")
  service_account_role_arn    = try(each.value.service_account_role_arn, null)

  timeouts {
    create = try(each.value.timeouts.create, var.eks_addons_timeouts.create, null)
    update = try(each.value.timeouts.update, var.eks_addons_timeouts.update, null)
    delete = try(each.value.timeouts.delete, var.eks_addons_timeouts.delete, null)
  }

  tags = var.tags

  depends_on = [
    module.cert_manager.name,
    module.cert_manager.namespace,
  ]
}


################################################################################
# AWS Cloudwatch Metrics
################################################################################

locals {
  aws_cloudwatch_metrics_service_account = try(var.aws_cloudwatch_metrics.service_account_name, "aws-cloudwatch-metrics")
  aws_cloudwatch_metrics_namespace = try(var.aws_cloudwatch_metrics.namespace, "amazon-cloudwatch")
}

module "aws_cloudwatch_metrics" {
  source  = "aws-ia/eks-blueprints-addon/aws"
  version = "1.0.0"

  create = var.enable_aws_cloudwatch_metrics

  # Disable helm release
  create_release = false

  namespace = local.aws_cloudwatch_metrics_namespace

  # IAM role for service account (IRSA)
  create_role                   = try(var.aws_cloudwatch_metrics.create_role, true)
  role_name                     = try(var.aws_cloudwatch_metrics.role_name, "aws-cloudwatch-metrics")
  role_name_use_prefix          = try(var.aws_cloudwatch_metrics.role_name_use_prefix, true)
  role_path                     = try(var.aws_cloudwatch_metrics.role_path, "/")
  role_permissions_boundary_arn = try(var.aws_cloudwatch_metrics.role_permissions_boundary_arn, null)
  role_description              = try(var.aws_cloudwatch_metrics.role_description, "IRSA for aws-cloudwatch-metrics project")
  role_policies = lookup(var.aws_cloudwatch_metrics, "role_policies",
    { CloudWatchAgentServerPolicy = "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy" }
  )
  create_policy = try(var.aws_cloudwatch_metrics.create_policy, false)

  oidc_providers = {
    this = {
      provider_arn = local.oidc_provider_arn
      # namespace is inherited from chart
      service_account = local.aws_cloudwatch_metrics_service_account
    }
  }

  tags = var.tags
}


################################################################################
# Cert Manager
################################################################################

locals {
  cert_manager_service_account = try(var.cert_manager.service_account_name, "cert-manager")
  create_cert_manager_irsa     = var.enable_cert_manager && length(var.cert_manager_route53_hosted_zone_arns) > 0
  cert_manager_namespace       = try(var.cert_manager.namespace, "cert-manager")
}

data "aws_iam_policy_document" "cert_manager" {
  count = local.create_cert_manager_irsa ? 1 : 0

  statement {
    actions   = ["route53:GetChange", ]
    resources = ["arn:${local.partition}:route53:::change/*"]
  }

  statement {
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
    ]
    resources = var.cert_manager_route53_hosted_zone_arns
  }

  statement {
    actions   = ["route53:ListHostedZonesByName"]
    resources = ["*"]
  }
}

module "cert_manager" {
  source  = "aws-ia/eks-blueprints-addon/aws"
  version = "1.0.0"

  create = var.enable_cert_manager

  # Disable helm release
  create_release = false

  namespace = local.cert_manager_namespace

  # IAM role for service account (IRSA)
  create_role                   = local.create_cert_manager_irsa && try(var.cert_manager.create_role, true)
  role_name                     = try(var.cert_manager.role_name, "cert-manager")
  role_name_use_prefix          = try(var.cert_manager.role_name_use_prefix, true)
  role_path                     = try(var.cert_manager.role_path, "/")
  role_permissions_boundary_arn = lookup(var.cert_manager, "role_permissions_boundary_arn", null)
  role_description              = try(var.cert_manager.role_description, "IRSA for cert-manger project")
  role_policies                 = lookup(var.cert_manager, "role_policies", {})

  source_policy_documents = compact(concat(
    data.aws_iam_policy_document.cert_manager[*].json,
    lookup(var.cert_manager, "source_policy_documents", [])
  ))
  override_policy_documents = lookup(var.cert_manager, "override_policy_documents", [])
  policy_statements         = lookup(var.cert_manager, "policy_statements", [])
  policy_name               = try(var.cert_manager.policy_name, null)
  policy_name_use_prefix    = try(var.cert_manager.policy_name_use_prefix, true)
  policy_path               = try(var.cert_manager.policy_path, null)
  policy_description        = try(var.cert_manager.policy_description, "IAM Policy for cert-manager")

  oidc_providers = {
    this = {
      provider_arn = local.oidc_provider_arn
      # namespace is inherited from chart
      service_account = local.cert_manager_service_account
    }
  }

  tags = var.tags
}


################################################################################
# Cluster Autoscaler
################################################################################

locals {
  cluster_autoscaler_service_account = try(var.cluster_autoscaler.service_account_name, "cluster-autoscaler-sa")
  cluster_autoscaler_namespace = try(var.cluster_autoscaler.namespace, "kube-system")
  cluster_autoscaler_image_tag_selected = try(local.cluster_autoscaler_image_tag[var.cluster_version], "v${var.cluster_version}.0")
  # Lookup map to pull latest cluster-autoscaler patch version given the cluster version
  cluster_autoscaler_image_tag = {
    "1.20" = "v1.20.3"
    "1.21" = "v1.21.3"
    "1.22" = "v1.22.3"
    "1.23" = "v1.23.1"
    "1.24" = "v1.24.1"
    "1.25" = "v1.25.1"
    "1.26" = "v1.26.2"
    "1.27" = "v1.27.2"
  }
}

data "aws_iam_policy_document" "cluster_autoscaler" {
  count = var.enable_cluster_autoscaler ? 1 : 0

  statement {
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeInstanceTypes",
      "eks:DescribeNodegroup",
      "ec2:DescribeImages",
      "ec2:GetInstanceTypesFromInstanceRequirements"
    ]

    resources = ["*"]
  }

  statement {
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }
}

module "cluster_autoscaler" {
  source  = "aws-ia/eks-blueprints-addon/aws"
  version = "1.0.0"

  create = var.enable_cluster_autoscaler

  # Disable helm release
  create_release = false

  namespace = local.cluster_autoscaler_namespace

  # IAM role for service account (IRSA)
  create_role                   = try(var.cluster_autoscaler.create_role, true)
  role_name                     = try(var.cluster_autoscaler.role_name, "cluster-autoscaler")
  role_name_use_prefix          = try(var.cluster_autoscaler.role_name_use_prefix, true)
  role_path                     = try(var.cluster_autoscaler.role_path, "/")
  role_permissions_boundary_arn = lookup(var.cluster_autoscaler, "role_permissions_boundary_arn", null)
  role_description              = try(var.cluster_autoscaler.role_description, "IRSA for cluster-autoscaler operator")
  role_policies                 = lookup(var.cluster_autoscaler, "role_policies", {})

  source_policy_documents = compact(concat(
    data.aws_iam_policy_document.cluster_autoscaler[*].json,
    lookup(var.cluster_autoscaler, "source_policy_documents", [])
  ))
  override_policy_documents = lookup(var.cluster_autoscaler, "override_policy_documents", [])
  policy_statements         = lookup(var.cluster_autoscaler, "policy_statements", [])
  policy_name               = try(var.cluster_autoscaler.policy_name, null)
  policy_name_use_prefix    = try(var.cluster_autoscaler.policy_name_use_prefix, true)
  policy_path               = try(var.cluster_autoscaler.policy_path, null)
  policy_description        = try(var.cluster_autoscaler.policy_description, "IAM Policy for cluster-autoscaler operator")

  oidc_providers = {
    this = {
      provider_arn = local.oidc_provider_arn
      # namespace is inherited from chart
      service_account = local.cluster_autoscaler_service_account
    }
  }

  tags = var.tags
}


################################################################################
# AWS EFS CSI DRIVER
################################################################################

locals {
  aws_efs_csi_driver_controller_service_account = try(var.aws_efs_csi_driver.controller_service_account_name, "efs-csi-controller-sa")
  aws_efs_csi_driver_node_service_account       = try(var.aws_efs_csi_driver.node_service_account_name, "efs-csi-node-sa")
  efs_arns = lookup(var.aws_efs_csi_driver, "efs_arns",
    ["arn:${local.partition}:elasticfilesystem:${local.region}:${local.account_id}:file-system/*"],
  )
  efs_access_point_arns = lookup(var.aws_efs_csi_driver, "efs_access_point_arns",
    ["arn:${local.partition}:elasticfilesystem:${local.region}:${local.account_id}:access-point/*"]
  )
  aws_efs_csi_driver_namespace = try(var.aws_efs_csi_driver.namespace, "kube-system")
}

data "aws_iam_policy_document" "aws_efs_csi_driver" {
  count = var.enable_aws_efs_csi_driver ? 1 : 0

  statement {
    sid       = "AllowDescribeAvailabilityZones"
    actions   = ["ec2:DescribeAvailabilityZones"]
    resources = ["*"]
  }

  statement {
    sid = "AllowDescribeFileSystems"
    actions = [
      "elasticfilesystem:DescribeAccessPoints",
      "elasticfilesystem:DescribeFileSystems",
      "elasticfilesystem:DescribeMountTargets"
    ]
    resources = flatten([
      local.efs_arns,
      local.efs_access_point_arns,
    ])
  }

  statement {
    actions = [
      "elasticfilesystem:CreateAccessPoint",
      "elasticfilesystem:TagResource",
    ]
    resources = local.efs_arns

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/efs.csi.aws.com/cluster"
      values   = ["true"]
    }
  }

  statement {
    sid       = "AllowDeleteAccessPoint"
    actions   = ["elasticfilesystem:DeleteAccessPoint"]
    resources = local.efs_access_point_arns

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/efs.csi.aws.com/cluster"
      values   = ["true"]
    }
  }

  statement {
    sid = "ClientReadWrite"
    actions = [
      "elasticfilesystem:ClientRootAccess",
      "elasticfilesystem:ClientWrite",
      "elasticfilesystem:ClientMount",
    ]
    resources = local.efs_arns

    condition {
      test     = "Bool"
      variable = "elasticfilesystem:AccessedViaMountTarget"
      values   = ["true"]
    }
  }
}

module "aws_efs_csi_driver" {
  source  = "aws-ia/eks-blueprints-addon/aws"
  version = "1.0.0"

  create = var.enable_aws_efs_csi_driver

  # Disable helm release
  create_release = false

  namespace = local.aws_efs_csi_driver_namespace

  # IAM role for service account (IRSA)
  create_role                   = try(var.aws_efs_csi_driver.create_role, true)
  role_name                     = try(var.aws_efs_csi_driver.role_name, "aws-efs-csi-driver")
  role_name_use_prefix          = try(var.aws_efs_csi_driver.role_name_use_prefix, true)
  role_path                     = try(var.aws_efs_csi_driver.role_path, "/")
  role_permissions_boundary_arn = lookup(var.aws_efs_csi_driver, "role_permissions_boundary_arn", null)
  role_description              = try(var.aws_efs_csi_driver.role_description, "IRSA for aws-efs-csi-driver project")
  role_policies                 = lookup(var.aws_efs_csi_driver, "role_policies", {})

  source_policy_documents = compact(concat(
    data.aws_iam_policy_document.aws_efs_csi_driver[*].json,
    lookup(var.aws_efs_csi_driver, "source_policy_documents", [])
  ))
  override_policy_documents = lookup(var.aws_efs_csi_driver, "override_policy_documents", [])
  policy_statements         = lookup(var.aws_efs_csi_driver, "policy_statements", [])
  policy_name               = try(var.aws_efs_csi_driver.policy_name, null)
  policy_name_use_prefix    = try(var.aws_efs_csi_driver.policy_name_use_prefix, true)
  policy_path               = try(var.aws_efs_csi_driver.policy_path, null)
  policy_description        = try(var.aws_efs_csi_driver.policy_description, "IAM Policy for AWS EFS CSI Driver")

  oidc_providers = {
    controller = {
      provider_arn = local.oidc_provider_arn
      # namespace is inherited from chart
      service_account = local.aws_efs_csi_driver_controller_service_account
    }
    node = {
      provider_arn = local.oidc_provider_arn
      # namespace is inherited from chart
      service_account = local.aws_efs_csi_driver_node_service_account
    }
  }

  tags = var.tags
}



################################################################################
# AWS FSX CSI DRIVER
################################################################################

locals {
  aws_fsx_csi_driver_controller_service_account = try(var.aws_fsx_csi_driver.controller_service_account_name, "aws-fsx-csi-controller-sa")
  aws_fsx_csi_driver_node_service_account       = try(var.aws_fsx_csi_driver.node_service_account_name, "aws-fsx-csi-node-sa")
  aws_fsx_csi_driver_namespace = try(var.aws_fsx_csi_driver.namespace, "kube-system")
}

data "aws_iam_policy_document" "aws_fsx_csi_driver" {
  statement {
    sid       = "AllowCreateServiceLinkedRoles"
    resources = ["arn:${local.partition}:iam::*:role/aws-service-role/s3.data-source.lustre.fsx.${local.dns_suffix}/*"]

    actions = [
      "iam:CreateServiceLinkedRole",
      "iam:AttachRolePolicy",
      "iam:PutRolePolicy",
    ]
  }

  statement {
    sid       = "AllowCreateServiceLinkedRole"
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/*"]
    actions   = ["iam:CreateServiceLinkedRole"]

    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values   = ["fsx.${local.dns_suffix}"]
    }
  }

  statement {
    sid       = "AllowListBuckets"
    resources = ["arn:${local.partition}:s3:::*"]
    actions = [
      "s3:ListBucket"
    ]
  }

  statement {
    resources = ["arn:${local.partition}:fsx:${local.region}:${local.account_id}:file-system/*"]
    actions = [
      "fsx:CreateFileSystem",
      "fsx:DeleteFileSystem",
      "fsx:UpdateFileSystem",
    ]
  }

  statement {
    resources = ["arn:${local.partition}:fsx:${local.region}:${local.account_id}:*"]
    actions = [
      "fsx:DescribeFileSystems",
      "fsx:TagResource"
    ]
  }
}

module "aws_fsx_csi_driver" {
  source  = "aws-ia/eks-blueprints-addon/aws"
  version = "1.0.0"

  create = var.enable_aws_fsx_csi_driver

  # Disable helm release
  create_release = false

  namespace = local.aws_fsx_csi_driver_namespace

  # IAM role for service account (IRSA)
  create_role                   = try(var.aws_fsx_csi_driver.create_role, true)
  role_name                     = try(var.aws_fsx_csi_driver.role_name, "aws-fsx-csi-driver")
  role_name_use_prefix          = try(var.aws_fsx_csi_driver.role_name_use_prefix, true)
  role_path                     = try(var.aws_fsx_csi_driver.role_path, "/")
  role_permissions_boundary_arn = lookup(var.aws_fsx_csi_driver, "role_permissions_boundary_arn", null)
  role_description              = try(var.aws_fsx_csi_driver.role_description, "IRSA for aws-fsx-csi-driver")
  role_policies                 = lookup(var.aws_fsx_csi_driver, "role_policies", {})

  source_policy_documents = compact(concat(
    data.aws_iam_policy_document.aws_fsx_csi_driver[*].json,
    lookup(var.aws_fsx_csi_driver, "source_policy_documents", [])
  ))
  override_policy_documents = lookup(var.aws_fsx_csi_driver, "override_policy_documents", [])
  policy_statements         = lookup(var.aws_fsx_csi_driver, "policy_statements", [])
  policy_name               = try(var.aws_fsx_csi_driver.policy_name, "aws-fsx-csi-driver")
  policy_name_use_prefix    = try(var.aws_fsx_csi_driver.policy_name_use_prefix, true)
  policy_path               = try(var.aws_fsx_csi_driver.policy_path, null)
  policy_description        = try(var.aws_fsx_csi_driver.policy_description, "IAM Policy for AWS FSX CSI Driver")

  oidc_providers = {
    controller = {
      provider_arn = local.oidc_provider_arn
      # namespace is inherited from chart
      service_account = local.aws_fsx_csi_driver_controller_service_account
    }
    node = {
      provider_arn = local.oidc_provider_arn
      # namespace is inherited from chart
      service_account = local.aws_fsx_csi_driver_node_service_account
    }
  }
}


################################################################################
# AWS Private CA Issuer
################################################################################

locals {
  aws_privateca_issuer_service_account = try(var.aws_privateca_issuer.service_account_name, "aws-privateca-issuer-sa")
  aws_privateca_issuer_namespace = try(var.aws_privateca_issuer.namespace, local.cert_manager_namespace)
}

data "aws_iam_policy_document" "aws_privateca_issuer" {
  count = var.enable_aws_privateca_issuer ? 1 : 0

  statement {
    actions = [
      "acm-pca:DescribeCertificateAuthority",
      "acm-pca:GetCertificate",
      "acm-pca:IssueCertificate",
    ]
    resources = [
      try(var.aws_privateca_issuer.acmca_arn,
      "arn:${local.partition}:acm-pca:${local.region}:${local.account_id}:certificate-authority/*")
    ]
  }
}

module "aws_privateca_issuer" {
  source  = "aws-ia/eks-blueprints-addon/aws"
  version = "1.0.0"

  create = var.enable_aws_privateca_issuer

  # Disable helm release
  create_release = false

  namespace = local.aws_privateca_issuer_namespace

  # IAM role for service account (IRSA)
  create_role                   = try(var.aws_privateca_issuer.create_role, true)
  role_name                     = try(var.aws_privateca_issuer.role_name, "aws-privateca-issuer")
  role_name_use_prefix          = try(var.aws_privateca_issuer.role_name_use_prefix, true)
  role_path                     = try(var.aws_privateca_issuer.role_path, "/")
  role_permissions_boundary_arn = lookup(var.aws_privateca_issuer, "role_permissions_boundary_arn", null)
  role_description              = try(var.aws_privateca_issuer.role_description, "IRSA for AWS Private CA Issuer")
  role_policies                 = lookup(var.aws_privateca_issuer, "role_policies", {})

  source_policy_documents = compact(concat(
    data.aws_iam_policy_document.aws_privateca_issuer[*].json,
    lookup(var.aws_privateca_issuer, "source_policy_documents", [])
  ))
  override_policy_documents = lookup(var.aws_privateca_issuer, "override_policy_documents", [])
  policy_statements         = lookup(var.aws_privateca_issuer, "policy_statements", [])
  policy_name               = try(var.aws_privateca_issuer.policy_name, "aws-privateca-issuer")
  policy_name_use_prefix    = try(var.aws_privateca_issuer.policy_name_use_prefix, true)
  policy_path               = try(var.aws_privateca_issuer.policy_path, null)
  policy_description        = try(var.aws_privateca_issuer.policy_description, "IAM Policy for AWS Private CA Issuer")

  oidc_providers = {
    controller = {
      provider_arn = local.oidc_provider_arn
      # namespace is inherited from chart
      service_account = local.aws_privateca_issuer_service_account
    }
  }

  tags = var.tags
}


################################################################################
# External DNS
################################################################################

locals {
  external_dns_service_account = try(var.external_dns.service_account_name, "external-dns-sa")
  external_dns_namespace = try(var.external_dns.namespace, "external-dns")
}

data "aws_iam_policy_document" "external_dns" {
  count = var.enable_external_dns && length(var.external_dns_route53_zone_arns) > 0 ? 1 : 0

  statement {
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = var.external_dns_route53_zone_arns
  }

  statement {
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
    ]
    resources = ["*"]
  }
}

module "external_dns" {
  source  = "aws-ia/eks-blueprints-addon/aws"
  version = "1.0.0"

  create = var.enable_external_dns

  # Disable helm release
  create_release = false

  namespace = local.external_dns_namespace

  # IAM role for service account (IRSA)
  create_role                   = try(var.external_dns.create_role, true) && length(var.external_dns_route53_zone_arns) > 0
  role_name                     = try(var.external_dns.role_name, "external-dns")
  role_name_use_prefix          = try(var.external_dns.role_name_use_prefix, true)
  role_path                     = try(var.external_dns.role_path, "/")
  role_permissions_boundary_arn = lookup(var.external_dns, "role_permissions_boundary_arn", null)
  role_description              = try(var.external_dns.role_description, "IRSA for external-dns operator")
  role_policies                 = lookup(var.external_dns, "role_policies", {})

  source_policy_documents = compact(concat(
    data.aws_iam_policy_document.external_dns[*].json,
    lookup(var.external_dns, "source_policy_documents", [])
  ))
  override_policy_documents = lookup(var.external_dns, "override_policy_documents", [])
  policy_statements         = lookup(var.external_dns, "policy_statements", [])
  policy_name               = try(var.external_dns.policy_name, null)
  policy_name_use_prefix    = try(var.external_dns.policy_name_use_prefix, true)
  policy_path               = try(var.external_dns.policy_path, null)
  policy_description        = try(var.external_dns.policy_description, "IAM Policy for external-dns operator")

  oidc_providers = {
    this = {
      provider_arn = local.oidc_provider_arn
      # namespace is inherited from chart
      service_account = local.external_dns_service_account
    }
  }

  tags = var.tags
}


################################################################################
# External Secrets
################################################################################

locals {
  external_secrets_service_account  = try(var.external_secrets.service_account_name, "external-secrets-sa")
  external_secrets_namespace        = try(var.external_secrets.namespace, "external-secrets")
}

data "aws_iam_policy_document" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  dynamic "statement" {
    for_each = length(var.external_secrets_ssm_parameter_arns) > 0 ? [1] : []

    content {
      actions   = ["ssm:DescribeParameters"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.external_secrets_ssm_parameter_arns) > 0 ? [1] : []

    content {
      actions = [
        "ssm:GetParameter",
        "ssm:GetParameters",
      ]
      resources = var.external_secrets_ssm_parameter_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.external_secrets_secrets_manager_arns) > 0 ? [1] : []

    content {
      actions   = ["secretsmanager:ListSecrets"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.external_secrets_secrets_manager_arns) > 0 ? [1] : []

    content {
      actions = [
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds",
      ]
      resources = var.external_secrets_secrets_manager_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.external_secrets_kms_key_arns) > 0 ? [1] : []

    content {
      actions   = ["kms:Decrypt"]
      resources = var.external_secrets_kms_key_arns
    }
  }
}

module "external_secrets" {
  source  = "aws-ia/eks-blueprints-addon/aws"
  version = "1.0.0"

  create = var.enable_external_secrets

  # Disable helm release
  create_release = false

  namespace = local.external_secrets_namespace

  # IAM role for service account (IRSA)
  create_role                   = try(var.external_secrets.create_role, true)
  role_name                     = try(var.external_secrets.role_name, "external-secrets")
  role_name_use_prefix          = try(var.external_secrets.role_name_use_prefix, true)
  role_path                     = try(var.external_secrets.role_path, "/")
  role_permissions_boundary_arn = lookup(var.external_secrets, "role_permissions_boundary_arn", null)
  role_description              = try(var.external_secrets.role_description, "IRSA for external-secrets operator")
  role_policies                 = lookup(var.external_secrets, "role_policies", {})

  source_policy_documents = compact(concat(
    data.aws_iam_policy_document.external_secrets[*].json,
    lookup(var.external_secrets, "source_policy_documents", [])
  ))
  override_policy_documents = lookup(var.external_secrets, "override_policy_documents", [])
  policy_statements         = lookup(var.external_secrets, "policy_statements", [])
  policy_name               = try(var.external_secrets.policy_name, null)
  policy_name_use_prefix    = try(var.external_secrets.policy_name_use_prefix, true)
  policy_path               = try(var.external_secrets.policy_path, null)
  policy_description        = try(var.external_secrets.policy_description, "IAM Policy for external-secrets operator")

  oidc_providers = {
    this = {
      provider_arn = local.oidc_provider_arn
      # namespace is inherited from chart
      service_account = local.external_secrets_service_account
    }
  }

  tags = var.tags
}


################################################################################
# AWS Load Balancer Controller
################################################################################

locals {
  aws_load_balancer_controller_service_account = try(var.aws_load_balancer_controller.service_account_name, "aws-load-balancer-controller-sa")
  aws_load_balancer_controller_namespace   = try(var.aws_load_balancer_controller.namespace, "kube-system")
}

data "aws_iam_policy_document" "aws_load_balancer_controller" {
  statement {
    sid       = "AllowCreateServiceLinkedRole"
    effect    = "Allow"
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing"]
    actions   = ["iam:CreateServiceLinkedRole"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.${local.dns_suffix}"]
    }
  }

  statement {
    sid       = "AllowDescribeElbTags"
    effect    = "Allow"
    resources = ["*"] #tfsec:ignore:aws-iam-no-policy-wildcards

    actions = ["elasticloadbalancing:DescribeTags"]
  }

  statement {
    sid       = "AllowGetResources"
    effect    = "Allow"
    resources = ["*"]

    actions = [
      "elasticloadbalancing:DescribeListenerCertificates",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeSSLPolicies",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeCoipPools",
      "ec2:DescribeInstances",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeVpcs",
      "ec2:GetCoipPoolUsage",
    ]
  }

  statement {
    sid    = "AllowManageElbs"
    effect = "Allow"

    resources = [
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:loadbalancer/app/*/*",
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:loadbalancer/net/*/*",
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:targetgroup/*/*",
    ]

    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:RemoveTags",
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
    ]
  }

  statement {
    sid    = "AllowManageTargetGroup"
    effect = "Allow"
    resources = [
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:targetgroup/*/*",
    ]

    actions = [
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
    ]
  }

  statement {
    sid    = "AllowManageListeners"
    effect = "Allow"
    resources = [
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:listener/app/*/*/*",
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:listener/net/*/*/*",
    ]

    actions = [
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:AddListenerCertificates",
      "elasticloadbalancing:RemoveListenerCertificates"
    ]
  }

  statement {
    sid    = "AllowManageRules"
    effect = "Allow"
    resources = [
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:listener-rule/app/*/*/*/*",
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:listener-rule/net/*/*/*/*",
    ]

    actions = [
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:ModifyRule"
    ]
  }

  statement {
    sid    = "AllowManageResourceTags"
    effect = "Allow"

    resources = [
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:loadbalancer/app/*/*",
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:loadbalancer/net/*/*",
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:listener/app/*/*/*",
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:listener/net/*/*/*",
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:listener-rule/app/*/*/*/*",
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:listener-rule/net/*/*/*/*",
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:targetgroup/*/*",
    ]

    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
  }

  statement {
    sid       = "AllowManageTargets"
    effect    = "Allow"
    resources = ["arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:targetgroup/*/*"]

    actions = [
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:RegisterTargets"
    ]
  }

  statement {
    sid    = "AllowGetCertificates"
    effect = "Allow"
    resources = [
      "*",
    ]

    actions = [
      "acm:DescribeCertificate",
      "acm:ListCertificates"
    ]
  }

  statement {
    sid       = "AllowDescribeCognitoIdp"
    effect    = "Allow"
    resources = ["arn:${local.partition}:cognito-idp:${local.region}:${local.account_id}:userpool/*"]

    actions = ["cognito-idp:DescribeUserPoolClient"]
  }

  statement {
    sid    = "AllowGetServerCertificates"
    effect = "Allow"
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:*",
      "arn:${local.partition}:iam::${local.account_id}:server-certificate/*"
    ]

    actions = [
      "iam:GetServerCertificate",
      "iam:ListServerCertificates",
    ]
  }

  statement {
    sid    = "AllowShield"
    effect = "Allow"
    resources = [
      "arn:${local.partition}:shield::${local.account_id}:*",
      "arn:${local.partition}:shield::${local.account_id}:protection/*"
    ]

    actions = [
      "shield:CreateProtection",
      "shield:DeleteProtection",
      "shield:DescribeProtection",
      "shield:GetSubscriptionState",
    ]
  }

  statement {
    sid    = "AllowManageWebAcl"
    effect = "Allow"
    resources = [
      "arn:${local.partition}:elasticloadbalancing:${local.region}:${local.account_id}:loadbalancer/app/*/*",
      "arn:${local.partition}:apigateway:${local.region}::/restapis/*/stages/*",
      "arn:${local.partition}:appsync:${local.region}:${local.account_id}:apis/*",
      "arn:${local.partition}:cognito-idp:${local.region}:${local.account_id}:userpool/*",
      "arn:${local.partition}:wafv2:${local.region}:${local.account_id}:*",
      "arn:${local.partition}:wafv2:${local.region}:${local.account_id}:*/webacl/*/*",
      "arn:${local.partition}:waf-regional:${local.region}:${local.account_id}:*",
      "arn:${local.partition}:waf-regional:${local.region}:${local.account_id}:webacl/*"
    ]

    actions = [
      "elasticloadbalancing:SetWebAcl",
      "waf-regional:AssociateWebACL",
      "waf-regional:DisassociateWebACL",
      "waf-regional:GetWebACL",
      "waf-regional:GetWebACLForResource",
      "wafv2:AssociateWebACL",
      "wafv2:DisassociateWebACL",
      "wafv2:GetWebACL",
      "wafv2:GetWebACLForResource",
    ]
  }

  statement {
    sid       = "AllowManageSecurityGroups"
    effect    = "Allow"
    resources = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:security-group/*"]

    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
  }

  statement {
    sid    = "AllowCreateSecurityGroups"
    effect = "Allow"
    resources = [
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:security-group/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:vpc/*",
    ]
    actions = ["ec2:CreateSecurityGroup"]
  }
}

module "aws_load_balancer_controller" {
  source  = "aws-ia/eks-blueprints-addon/aws"
  version = "1.0.0"

  create = var.enable_aws_load_balancer_controller

  # Disable helm release
  create_release = false

  namespace = local.aws_load_balancer_controller_namespace

  # IAM role for service account (IRSA)
  create_role                   = try(var.aws_load_balancer_controller.create_role, true)
  role_name                     = try(var.aws_load_balancer_controller.role_name, "alb-controller")
  role_name_use_prefix          = try(var.aws_load_balancer_controller.role_name_use_prefix, true)
  role_path                     = try(var.aws_load_balancer_controller.role_path, "/")
  role_permissions_boundary_arn = lookup(var.aws_load_balancer_controller, "role_permissions_boundary_arn", null)
  role_description              = try(var.aws_load_balancer_controller.role_description, "IRSA for aws-load-balancer-controller project")
  role_policies                 = lookup(var.aws_load_balancer_controller, "role_policies", {})

  source_policy_documents = compact(concat(
    data.aws_iam_policy_document.aws_load_balancer_controller[*].json,
    lookup(var.aws_load_balancer_controller, "source_policy_documents", [])
  ))
  override_policy_documents = lookup(var.aws_load_balancer_controller, "override_policy_documents", [])
  policy_statements         = lookup(var.aws_load_balancer_controller, "policy_statements", [])
  policy_name               = try(var.aws_load_balancer_controller.policy_name, null)
  policy_name_use_prefix    = try(var.aws_load_balancer_controller.policy_name_use_prefix, true)
  policy_path               = try(var.aws_load_balancer_controller.policy_path, null)
  policy_description        = try(var.aws_load_balancer_controller.policy_description, "IAM Policy for AWS Load Balancer Controller")

  oidc_providers = {
    this = {
      provider_arn = local.oidc_provider_arn
      # namespace is inherited from chart
      service_account = local.aws_load_balancer_controller_service_account
    }
  }

  tags = var.tags
}
