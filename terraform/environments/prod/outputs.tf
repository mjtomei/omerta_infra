# =============================================================================
# EC2 Outputs
# =============================================================================

output "rendezvous1_public_ip" {
  description = "Public IP for rendezvous1.mtomei.com"
  value       = module.rendezvous1.public_ip
}

output "rendezvous2_public_ip" {
  description = "Public IP for rendezvous2.mtomei.com"
  value       = module.rendezvous2.public_ip
}

output "rendezvous1_endpoints" {
  description = "All endpoints for rendezvous1"
  value = {
    signaling = module.rendezvous1.signaling_endpoint
    stun      = module.rendezvous1.stun_endpoint
    relay     = module.rendezvous1.relay_endpoint
  }
}

output "rendezvous2_endpoints" {
  description = "All endpoints for rendezvous2"
  value = {
    signaling = module.rendezvous2.signaling_endpoint
    stun      = module.rendezvous2.stun_endpoint
    relay     = module.rendezvous2.relay_endpoint
  }
}

# =============================================================================
# Route53 DNS Outputs
# =============================================================================

output "route53_zone_id" {
  description = "Route53 hosted zone ID"
  value       = aws_route53_zone.mtomei.zone_id
}

output "route53_nameservers" {
  description = "Route53 nameservers - configure these in Squarespace"
  value       = aws_route53_zone.mtomei.name_servers
}

output "dns_records_created" {
  description = "DNS records managed by Terraform"
  value = {
    "rendezvous1.${var.domain_name}" = module.rendezvous1.public_ip
    "rendezvous2.${var.domain_name}" = module.rendezvous2.public_ip
    "stun1.${var.domain_name}"       = module.rendezvous1.public_ip
    "stun2.${var.domain_name}"       = module.rendezvous2.public_ip
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
    2. Select mtomei.com
    3. Go to DNS Settings > Nameservers
    4. Select "Use custom nameservers"
    5. Enter these Route53 nameservers:

       ${join("\n       ", aws_route53_zone.mtomei.name_servers)}

    6. Save changes

    Note: DNS propagation may take up to 48 hours.

    ============================================================
  EOT
}
