provider "google" {
  project     = "${var.PROJECT}"
  region      = "${var.REGION}"
  zone        = "${var.ZONE}"
}

resource "google_storage_bucket" "bucket-for-state" {
  name        = "${var.PROJECT}"
  location    = "EU"
  uniform_bucket_level_access = true
}

locals {
  settings = {
    DEV  = { target_size =  2 },
    PROD = { target_size =  3 }
  }

  target_size = lookup(local.settings, var.ENVIRONMENT, local.settings["DEV"]).target_size
}

# Shared VPC network
resource "google_compute_network" "lb_network" {
  name                    = "lb-network"
  provider                = google-beta
  project                 = "${var.PROJECT}"
  auto_create_subnetworks = false
}

# Shared VPC network - backend subnet
resource "google_compute_subnetwork" "lb_frontend_and_backend_subnet" {
  name          = "lb-frontend-and-backend-subnet"
  provider      = google-beta
  project       = "${var.PROJECT}"
  region        = "${var.REGION}"
  ip_cidr_range = "10.1.2.0/24"
  role          = "ACTIVE"
  network       = google_compute_network.lb_network.id
}

# Shared VPC network - proxy-only subnet
resource "google_compute_subnetwork" "proxy_only_subnet" {
  name          = "proxy-only-subnet"
  provider      = google-beta
  project       = "${var.PROJECT}"
  region        = "${var.REGION}"
  ip_cidr_range = "10.129.0.0/23"
  role          = "ACTIVE"
  purpose       = "REGIONAL_MANAGED_PROXY"
  network       = google_compute_network.lb_network.id
}

resource "google_compute_firewall" "fw_allow_health_check" {
  name          = "fw-allow-health-check"
  provider      = google-beta
  project       = "${var.PROJECT}"
  direction     = "INGRESS"
  network       = google_compute_network.lb_network.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"] # Google health check IP ranges -\_('_')_/-
  allow {
    protocol = "tcp"
  }
  target_tags = ["load-balanced-backend"]
}


resource "google_compute_firewall" "fw_allow-http" {
  name          = "fw-allow-http"
  provider      = google-beta
  project       = "${var.PROJECT}"
  network       = google_compute_network.lb_network.id
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "icmp"
  }
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  target_tags = ["allow-http"] # tag to be used in the bastion host
}

resource "google_compute_firewall" "fw_allow_proxies" {
  name          = "fw-allow-proxies"
  provider      = google-beta
  project       = "${var.PROJECT}"
  direction     = "INGRESS"
  network       = google_compute_network.lb_network.id
  source_ranges = ["10.129.0.0/23"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }
  target_tags = ["load-balanced-backend"]
}

resource "google_compute_firewall" "fw_allow_ssh" {
  name          = "fw-allow-ssh"
  provider      = google-beta
  project       = "${var.PROJECT}"
  direction     = "INGRESS"
  network       = google_compute_network.lb_network.id
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  target_tags = ["allow-ssh"]
}

# Instance template
resource "google_compute_instance_template" "default" {
  name     = "host-ilb-backend-template"
  provider = google-beta
  project  = "${var.PROJECT}"
  region   = "${var.REGION}"
  machine_type = "e2-small"
  tags         = ["allow-ssh", "load-balanced-backend"]
  network_interface {
    network    = google_compute_network.lb_network.id
    subnetwork = google_compute_subnetwork.lb_frontend_and_backend_subnet.id
    access_config {
    }
  }
  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }
  # install apache2 and serve a simple web page
  metadata = {
    ssh-keys = <<EOT
      josefbocan:ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCuslUXLj/CpahGwdjam+/6c5a9y0povBGtfYE+VpkpnRBBNoBaf6ybryPCqAveddKCRZI6jI5uXyLMRWvx3c+zZ70/HjV+w5UbXAcb5U0D3PyMwcuBOwLfQy8ciYitS+2pPeeqCN0L2C2KE6RxyhGgyGOMRAdhsmQC0OQXfwg9JeVrkTAjQjvkeIBYj0+GL+SJqQlDaTEN87/tkO50juljmod1vXRwc9m28WRgSIEo7nHzHJ+14k+BiE4+n+UkM1Xw9T1vHuAftGHmroiIXrha2X/KhucujkmjCHF8caU6k2+JAjEZBImpJ+CUZhYctxUzF8zqCKu83BvJ4RmiE7oiWVCoYSTKJQHOufJrsoXb65kv9xl0mfQbmQk8FzMCT02HAFJ62LuGoad1vl9NfCaetO+dR3R7rPwf9PhDDSjfFA0YV9VOIBXj0OqocEvygNEFPMlo8i6AOLavAgTdgidOiKfav7BoxtFQsUQypcUqw4qg3Fyq5nZqpn59QIbCK70= josefbocan
     EOT
    startup-script = <<EOF
    #! /bin/bash
    sudo apt-get update
    sudo apt-get install apache2 -y
    sudo a2ensite default-ssl
    sudo a2enmod ssl
    vm_hostname="$(curl -H "Metadata-Flavor:Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/name)"
    sudo echo "Page served from: $vm_hostname" | \
    tee /var/www/html/index.html
    sudo systemctl restart apache2
    EOF
  }
}

