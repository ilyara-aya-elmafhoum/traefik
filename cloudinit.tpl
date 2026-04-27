#cloud-config
ssh_pwauth: false
disable_root: true

users:
  - name: sysadmin
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${sysadmin_public_key}

  - name: devops-aya
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${devops_aya_public_key}

  - name: ansible-boot
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${ansible_boot_public_key}

package_update: true
package_upgrade: true

packages:
  - unzip
  - git
  - curl
  - wget
  - software-properties-common
  - gnupg2
  - lsb-release
  - python3-pip
  - ufw
  - unattended-upgrades
  - fail2ban
  - needrestart
  - docker.io
  - docker-compose-plugin
  - jq

write_files:
  - path: /etc/fail2ban/jail.local
    permissions: '0644'
    content: |
      [sshd]
      enabled = true
      port    = ssh
      filter  = sshd
      logpath = /var/log/auth.log
      maxretry = 3
      bantime = 600
      findtime = 600

runcmd:
  # ── Sécurisation SSH ──
  - passwd -l root
  - if [ -f /root/.ssh/authorized_keys ]; then shred -u /root/.ssh/authorized_keys; fi

  # ── Docker ──
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker ansible-boot
  - usermod -aG docker devops-aya

  # ── Pare-feu (Traefik reverse proxy) ──
  - ufw --force reset
  - ufw default deny incoming
  - ufw default allow outgoing

  # SSH restreint au CIDR admin
  - ufw allow from ${admin_cidr} to any port 22 proto tcp comment "SSH Admin"

  # HTTP — Let's Encrypt ACME challenge + redirection HTTPS
  - ufw allow 80/tcp comment "HTTP ACME + redirect"

  # HTTPS — Traefik entrypoint principal
  - ufw allow 443/tcp comment "HTTPS Traefik"

  # Dashboard Traefik — restreint au CIDR admin uniquement
  - ufw allow from ${admin_cidr} to any port 8080 proto tcp comment "Traefik Dashboard Admin"

  - ufw --force enable

  # ── Préparation Traefik ──
  - mkdir -p /opt/traefik/dynamic /opt/traefik/acme /var/log/traefik
  - touch /opt/traefik/acme/acme.json
  - chmod 600 /opt/traefik/acme/acme.json
  - chown -R devops-aya:devops-aya /opt/traefik /var/log/traefik

  # ── Mises à jour automatiques ──
  - dpkg-reconfigure -f noninteractive unattended-upgrades
  - systemctl enable unattended-upgrades
  - systemctl restart unattended-upgrades

  # ── Nettoyage ──
  - apt autoremove -y
  - apt clean
  - systemctl enable fail2ban
  - systemctl restart fail2ban
