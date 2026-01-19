# Staging environment outputs

output "bootstrap1_public_ip" {
  description = "Public IP of staging bootstrap1"
  value       = module.bootstrap1.public_ip
}

output "bootstrap2_public_ip" {
  description = "Public IP of staging bootstrap2"
  value       = module.bootstrap2.public_ip
}

output "bootstrap1_instance_id" {
  description = "Instance ID of staging bootstrap1"
  value       = module.bootstrap1.instance_id
}

output "bootstrap2_instance_id" {
  description = "Instance ID of staging bootstrap2"
  value       = module.bootstrap2.instance_id
}

output "domain_name" {
  description = "Domain name"
  value       = var.domain_name
}

output "bootstrap1_dns" {
  description = "DNS name for staging bootstrap1"
  value       = "staging-bootstrap1.${var.domain_name}"
}

output "bootstrap2_dns" {
  description = "DNS name for staging bootstrap2"
  value       = "staging-bootstrap2.${var.domain_name}"
}
