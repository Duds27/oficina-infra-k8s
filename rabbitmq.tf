# ─────────────────────────────── RabbitMQ ───────────────────────────────
# RabbitMQ Cluster Operator (oficial) + um RabbitmqCluster no namespace messaging.
# Os usuários dos serviços entram por um arquivo de definitions importado no boot, então
# não precisa do Messaging Topology Operator nem do cert-manager.

locals {
  rabbitmq_operator_url = "https://github.com/rabbitmq/cluster-operator/releases/download/${var.rabbitmq_operator_version}/cluster-operator.yml"

  # O manifesto pede 200m/500Mi para o operator, metade da memória de um t3.micro.
  # Ele usa bem menos que isso com um único RabbitmqCluster.
  rabbitmq_operator_resources = {
    requests = { cpu = "50m", memory = "128Mi" }
    limits   = { cpu = "200m", memory = "256Mi" }
  }

  rabbitmq_operator_documentos = [
    for doc in split("\n---\n", data.http.rabbitmq_operator.response_body) : yamldecode(doc)
    if trimspace(doc) != ""
  ]

  # Chave estável por objeto (tipo/namespace/nome) e o YAML final, já com os recursos
  # do Deployment do operator trocados.
  rabbitmq_operator_manifestos = {
    for doc in local.rabbitmq_operator_documentos :
    "${doc.kind}/${try(doc.metadata.namespace, "-")}/${doc.metadata.name}" => (
      doc.kind != "Deployment" ? yamlencode(doc) : yamlencode(merge(doc, {
        spec = merge(doc.spec, {
          template = merge(doc.spec.template, {
            spec = merge(doc.spec.template.spec, {
              containers = [
                for c in doc.spec.template.spec.containers : merge(c, { resources = local.rabbitmq_operator_resources })
              ]
            })
          })
        })
      }))
    )
  }

  rabbitmq_host = "rabbitmq.${kubernetes_namespace_v1.messaging.metadata[0].name}.svc.cluster.local"

  # Um usuário por serviço, com permissão só no vhost da aplicação. O MassTransit cria
  # exchanges e filas sob demanda, por isso configure/write/read liberados no vhost.
  #
  # Com definitions importadas no boot, o RabbitMQ não cria o usuário padrão do operator
  # (o secret rabbitmq-default-user existe, mas o usuário não). Daí o "admin" abaixo,
  # para a UI de management por port-forward.
  rabbitmq_usuarios = merge(
    { for servico in keys(var.servicos) : "${servico}-service" => { senha = random_password.rabbitmq[servico].result, tags = "" } },
    { admin = { senha = random_password.rabbitmq_admin.result, tags = "administrator" } }
  )

  rabbitmq_definitions = {
    vhosts = [{ name = var.rabbitmq_vhost }]
    users = [
      for nome, u in local.rabbitmq_usuarios : { name = nome, password = u.senha, tags = u.tags }
    ]
    permissions = [
      for nome in keys(local.rabbitmq_usuarios) : {
        user      = nome
        vhost     = var.rabbitmq_vhost
        configure = ".*"
        write     = ".*"
        read      = ".*"
      }
    ]
  }
}

# Versão fixa e conferida pelo SHA-256: um arquivo diferente do esperado derruba o plan.
data "http" "rabbitmq_operator" {
  url = local.rabbitmq_operator_url

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && sha256(self.response_body) == var.rabbitmq_operator_sha256
      error_message = "O cluster-operator.yml baixado não confere com rabbitmq_operator_sha256."
    }
  }
}

resource "kubectl_manifest" "rabbitmq_operator" {
  for_each = local.rabbitmq_operator_manifestos

  yaml_body = each.value
  # O CRD passa de 256 KiB, limite da anotação last-applied do apply do lado do cliente.
  server_side_apply = true
  force_conflicts   = true

  depends_on = [module.eks]
}

# ─────────────────────── Usuários dos serviços ───────────────────────
resource "random_password" "rabbitmq" {
  for_each = var.servicos

  length  = 32
  special = false # vai na URI AMQP e em variáveis de ambiente; só alfanuméricos
}

