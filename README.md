# uCore HCloud

A Terraform project to automate the provisioning of a VPS on Hetzner Cloud with
[uCore](https://github.com/ublue-os/ucore) installed.

To use it first create a `terraform.tfvars` file with your credentials, then run:

```bash
terraform init
terraform apply
ssh core@$(terraform output -raw ipv4_address)
```
