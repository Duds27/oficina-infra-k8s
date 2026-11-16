# ───────────────────────── EBS CSI driver + StorageClass gp3 ─────────────────────────
# O RabbitMQ precisa de volume persistente. Desde o Kubernetes 1.23 o provisionamento de
# EBS só funciona pelo driver CSI, e o add-on gerenciado precisa de uma role IRSA própria.
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name             = "${local.name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = module.ebs_csi_irsa.iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # 1 réplica do controller (o padrão é 2): economiza memória nos nós pequenos.
  configuration_values = jsonencode({
    controller = { replicaCount = 1 }
  })

  tags = local.tags

  # O controller roda nos nós: o node group precisa existir antes.
  depends_on = [module.eks]
}

# StorageClass padrão do cluster. A gp2 que o EKS cria não é marcada como padrão
# desde o Kubernetes 1.30, então PVCs sem storageClassName caem nesta.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}