# Lido pelo CD de cada serviço (RABBITMQ_SECRET_ID) para montar o Secret do pod.
resource "aws_secretsmanager_secret" "rabbitmq" {
  for_each = var.servicos

  name                    = "${local.name}/rabbitmq/${each.key}"
  description             = "Credenciais do ${each.key}-service no RabbitMQ (vhost ${var.rabbitmq_vhost})."
  recovery_window_in_days = var.environment == "prod" ? 30 : 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "rabbitmq" {
  for_each = var.servicos

  secret_id = aws_secretsmanager_secret.rabbitmq[each.key].id
  secret_string = jsonencode({
    host     = local.rabbitmq_host
    port     = 5672
    vhost    = var.rabbitmq_vhost
    username = "${each.key}-service"
    password = random_password.rabbitmq[each.key].result
  })
}

resource "random_password" "rabbitmq_admin" {
  length  = 32
  special = false
}

# Usuário da UI de management (kubectl port-forward svc/rabbitmq 15672 -n messaging).
resource "aws_secretsmanager_secret" "rabbitmq_admin" {
  name                    = "${local.name}/rabbitmq/admin"
  description             = "Administrador do RabbitMQ (UI de management por port-forward)."
  recovery_window_in_days = var.environment == "prod" ? 30 : 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "rabbitmq_admin" {
  secret_id = aws_secretsmanager_secret.rabbitmq_admin.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.rabbitmq_admin.result
  })
}

# Importado pelo RabbitMQ no boot (load_definitions). Mudou a senha? Reinicie o pod.
resource "kubernetes_secret_v1" "rabbitmq_definitions" {
  metadata {
    name      = "rabbitmq-definitions"
    namespace = kubernetes_namespace_v1.messaging.metadata[0].name
  }

  data = {
    "definitions.json" = jsonencode(local.rabbitmq_definitions)
  }
}

# ─────────────────────────── RabbitmqCluster ───────────────────────────
resource "kubectl_manifest" "rabbitmq_cluster" {
  yaml_body = yamlencode({
    apiVersion = "rabbitmq.com/v1beta1"
    kind       = "RabbitmqCluster"
    metadata = {
      name      = "rabbitmq"
      namespace = kubernetes_namespace_v1.messaging.metadata[0].name
    }
    spec = {
      replicas = var.rabbitmq_replicas
      image    = var.rabbitmq_image

      # O padrão do operator é 7 dias, para esperar a sincronização das filas. Com 1 réplica
      # não há o que sincronizar, e com 3 as quorum queues já toleram a saída de um nó.
      terminationGracePeriodSeconds = 120

      # Memória: request igual ao limit, como o operator recomenda. O RabbitMQ calcula o
      # alarme de memória a partir do limit, e com request menor o nó pode ficar sem a
      # memória que ele conta ter.
      resources = {
        requests = { cpu = "100m", memory = var.rabbitmq_memory }
        limits   = { cpu = "500m", memory = var.rabbitmq_memory }
      }

      persistence = {
        storageClassName = kubernetes_storage_class_v1.gp3.metadata[0].name
        storage          = var.rabbitmq_storage
      }

      rabbitmq = {
        additionalPlugins = ["rabbitmq_management", "rabbitmq_prometheus"]
        additionalConfig  = <<-EOT
          load_definitions = /etc/rabbitmq/definitions/definitions.json
        EOT
      }

      override = {
        statefulSet = {
          spec = {
            template = {
              spec = {
                containers = [{
                  name = "rabbitmq"
                  volumeMounts = [{
                    name      = "definitions"
                    mountPath = "/etc/rabbitmq/definitions"
                    readOnly  = true
                  }]
                }]
                volumes = [{
                  name   = "definitions"
                  secret = { secretName = kubernetes_secret_v1.rabbitmq_definitions.metadata[0].name }
                }]
              }
            }
          }
        }
      }
    }
  })

  depends_on = [kubectl_manifest.rabbitmq_operator, aws_eks_addon.ebs_csi]
}
