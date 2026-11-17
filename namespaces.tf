# ───────────────────────────── Namespaces ─────────────────────────────
# Um namespace por serviço (oficina-os, oficina-billing, oficina-execution) e o do broker.
# Ficam aqui, e não nos manifestos dos serviços, para o CD de cada serviço não disputar a
# posse do namespace com o Terraform. Os overlays locais (kind) criam os seus.
resource "kubernetes_namespace_v1" "servico" {
  for_each = var.servicos

  metadata {
    name = "oficina-${each.key}"
    labels = {
      "app.kubernetes.io/part-of" = "oficina-mecanica"
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace_v1" "messaging" {
  metadata {
    name = "messaging"
    labels = {
      "app.kubernetes.io/part-of" = "oficina-mecanica"
    }
  }

  depends_on = [module.eks]
}
