# ───────────────────────── metrics-server (HPA) ─────────────────────────
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.1"

  depends_on = [module.eks]
}

# ───────────────────── AWS Load Balancer Controller ─────────────────────
# Role do controller (gerencia NLB/ALB e TargetGroupBinding), entregue por Pod Identity à
# ServiceAccount dele.
module "lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 1.12"

  name                            = "${local.name}-lb-controller"
  use_name_prefix                 = false
  attach_aws_lb_controller_policy = true

  associations = {
    controller = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }

  tags = local.tags
}

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
  # 1 réplica (o padrão é 2) — economiza recursos em nós pequenos (free tier).
  set {
    name  = "replicaCount"
    value = "1"
  }

  # A associação do Pod Identity precisa existir quando o pod nasce: é aí que o EKS injeta as
  # variáveis de credencial.
  depends_on = [module.eks, module.lb_controller_pod_identity, helm_release.metrics_server]
}

# ───────────────────── New Relic Kubernetes integration ─────────────────────
# Coleta CPU/memória/uptime/eventos do cluster. Só é instalado se a licença for informada.
resource "helm_release" "newrelic" {
  count = var.newrelic_license_key != "" ? 1 : 0

  name             = "newrelic-bundle"
  repository       = "https://helm-charts.newrelic.com"
  chart            = "nri-bundle"
  namespace        = "newrelic"
  create_namespace = true
  version          = "5.0.99"

  set {
    name  = "global.licenseKey"
    value = var.newrelic_license_key
  }
  set {
    name  = "global.cluster"
    value = local.name
  }
  set {
    name  = "newrelic-infrastructure.privileged"
    value = "true"
  }
  set {
    name  = "kube-state-metrics.enabled"
    value = "true"
  }
  set {
    name  = "nri-kube-events.enabled"
    value = "true"
  }
  set {
    name  = "logging.enabled"
    value = "true"
  }
  # Prometheus agent: coleta as métricas dos pods anotados com prometheus.io/scrape, como o
  # RabbitMQ (profundidade das filas, _error, consumidores, publish/ack). Etapa 5, 5.4.
  set {
    name  = "newrelic-prometheus-agent.enabled"
    value = "true"
  }

  depends_on = [module.eks]
}
