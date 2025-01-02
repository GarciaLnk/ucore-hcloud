####
# Variables
##

variable "hcloud_token" {
  description = "Hetzner Cloud API Token"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_file" {
  description = "Local path to your public key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_file" {
  description = "Local path to your private key"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "ssh_public_key_name" {
  description = "Name of your public key to identify at Hetzner Cloud portal"
  type        = string
  default     = "My-SSH-Key"
}

variable "hcloud_server_type" {
  description = "vServer type name, lookup via `hcloud server-type list`"
  type        = string
  default     = "cx22"
}

variable "hcloud_server_datacenter" {
  description = "Desired datacenter location name, lookup via `hcloud datacenter list`"
  type        = string
  default     = "nbg1-dc3"
}

variable "hcloud_server_name" {
  description = "Name of the server"
  type        = string
  default     = "my-server"
}

variable "image_name" {
  description = "Name of the uCore image"
  type        = string
  default     = "ucore"
}

variable "image_tag" {
  description = "Tag of the uCore image"
  type        = string
  default     = "stable"
}

# Update version to the latest release of Butane
variable "tools_butane_version" {
  description = "See https://github.com/coreos/butane/releases for available versions"
  type        = string
  default     = "0.23.0"
}

variable "tailscale_auth_key" {
  description = "Tailscale Auth Key"
  type        = string
  sensitive   = true
}

variable "password_hash" {
  description = "Password hash for the core user"
  type        = string
  sensitive   = true
}

####
# Infrastructure config
##

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_ssh_key" "key" {
  name       = var.ssh_public_key_name
  public_key = file(var.ssh_public_key_file)
}

resource "hcloud_firewall" "default_firewall" {
  name = "default_firewall"

  # Open ports beyond 32767
  rule {
    direction = "in"
    protocol  = "udp"
    port      = "32768-65535"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }

  # SSH
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }

  # HTTP
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }

  # HTTPS
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }

  # HTTP/Testing
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "8080"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }
}

resource "hcloud_server" "master" {
  name   = var.hcloud_server_name
  labels = { "os" = "coreos" }

  server_type  = var.hcloud_server_type
  datacenter   = var.hcloud_server_datacenter
  firewall_ids = [hcloud_firewall.default_firewall.id]

  # Image is ignored, as we boot into rescue mode, but is a required field
  image    = "fedora-41"
  rescue   = "linux64"
  ssh_keys = [hcloud_ssh_key.key.id]

  connection {
    host        = self.ipv4_address
    timeout     = "5m"
    private_key = file(var.ssh_private_key_file)
    # Root is the available user in rescue mode
    user = "root"
  }

  # Wait for the server to be available
  provisioner "local-exec" {
    command = "until nc -zv ${self.ipv4_address} 22; do sleep 5; done"
  }

  # Copy config.yaml and replace $ssh_public_key and $passwd_hash variables
  provisioner "file" {
    content     = replace(replace(file("config.yaml"), "$ssh_public_key", trimspace(file(var.ssh_public_key_file))), "$passwd_hash", var.password_hash)
    destination = "/root/config.yaml"
  }

  # Install Butane in rescue mode
  provisioner "remote-exec" {
    inline = [
      "set -x",
      # Convert ignition yaml into json using Butane
      "wget -O /usr/local/bin/butane 'https://github.com/coreos/butane/releases/download/v${var.tools_butane_version}/butane-x86_64-unknown-linux-gnu'",
      "chmod +x /usr/local/bin/butane",
      "butane --strict < config.yaml > config.ign",
      "apt-get -y install podman",
      # Download and install Fedora CoreOS to /dev/sda
      "podman run --network=host --pull=always --privileged --rm -v /dev:/dev -v /run/udev:/run/udev -v /root:/data -w /data quay.io/coreos/coreos-installer:release install /dev/sda -i /data/config.ign",
    ]
  }

  # Ignore failures on reboot
  provisioner "remote-exec" {
    on_failure = continue

    inline = [
      # Exit rescue mode and boot into coreos
      "reboot"
    ]
  }

  # Wait for the server to be available
  provisioner "local-exec" {
    command = "until nc -zv ${self.ipv4_address} 22; do sleep 5; done"
  }

  # Configure CoreOS after installation
  provisioner "remote-exec" {
    connection {
      host        = self.ipv4_address
      timeout     = "1m"
      private_key = file(var.ssh_private_key_file)
      # This user is configured in config.yaml
      user = "core"
    }

    inline = [
      "sudo hostnamectl set-hostname ${self.name}",
      # Install uCore (unverified)
      "sudo rpm-ostree rebase --bypass-driver ostree-unverified-registry:ghcr.io/ublue-os/${var.image_name}:${var.image_tag}",
    ]
  }

  # Ignore failures on reboot
  provisioner "remote-exec" {
    connection {
      host        = self.ipv4_address
      timeout     = "1m"
      private_key = file(var.ssh_private_key_file)
      user        = "core"
    }

    on_failure = continue

    inline = [
      "sudo systemctl reboot"
    ]
  }

  # Wait for the server to be available
  provisioner "local-exec" {
    command = "until nc -zv ${self.ipv4_address} 22; do sleep 5; done"
  }

  # Configure uCore after installation
  provisioner "remote-exec" {
    connection {
      host        = self.ipv4_address
      timeout     = "1m"
      private_key = file(var.ssh_private_key_file)
      # This user is configured in config.yaml
      user = "core"
    }

    inline = [
      # Pin current deployment
      "sudo ostree admin pin 0",
      # Automatically start containers on boot
      "mkdir -p $HOME/.config/systemd/user",
      "cp /lib/systemd/system/podman-restart.service $HOME/.config/systemd/user",
      "systemctl --user enable podman-restart.service",
      "loginctl enable-linger $UID",
      # Tailscale
      "sudo systemctl enable --now tailscaled",
      "firewall-cmd --permanent --add-masquerade",
      "sudo tailscale up --auth-key=${var.tailscale_auth_key} --ssh --advertise-exit-node --operator=core",
      # Cockpit
      "sudo systemctl enable --now cockpit",
      # Install uCore (signed)
      "sudo rpm-ostree rebase --bypass-driver ostree-image-signed:docker://ghcr.io/ublue-os/${var.image_name}:${var.image_tag}",
    ]
  }

  # Ignore failures on reboot
  provisioner "remote-exec" {
    connection {
      host        = self.ipv4_address
      timeout     = "1m"
      private_key = file(var.ssh_private_key_file)
      user        = "core"
    }

    on_failure = continue

    inline = [
      "sudo systemctl reboot"
    ]
  }
}
