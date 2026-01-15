output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.rendezvous.id
}

output "private_ip" {
  description = "Private IP address"
  value       = aws_instance.rendezvous.private_ip
}

output "public_ip" {
  description = "Public IP address (EIP if created, otherwise instance public IP)"
  value       = var.create_eip ? aws_eip.rendezvous[0].public_ip : aws_instance.rendezvous.public_ip
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.rendezvous.id
}

output "signaling_endpoint" {
  description = "WebSocket signaling endpoint"
  value       = "ws://${var.create_eip ? aws_eip.rendezvous[0].public_ip : aws_instance.rendezvous.public_ip}:8080"
}

output "stun_endpoint" {
  description = "STUN server endpoint"
  value       = "${var.create_eip ? aws_eip.rendezvous[0].public_ip : aws_instance.rendezvous.public_ip}:3478"
}

output "relay_endpoint" {
  description = "Relay server endpoint"
  value       = "${var.create_eip ? aws_eip.rendezvous[0].public_ip : aws_instance.rendezvous.public_ip}:3479"
}
