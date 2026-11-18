# ───────────────────────── EBS CSI driver + StorageClass gp3 ─────────────────────────
# O RabbitMQ precisa de volume persistente. Desde o Kubernetes 1.23 o provisionamento de
# EBS só funciona pelo driver CSI, e o add-on gerenciado precisa de uma role própria, entregue
# por Pod Identity (a associação é criada pelo próprio add-on, abaixo).
module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 1.12"

  name                      = "${local.name}-ebs-csi"
  use_name_prefix           = false
  attach_aws_ebs_csi_policy = true

  tags = local.tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # 1 réplica do controller (o padrão é 2): economiza memória nos nós pequenos.
  configuration_values = jsonencode({
    controller = { replicaCount = 1 }
  })

  pod_identity_association {
    role_arn        = module.ebs_csi_pod_identity.iam_role_arn
    service_account = "ebs-csi-controller-sa"
  }

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
