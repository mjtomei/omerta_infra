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

output "dns_records_to_create" {
  description = "DNS records to create manually if not using Route53"
  value = <<-EOT
    Create the following A records:

    rendezvous1.mtomei.com -> ${module.rendezvous1.public_ip}
    rendezvous2.mtomei.com -> ${module.rendezvous2.public_ip}
    stun1.mtomei.com       -> ${module.rendezvous1.public_ip}
    stun2.mtomei.com       -> ${module.rendezvous2.public_ip}
  EOT
}