# MIG
resource "google_compute_instance_group_manager" "default" {
  name               = "host-ilb-backend-example"
  provider           = google-beta
  project  = "${var.PROJECT}"
  zone   = "${var.ZONE}"
  base_instance_name = "vm"
  target_size        = local.target_size
  version {
    instance_template = google_compute_instance_template.default.id
    name              = "primary"
  }
  named_port {
    name = "http"
    port = 80
  }
}

# health check
resource "google_compute_health_check" "default" {
  name               = "host-ilb-basic-check"
  provider           = google-beta
  project            = "${var.PROJECT}"
  timeout_sec        = 1
  check_interval_sec = 1
  http_health_check {
    port = "80"
  }
}

# backend service
resource "google_compute_region_backend_service" "default" {
  name                  = "host-ilb-backend-service"
  provider              = google-beta
  project               = "${var.PROJECT}"
  region                = "${var.REGION}"
  protocol              = "HTTP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  timeout_sec           = 10
  health_checks         = [google_compute_health_check.default.id]
  backend {
    group           = google_compute_instance_group_manager.default.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# URL map
resource "google_compute_region_url_map" "default" {
  name            = "host-ilb-map"
  provider        = google-beta
  project  = "${var.PROJECT}"
  region   = "${var.REGION}"
  default_service = google_compute_region_backend_service.default.id
}

# HTTP target proxy
resource "google_compute_region_target_http_proxy" "default" {
  name     = "host-ilb-proxy"
  provider = google-beta
  project  = "${var.PROJECT}"
  region   = "${var.REGION}"
  url_map  = google_compute_region_url_map.default.id
}

# Forwarding rule
resource "google_compute_forwarding_rule" "default" {
  name                  = "host-ilb-forwarding-rule"
  provider              = google-beta
  project  = "${var.PROJECT}"
  region   = "${var.REGION}"
  ip_protocol           = "TCP"
  ip_address            = "10.1.2.8"
  port_range            = "80-80"
  load_balancing_scheme = "INTERNAL_MANAGED"
  target                = google_compute_region_target_http_proxy.default.id
  network               = google_compute_network.lb_network.id
  subnetwork            = google_compute_subnetwork.lb_frontend_and_backend_subnet.id
  network_tier          = "PREMIUM"
  depends_on            = [google_compute_subnetwork.lb_frontend_and_backend_subnet]
}

resource "google_compute_instance" "bastion_host" {
  name         = "bastion-host"
  machine_type = "n1-standard-1"
  zone         = "${var.ZONE}"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-10"
    }
  }
  metadata = {
    ssh-keys = <<EOT
      josefbocan:ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCuslUXLj/CpahGwdjam+/6c5a9y0povBGtfYE+VpkpnRBBNoBaf6ybryPCqAveddKCRZI6jI5uXyLMRWvx3c+zZ70/HjV+w5UbXAcb5U0D3PyMwcuBOwLfQy8ciYitS+2pPeeqCN0L2C2KE6RxyhGgyGOMRAdhsmQC0OQXfwg9JeVrkTAjQjvkeIBYj0+GL+SJqQlDaTEN87/tkO50juljmod1vXRwc9m28WRgSIEo7nHzHJ+14k+BiE4+n+UkM1Xw9T1vHuAftGHmroiIXrha2X/KhucujkmjCHF8caU6k2+JAjEZBImpJ+CUZhYctxUzF8zqCKu83BvJ4RmiE7oiWVCoYSTKJQHOufJrsoXb65kv9xl0mfQbmQk8FzMCT02HAFJ62LuGoad1vl9NfCaetO+dR3R7rPwf9PhDDSjfFA0YV9VOIBXj0OqocEvygNEFPMlo8i6AOLavAgTdgidOiKfav7BoxtFQsUQypcUqw4qg3Fyq5nZqpn59QIbCK70= josefbocan
     EOT
  }
  provisioner "file" {
    source      = "proxy.conf"
    destination = "/tmp/proxy.conf"
    connection {
      host        = self.network_interface[0].access_config[0].nat_ip
      type        = "ssh"
      user        = "josefbocan"
      private_key = file("~/.ssh/my_google_cloud_key")
    }
  }
  # http2 -\_('_')_/-
  metadata_startup_script = <<-EOL
    #!/bin/bash
    # Install Apache
    sudo apt update
    sudo apt install -y apache2
    # Enable necessary modules
    sudo a2enmod proxy
    sudo a2enmod proxy_http
    sudo a2enmod http2
    sudo rm /var/www/html/*
    cp /tmp/proxy.conf /etc/apache2/sites-available/reverse-proxy.conf
    sudo rm /etc/apache2/sites-available/000-default.conf
    sudo rm /etc/apache2/sites-available/default-ssl.conf
    sudo rm /etc/apache2/sites-enabled/000-default.conf
    sudo a2ensite reverse-proxy
    sleep 5
    sudo systemctl restart apache2
  EOL

  allow_stopping_for_update = true
  network_interface {
    network    = google_compute_network.lb_network.id
    subnetwork = google_compute_subnetwork.lb_frontend_and_backend_subnet.id
    access_config {
    }
  }
  tags         = ["allow-ssh", "allow-http"]
}
