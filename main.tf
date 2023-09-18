provider "google" {
  project     = "test-1-399414"
  region      = "europe-central2"
  zone        = "europe-central2-a"
}

resource "google_storage_bucket" "bucket-for-state" {
  name        = "test-1-399414"
  location    = "EU"
  uniform_bucket_level_access = true
}

resource "google_compute_network" "nat_network" {
  name                    = "nat-network"
  auto_create_subnetworks = "true"
}

resource "google_compute_instance_template" "mig-template" {
  name_prefix = "mig-template-"
  machine_type = "f1-micro"

  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }
  metadata = {
    ssh-keys = <<EOT
      josefbocan:ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCuslUXLj/CpahGwdjam+/6c5a9y0povBGtfYE+VpkpnRBBNoBaf6ybryPCqAveddKCRZI6jI5uXyLMRWvx3c+zZ70/HjV+w5UbXAcb5U0D3PyMwcuBOwLfQy8ciYitS+2pPeeqCN0L2C2KE6RxyhGgyGOMRAdhsmQC0OQXfwg9JeVrkTAjQjvkeIBYj0+GL+SJqQlDaTEN87/tkO50juljmod1vXRwc9m28WRgSIEo7nHzHJ+14k+BiE4+n+UkM1Xw9T1vHuAftGHmroiIXrha2X/KhucujkmjCHF8caU6k2+JAjEZBImpJ+CUZhYctxUzF8zqCKu83BvJ4RmiE7oiWVCoYSTKJQHOufJrsoXb65kv9xl0mfQbmQk8FzMCT02HAFJ62LuGoad1vl9NfCaetO+dR3R7rPwf9PhDDSjfFA0YV9VOIBXj0OqocEvygNEFPMlo8i6AOLavAgTdgidOiKfav7BoxtFQsUQypcUqw4qg3Fyq5nZqpn59QIbCK70= josefbocan
     EOT
  }
  metadata_startup_script = <<-EOL
    #!/bin/bash
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -
    sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    sudo systemctl start docker
    sudo docker run -d -p 80:80 nginxdemos/hello
  EOL

  network_interface {
    network = "nat-network"
    access_config {
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_router" "nat_router" {
  name    = "my-router"
  region  = "europe-central2"
  network = "nat-network"
}

resource "google_compute_router_nat" "nat_router" {
  name                               = "my-nat-config"
  router                             = google_compute_router.nat_router.name
  region                             = "europe-central2"
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Ensure your MIG instances have egress rules to access the internet
resource "google_compute_firewall" "egress-internet" {
  name    = "allow-egress-internet"
  network = "nat-network"

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow-ssh" {
  name    = "allow-ssh"
  network = "nat-network"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_instance_group_manager" "mig" {
  name = "mig-group"
  base_instance_name = "mig-instance"
  zone = "europe-central2-a"
  target_size = 2
  version {
    instance_template = google_compute_instance_template.mig-template.self_link
  }
  named_port {
    name = "http"
    port = 80
  }
}
