terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.54.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.6.0"
}

# ─── Connexion OpenBao ────────────────────────────────────────────────────────
provider "vault" {
  address         = var.vault_addr
  token           = var.vault_token
  skip_tls_verify = true
}

# ─── Secrets depuis OpenBao ───────────────────────────────────────────────────
data "vault_kv_secret_v2" "auth" {
  mount = "secret"
  name  = "openstack/auth"
}

data "vault_kv_secret_v2" "network" {
  mount = "secret"
  name  = "openstack/network/common"
}

data "vault_kv_secret_v2" "vm" {
  mount = "secret"
  name  = "vms/traefik"
}

data "vault_kv_secret_v2" "ssh_keys" {
  mount = "secret"
  name  = "ssh-keys/admins"
}

# ─── Provider OpenStack ───────────────────────────────────────────────────────
provider "openstack" {
  user_name        = data.vault_kv_secret_v2.auth.data["OS_USERNAME"]
  password         = data.vault_kv_secret_v2.auth.data["OS_PASSWORD"]
  auth_url         = data.vault_kv_secret_v2.auth.data["OS_AUTH_URL"]
  tenant_id        = data.vault_kv_secret_v2.auth.data["OS_PROJECT_ID"]
  user_domain_name = data.vault_kv_secret_v2.auth.data["user_domain_name"]
  region           = data.vault_kv_secret_v2.auth.data["region"]
}

# ─── Security Group ───────────────────────────────────────────────────────────
resource "openstack_networking_secgroup_v2" "traefik_sg" {
  name        = "sg-traefik"
  description = "Security group pour la VM Traefik reverse proxy"
}

resource "openstack_networking_secgroup_rule_v2" "allow_ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = data.vault_kv_secret_v2.network.data["admin_cidr"]
  security_group_id = openstack_networking_secgroup_v2.traefik_sg.id
}

resource "openstack_networking_secgroup_rule_v2" "allow_http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.traefik_sg.id
}

resource "openstack_networking_secgroup_rule_v2" "allow_https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.traefik_sg.id
}

resource "openstack_networking_secgroup_rule_v2" "allow_dashboard" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8080
  port_range_max    = 8080
  remote_ip_prefix  = data.vault_kv_secret_v2.network.data["admin_cidr"]
  security_group_id = openstack_networking_secgroup_v2.traefik_sg.id
}

# ─── Cloud-init ───────────────────────────────────────────────────────────────
data "template_file" "cloudinit" {
  template = file("${path.module}/cloudinit.tpl")

  vars = {
    sysadmin_public_key     = data.vault_kv_secret_v2.ssh_keys.data["sysadmin_pub_key"]
    devops_aya_public_key   = data.vault_kv_secret_v2.ssh_keys.data["devops_aya_pub_key"]
    ansible_boot_public_key = data.vault_kv_secret_v2.ssh_keys.data["ansible_boot_pub_key"]
    admin_cidr              = data.vault_kv_secret_v2.network.data["admin_cidr"]
  }
}

# ─── Port privé fixe ─────────────────────────────────────────────────────────
resource "openstack_networking_port_v2" "traefik_port" {
  name       = "traefik-port"
  network_id = data.vault_kv_secret_v2.network.data["network_id"]

  fixed_ip {
    subnet_id  = data.vault_kv_secret_v2.vm.data["subnet_id"]
    ip_address = data.vault_kv_secret_v2.vm.data["machine_traefik_private_ip"]
  }

  security_group_ids = [
    openstack_networking_secgroup_v2.traefik_sg.id
  ]
}

# ─── Instance ─────────────────────────────────────────────────────────────────
resource "openstack_compute_instance_v2" "machine_traefik" {
  name        = "traefik"
  image_name  = data.vault_kv_secret_v2.vm.data["vm_image"]
  flavor_name = data.vault_kv_secret_v2.vm.data["vm_flavor"]
  key_pair    = data.vault_kv_secret_v2.vm.data["ssh_key_name"]

  network {
    port = openstack_networking_port_v2.traefik_port.id
  }

  user_data = data.template_file.cloudinit.rendered
}

# ─── Floating IP publique ─────────────────────────────────────────────────────
resource "openstack_networking_floatingip_v2" "traefik_fip" {
  pool    = data.vault_kv_secret_v2.network.data["floating_ip_pool"]
  port_id = openstack_networking_port_v2.traefik_port.id
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
output "traefik_private_ip" {
  value       = openstack_networking_port_v2.traefik_port.all_fixed_ips[0]
  description = "IP privée de la VM Traefik"
}

output "traefik_public_ip" {
  value       = openstack_networking_floatingip_v2.traefik_fip.address
  description = "IP publique (floating IP) de la VM Traefik"
}
