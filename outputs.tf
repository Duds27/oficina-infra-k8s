output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "nodes_security_group_id" {
  description = "SG dos nós do EKS (usado por RDS e VPC Link)."
  value       = module.eks.node_security_group_id
}

# ─────────────── NLB por serviço (consumidos pela Lambda e pelos CDs) ───────────────
output "nlb_dns_name" {
  description = "DNS do NLB interno. A Lambda chama o os-service em http://<dns>:<porta do os>."
  value       = aws_lb.app.dns_name
}

output "listener_arns" {
  description = "Serviço → ARN do listener (integração VPC Link de cada rota do API Gateway)."
  value       = { for s, l in aws_lb_listener.servico : s => l.arn }
}

output "listener_ports" {
  description = "Serviço → porta do listener no NLB."
  value       = var.servicos
}

output "target_group_arns" {
  description = "Serviço → ARN do target group (TARGET_GROUP_ARN do CD, usado no TargetGroupBinding)."
  value       = { for s, tg in aws_lb_target_group.servico : s => tg.arn }
}

output "service_namespaces" {
  description = "Serviço → namespace Kubernetes."
  value       = { for s, ns in kubernetes_namespace_v1.servico : s => ns.metadata[0].name }
}

# ─────────────────────────────── RabbitMQ ───────────────────────────────
output "rabbitmq_host" {
  value = local.rabbitmq_host
}

output "rabbitmq_secret_ids" {
  description = "Serviço → nome do secret com as credenciais dele (RABBITMQ_SECRET_ID do CD)."
  value       = { for s, sec in aws_secretsmanager_secret.rabbitmq : s => sec.name }
}

output "rabbitmq_admin_secret_id" {
  description = "Secret com o usuário da UI de management."
  value       = aws_secretsmanager_secret.rabbitmq_admin.name
}

# Compatibilidade com a Fase 3 (um listener só): apontam para o os-service. Saem quando a
# Lambda e o CD do os-service passarem a usar listener_arns e target_group_arns.
output "app_listener_arn" {
  description = "Obsoleto: use listener_arns[\"os\"]."
  value       = aws_lb_listener.servico["os"].arn
}

output "app_target_group_arn" {
  description = "Obsoleto: use target_group_arns[\"os\"]."
  value       = aws_lb_target_group.servico["os"].arn
}
