output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.bootstrap.id
}

output "private_ip" {
  description = "Private IP address"
  value       = aws_instance.bootstrap.private_ip
}

output "public_ip" {
  description = "Public IP address (EIP if created, otherwise instance public IP)"
  value       = var.create_eip ? aws_eip.bootstrap[0].public_ip : aws_instance.bootstrap.public_ip
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.bootstrap.id
}

output "stun_endpoint" {
  description = "STUN server endpoint"
  value       = "${var.create_eip ? aws_eip.bootstrap[0].public_ip : aws_instance.bootstrap.public_ip}:3478"
}

output "omertad_endpoint" {
  description = "Omertad mesh endpoint"
  value       = "${var.create_eip ? aws_eip.bootstrap[0].public_ip : aws_instance.bootstrap.public_ip}:9999"
}
