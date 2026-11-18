variable "aws_region" {
  type = string
  # A conta do grupo (Free plan, numa organização gerenciada pela AWS) só libera a us-east-2.
  default = "us-east-2"
}

variable "cluster_admin_arns" {
  type        = list(string)
  default     = []
  description = "Usuários ou roles IAM com acesso de admin ao cluster, além de quem o criou: o usuário do CD dos serviços e quem usa o kubectl."
}

variable "project" {
  type    = string
  default = "oficina"
}

variable "environment" {
  type        = string
  description = "Ambiente (homolog | prod)."
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "kubernetes_version" {
  # Use uma versão em suporte no EKS (as antigas perdem as AMIs dos nós).
  # Verifique as disponíveis com:
  #   aws eks describe-cluster-versions --query "clusterVersions[?status=='STANDARD_SUPPORT'].clusterVersion" --output table
  type    = string
  default = "1.36"
}

variable "node_instance_types" {
  # t3.micro é free-tier-eligible (contas no Free Plan bloqueiam tipos maiores).
  # Requer prefix delegation na VPC CNI (ver cluster_addons no main.tf) para caber
  # os pods. Em conta paga, prefira t3.small/t3.medium.
  type    = list(string)
  default = ["t3.micro"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 5
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_pods" {
  # Eleva o teto de pods/nó (o t3.micro vem com 4). Requer prefix delegation na VPC CNI
  # (já habilitado em cluster_addons). ~34 é o teto teórico do t3.micro; 17 dá folga
  # segura — na prática a memória (1 GiB) é o limite real.
  type    = number
  default = 17
}

variable "newrelic_license_key" {
  type        = string
  default     = ""
  description = "Chave de licença do New Relic para o nri-bundle (vazio desabilita o release)."
  sensitive   = true
}

# ─────────────────────── Fase 4: serviços, NLB e RabbitMQ ───────────────────────

variable "servicos" {
  type        = map(number)
  description = "Serviço → porta do listener no NLB interno. Cada um ganha namespace oficina-<serviço>, target group e usuário no RabbitMQ."
  default = {
    os        = 8081
    billing   = 8082
    execution = 8083
  }

  validation {
    condition     = length(distinct(values(var.servicos))) == length(var.servicos)
    error_message = "Cada serviço precisa de uma porta própria no NLB."
  }

  validation {
    condition     = contains(keys(var.servicos), "os")
    error_message = "O os-service é obrigatório: a Lambda e as saídas app_* apontam para ele."
  }
}

variable "rabbitmq_operator_version" {
  type        = string
  default     = "v2.21.1"
  description = "Versão do RabbitMQ Cluster Operator. A partir da v2.22 ele exige cert-manager e RabbitMQ 4.2.4+, por isso a 2.21."
}

variable "rabbitmq_operator_sha256" {
  type        = string
  default     = "d859369dc044d765f316fe50dbc45368ef99a99bc4d1268ae6187d7a98b319bd"
  description = "SHA-256 do cluster-operator.yml da versão acima. O plan falha se o arquivo baixado for diferente."
}

variable "rabbitmq_image" {
  type        = string
  default     = "rabbitmq:4.1-management"
  description = "Imagem do broker: a mesma dos composes, validada com o MassTransit 8.4.1 no spike S1."
}

variable "rabbitmq_replicas" {
  type        = number
  default     = 1
  description = "1 em homolog (custo). Em prod, 3 réplicas com quorum queues."

  validation {
    condition     = contains([1, 3], var.rabbitmq_replicas)
    error_message = "Use 1 réplica (homolog) ou 3 (prod, quorum)."
  }
}

variable "rabbitmq_memory" {
  type        = string
  default     = "512Mi"
  description = "Memória de cada réplica do RabbitMQ (request = limit)."
}

variable "rabbitmq_storage" {
  type        = string
  default     = "2Gi"
  description = "Tamanho do volume gp3 de cada réplica do RabbitMQ."
}

variable "rabbitmq_vhost" {
  type    = string
  default = "oficina"
}
