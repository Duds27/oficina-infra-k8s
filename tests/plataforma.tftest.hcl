# Testes sem conta AWS nem cluster: providers mockados e os módulos da VPC, do EKS e das
# roles IRSA substituídos pelas saídas que os recursos daqui usam.
# Rodar com: terraform init -backend=false && terraform test

# O provider AWS valida o formato dos ARNs que um recurso passa para outro.
mock_provider "aws" {
  mock_resource "aws_lb" {
    defaults = {
      arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/oficina-homolog-app-nlb/abc"
      dns_name = "oficina-homolog-app-nlb.elb.us-east-1.amazonaws.com"
    }
  }
  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/net/oficina-homolog-app-nlb/abc/def"
    }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "http" {}
mock_provider "random" {}

override_module {
  target = module.vpc
  outputs = {
    vpc_id          = "vpc-123"
    vpc_cidr_block  = "10.20.0.0/16"
    private_subnets = ["subnet-a", "subnet-b"]
    public_subnets  = ["subnet-c", "subnet-d"]
  }
}

override_module {
  target = module.eks
  outputs = {
    cluster_name                       = "oficina-homolog"
    cluster_endpoint                   = "https://eks.exemplo"
    cluster_certificate_authority_data = "Y2E="
    oidc_provider_arn                  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/ABC"
    node_security_group_id             = "sg-nos"
  }
}

override_module {
  target  = module.lb_controller_irsa
  outputs = { iam_role_arn = "arn:aws:iam::123456789012:role/lb-controller" }
}

override_module {
  target  = module.ebs_csi_irsa
  outputs = { iam_role_arn = "arn:aws:iam::123456789012:role/ebs-csi" }
}

override_resource {
  target = aws_lb_target_group.servico["os"]
  values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina-homolog-os-tg/abc" }
}

override_resource {
  target = aws_lb_target_group.servico["billing"]
  values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina-homolog-billing-tg/abc" }
}

override_resource {
  target = aws_lb_target_group.servico["execution"]
  values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/oficina-homolog-execution-tg/abc" }
}

override_data {
  target = data.aws_availability_zones.available
  values = { names = ["us-east-1a", "us-east-1b"] }
}

# Um manifesto mínimo no lugar do cluster-operator.yml: um Namespace e o Deployment do
# operator com os recursos originais (200m/500Mi). O SHA-256 abaixo é o deste texto.
override_data {
  target = data.http.rabbitmq_operator
  values = {
    status_code   = 200
    response_body = "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: rabbitmq-system\n---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: rabbitmq-cluster-operator\n  namespace: rabbitmq-system\nspec:\n  template:\n    spec:\n      containers:\n      - name: operator\n        image: ghcr.io/rabbitmq/cluster-operator:2.21.1\n        resources:\n          requests:\n            cpu: 200m\n            memory: 500Mi\n"
  }
}

variables {
  environment              = "homolog"
  rabbitmq_operator_sha256 = "f9af97f0b083988099dfbd4e76829fc71fb31a86cd33a955c610258d57e21369"
}

run "um_listener_e_um_target_group_por_servico" {
  assert {
    condition     = { for s, l in aws_lb_listener.servico : s => l.port } == { os = 8081, billing = 8082, execution = 8083 }
    error_message = "Listeners 8081 (os), 8082 (billing) e 8083 (execution)."
  }

  assert {
    condition = alltrue([
      for s, l in aws_lb_listener.servico : l.default_action[0].target_group_arn == aws_lb_target_group.servico[s].arn
    ])
    error_message = "Cada listener encaminha para o target group do próprio serviço."
  }

  assert {
    condition = alltrue([
      for tg in aws_lb_target_group.servico :
      tg.target_type == "ip" && tg.port == 8080 && tg.health_check[0].path == "/health/ready"
    ])
    error_message = "Target groups do tipo IP, na porta 8080 dos pods, com health check em /health/ready."
  }

  assert {
    condition     = output.app_listener_arn == aws_lb_listener.servico["os"].arn && output.target_group_arns["billing"] == aws_lb_target_group.servico["billing"].arn
    error_message = "Saídas por serviço, e as antigas (app_*) apontando para o os-service."
  }
}

