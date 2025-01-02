output "ipv4_address" {
  description = "Public IPv4 address of the server"
  value       = hcloud_server.master.ipv4_address
}
