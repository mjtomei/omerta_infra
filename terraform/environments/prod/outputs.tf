# =============================================================================
# EC2 Outputs
# =============================================================================

output "bootstrap1_public_ip" {
  description = "Public IP for bootstrap1.omerta.run"
  value       = module.bootstrap1.public_ip
}

output "bootstrap2_public_ip" {
  description = "Public IP for bootstrap2.omerta.run"
  value       = module.bootstrap2.public_ip
}

output "bootstrap1_endpoints" {
  description = "All endpoints for bootstrap1"
  value = {
    omertad = module.bootstrap1.omertad_endpoint
  }
}

output "bootstrap2_endpoints" {
  description = "All endpoints for bootstrap2"
  value = {
    omertad = module.bootstrap2.omertad_endpoint
  }
}

# =============================================================================
# Domain Configuration
# =============================================================================

output "domain_name" {
  description = "Domain name used for bootstrap servers"
  value       = var.domain_name
}

# =============================================================================
# Route53 DNS Outputs
# =============================================================================

output "route53_zone_id" {
  description = "Route53 hosted zone ID"
  value       = aws_route53_zone.omerta.zone_id
}

output "route53_nameservers" {
  description = "Route53 nameservers - configure these in Squarespace"
  value       = aws_route53_zone.omerta.name_servers
}

output "dns_records_created" {
  description = "DNS records managed by Terraform"
  value = {
    "bootstrap1.${var.domain_name}" = module.bootstrap1.public_ip
    "bootstrap2.${var.domain_name}" = module.bootstrap2.public_ip
  }
}

output "squarespace_setup_instructions" {
  description = "Instructions for configuring Squarespace nameservers"
  value       = <<-EOT

    ============================================================
    SQUARESPACE NAMESERVER CONFIGURATION
    ============================================================

    To delegate DNS to Route53, update your nameservers in Squarespace:

    1. Log in to Squarespace Domains
    2. Select omerta.run
    3. Go to DNS Settings > Nameservers
    4. Select "Use custom nameservers"
    5. Enter these Route53 nameservers:

       ${join("\n       ", aws_route53_zone.omerta.name_servers)}

    6. Save changes

    Note: DNS propagation may take up to 48 hours.

    ============================================================
  EOT
}
