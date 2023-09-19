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
data "google_client_config" "default" {}

variable "gke_num_nodes" {
  default     = 2
  description = "number of gke nodes"
}

# GKE cluster
data "google_container_engine_versions" "gke_version" {
  location = "${var.REGION}"
  version_prefix = "1.27."
}

resource "google_service_account" "k8s_service_account" {
  account_id   = "k8s-service-account"
  display_name = "Kubernetes Service Account"
  description  = "Service Account for Kubernetes operations"
}

resource "google_project_iam_member" "k8s_service_account_iam" {
  project = "${var.PROJECT}"
  role    = "roles/container.admin"
  member  = "serviceAccount:${google_service_account.k8s_service_account.email}"
}

resource "google_service_account_key" "k8s_service_account_key" {
  service_account_id = google_service_account.k8s_service_account.name
  key_algorithm      = "KEY_ALG_RSA_2048"
  public_key_type    = "TYPE_X509_PEM_FILE"
}

output "service_account_key" {
  value     = google_service_account_key.k8s_service_account_key.private_key
  sensitive = true
}

resource "google_container_cluster" "primary" {
  name     = "${var.PROJECT}-gke"
  location = "${var.REGION}"

  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name
}

# Separately Managed Node Pool
resource "google_container_node_pool" "primary_nodes" {
  name       = google_container_cluster.primary.name
  location   = "${var.REGION}"
  cluster    = google_container_cluster.primary.name

  version = data.google_container_engine_versions.gke_version.release_channel_latest_version["STABLE"]
  node_count = var.gke_num_nodes

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    labels = {
      env = var.PROJECT
    }

    # preemptible  = true
    machine_type = "n1-standard-1"
    tags         = ["gke-node", "${var.PROJECT}-gke"]
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}

output "decoded_client_key" {
  value = base64decode(google_service_account_key.k8s_service_account_key.private_key)
  sensitive = true
}

provider "kubernetes" {
  host                  = google_container_cluster.primary.endpoint
  client_certificate     = base64decode(google_container_cluster.primary.master_auth[0].client_certificate)
  client_key             = base64decode(google_container_cluster.primary.master_auth[0].client_key)
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
}

resource "kubectl_manifest" "deployment" {
  yaml_body = <<YAML
apiVersion: "apps/v1"
kind: "Deployment"
metadata:
  labels:
    app: "nginx-service"
    version: "1.0.0"
  name: "nginx-service"
spec:
  replicas: ${var.ENVIRONMENT == "DEV" ? 3 : 2}
  selector:
    matchLabels:
      app: "nginx-service"
      version: "1.0.0"
  template:
    metadata:
      labels:
        app: "nginx-service"
        version: "1.0.0"
    spec:
      containers:
        - image: "nginxdemos/hello:latest"
          imagePullPolicy: "Always"
          name: "nginx-service"
          resources:
            limits:
              cpu: 500m
            requests:
              cpu: 200m
          ports:
            - protocol: TCP
              containerPort: 80
YAML
}

resource "kubectl_manifest" "service" {
  yaml_body = <<YAML
apiVersion: "v1"
kind: "Service"
metadata:
  annotations: {}
  labels: {}
  name: "nginx-service"
spec:
  selector:
    app: "nginx-service"
  type: LoadBalancer
  ports:
    - name: http
      port: 80
      targetPort: 80
      protocol: TCP
YAML
}