run "namespaces_dos_servicos_e_do_broker" {
  assert {
    condition     = sort([for ns in kubernetes_namespace_v1.servico : ns.metadata[0].name]) == tolist(["oficina-billing", "oficina-execution", "oficina-os"])
    error_message = "Um namespace oficina-<serviço> para cada serviço."
  }

  assert {
    condition     = kubernetes_namespace_v1.messaging.metadata[0].name == "messaging"
    error_message = "O RabbitMQ fica no namespace messaging."
  }
}

run "ebs_csi_com_irsa_e_gp3_como_padrao" {
  assert {
    condition     = aws_eks_addon.ebs_csi.service_account_role_arn == "arn:aws:iam::123456789012:role/ebs-csi"
    error_message = "O add-on do EBS CSI usa a role IRSA própria."
  }

  assert {
    condition = (
      kubernetes_storage_class_v1.gp3.storage_provisioner == "ebs.csi.aws.com" &&
      kubernetes_storage_class_v1.gp3.parameters["type"] == "gp3" &&
      kubernetes_storage_class_v1.gp3.metadata[0].annotations["storageclass.kubernetes.io/is-default-class"] == "true"
    )
    error_message = "StorageClass gp3 do EBS CSI, marcada como padrão."
  }
}

run "rabbitmq_com_um_usuario_por_servico" {
  assert {
    condition     = sort([for s in aws_secretsmanager_secret.rabbitmq : s.name]) == tolist(["oficina-homolog/rabbitmq/billing", "oficina-homolog/rabbitmq/execution", "oficina-homolog/rabbitmq/os"])
    error_message = "Um secret por serviço em <projeto>-<ambiente>/rabbitmq/<serviço>."
  }

  assert {
    condition = (
      jsondecode(aws_secretsmanager_secret_version.rabbitmq["billing"].secret_string).username == "billing-service" &&
      jsondecode(aws_secretsmanager_secret_version.rabbitmq["billing"].secret_string).host == "rabbitmq.messaging.svc.cluster.local" &&
      jsondecode(aws_secretsmanager_secret_version.rabbitmq["billing"].secret_string).vhost == "oficina" &&
      jsondecode(aws_secretsmanager_secret_version.rabbitmq["billing"].secret_string).password == random_password.rabbitmq["billing"].result
    )
    error_message = "O secret traz host, vhost, usuário e a senha gerada do serviço."
  }

  assert {
    condition = (
      sort([for u in jsondecode(kubernetes_secret_v1.rabbitmq_definitions.data["definitions.json"]).users : u.name]) == tolist(["admin", "billing-service", "execution-service", "os-service"]) &&
      one([for u in jsondecode(kubernetes_secret_v1.rabbitmq_definitions.data["definitions.json"]).users : u.tags if u.name == "admin"]) == "administrator" &&
      alltrue([for u in jsondecode(kubernetes_secret_v1.rabbitmq_definitions.data["definitions.json"]).users : u.tags == "" if u.name != "admin"]) &&
      alltrue([
        for p in jsondecode(kubernetes_secret_v1.rabbitmq_definitions.data["definitions.json"]).permissions : p.vhost == "oficina"
      ])
    )
    error_message = "As definitions criam os 3 usuários dos serviços e o admin da UI, todos só no vhost oficina."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.rabbitmq_cluster.yaml_body).spec.replicas == 1 &&
      yamldecode(kubectl_manifest.rabbitmq_cluster.yaml_body).spec.image == "rabbitmq:4.1-management" &&
      yamldecode(kubectl_manifest.rabbitmq_cluster.yaml_body).spec.persistence.storageClassName == "gp3" &&
      yamldecode(kubectl_manifest.rabbitmq_cluster.yaml_body).spec.resources.requests.memory == yamldecode(kubectl_manifest.rabbitmq_cluster.yaml_body).spec.resources.limits.memory
    )
    error_message = "Em homolog: 1 réplica, imagem fixada, volume gp3 e memória com request igual ao limit."
  }

  assert {
    condition     = aws_secretsmanager_secret.rabbitmq["os"].recovery_window_in_days == 0
    error_message = "Fora de prod, o secret pode ser apagado na hora (destroy e recriação do ambiente)."
  }
}

run "metricas_do_rabbitmq_por_fila_e_coletadas" {
  variables {
    newrelic_license_key = "licenca-de-teste"
  }

  assert {
    condition     = strcontains(yamldecode(kubectl_manifest.rabbitmq_cluster.yaml_body).spec.rabbitmq.additionalConfig, "prometheus.return_per_object_metrics = true")
    error_message = "O plugin Prometheus expõe as métricas por fila (para ver as _error)."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.rabbitmq_cluster.yaml_body).spec.override.statefulSet.spec.template.metadata.annotations["prometheus.io/scrape"] == "true" &&
      yamldecode(kubectl_manifest.rabbitmq_cluster.yaml_body).spec.override.statefulSet.spec.template.metadata.annotations["prometheus.io/port"] == "15692"
    )
    error_message = "Pod do RabbitMQ anotado para o scrape na porta 15692."
  }

  assert {
    condition     = contains([for s in helm_release.newrelic[0].set : "${s.name}=${s.value}"], "newrelic-prometheus-agent.enabled=true")
    error_message = "O nri-bundle liga o Prometheus agent, que coleta os pods anotados."
  }
}

run "operator_fixado_e_com_recursos_reduzidos" {
  assert {
    condition     = data.http.rabbitmq_operator.url == "https://github.com/rabbitmq/cluster-operator/releases/download/v2.21.1/cluster-operator.yml"
    error_message = "Operator fixado na v2.21.1."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.rabbitmq_operator["Deployment/rabbitmq-system/rabbitmq-cluster-operator"].yaml_body).spec.template.spec.containers[0].resources.requests.memory == "128Mi" &&
      yamldecode(kubectl_manifest.rabbitmq_operator["Namespace/-/rabbitmq-system"].yaml_body).kind == "Namespace"
    )
    error_message = "O Deployment do operator ganha requests menores, e os demais objetos passam como estão."
  }

  assert {
    condition     = kubectl_manifest.rabbitmq_operator["Deployment/rabbitmq-system/rabbitmq-cluster-operator"].server_side_apply
    error_message = "Server-side apply: o CRD real passa do limite da anotação last-applied."
  }
}

run "prod_com_tres_replicas" {
  variables {
    environment       = "prod"
    rabbitmq_replicas = 3
  }

  assert {
    condition     = yamldecode(kubectl_manifest.rabbitmq_cluster.yaml_body).spec.replicas == 3
    error_message = "Em prod, 3 réplicas."
  }

  assert {
    condition     = aws_secretsmanager_secret.rabbitmq["os"].recovery_window_in_days == 30
    error_message = "Em prod, 30 dias para recuperar um secret apagado."
  }
}

run "manifesto_do_operator_diferente_derruba_o_plan" {
  command = plan

  variables {
    rabbitmq_operator_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
  }

  expect_failures = [data.http.rabbitmq_operator]
}

run "rabbitmq_aceita_so_1_ou_3_replicas" {
  command = plan

  variables {
    rabbitmq_replicas = 2
  }

  expect_failures = [var.rabbitmq_replicas]
}

run "os_service_e_obrigatorio" {
  command = plan

  variables {
    servicos = { billing = 8082 }
  }

  expect_failures = [var.servicos]
}
