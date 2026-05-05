terraform {
  backend "s3" {
    encrypt = true
    # bucket and region passed via -backend-config at init time
  }
}

provider "aws" {
  region = var.aws_region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {}

variable "container_image" {
  description = "Full image URI (registry/name:tag)"
}

variable "app_port" {
  type    = number
  default = 8000
}

variable "replica_count" {
  type    = number
  default = 2
}

variable "node_instance_type" {
  default = "t3.medium"
}

variable "min_nodes" {
  type    = number
  default = 1
}

variable "max_nodes" {
  type    = number
  default = 3
}

variable "health_check_path" {
  default = "/"
}

# ── Optional secrets injected into pod environment ────────────────────────────
variable "database_url"  { type = string; default = ""; sensitive = true }
variable "db_host"       { type = string; default = "" }
variable "db_port"       { type = string; default = "" }
variable "db_name"       { type = string; default = "" }
variable "db_username"   { type = string; default = "" }
variable "db_password"   { type = string; default = ""; sensitive = true }
variable "mongo_uri"     { type = string; default = ""; sensitive = true }
variable "redis_url"     { type = string; default = ""; sensitive = true }
variable "secret_key"    { type = string; default = ""; sensitive = true }
variable "jwt_secret"    { type = string; default = ""; sensitive = true }
variable "spring_datasource_url"  { type = string; default = ""; sensitive = true }
variable "spring_datasource_user" { type = string; default = "" }
variable "spring_datasource_pass" { type = string; default = ""; sensitive = true }
variable "spring_mongodb_uri"     { type = string; default = ""; sensitive = true }

variable "rds_db_name"     { type = string; default = "" }
variable "rds_db_username" { type = string; default = "" }
variable "rds_db_password" { type = string; default = ""; sensitive = true }

locals {
  name_safe = trimsuffix(substr(lower(replace(replace(var.project_name, "_", "-"), " ", "-")), 0, 24), "-")
  ecr_name  = lower(replace(replace(var.project_name, "_", "-"), " ", "-"))
  namespace = local.name_safe

  _rds_db_name = var.rds_db_name != "" ? var.rds_db_name : "${replace(var.project_name, "-", "_")}db"
  _rds_user    = var.rds_db_username != "" ? var.rds_db_username : "appuser"
  _rds_port    = "5432"
  _rds_scheme  = "postgresql+asyncpg"
  _auto_db_url = "${local._rds_scheme}://${local._rds_user}:${var.rds_db_password}@${aws_db_instance.main.address}:${local._rds_port}/${local._rds_db_name}"
  _db_url      = var.database_url != "" ? var.database_url : local._auto_db_url
  _db_host     = aws_db_instance.main.address
  _db_port     = tostring(aws_db_instance.main.port)
  _db_name     = local._rds_db_name
  _db_user     = local._rds_user
  _db_password = var.rds_db_password
  _spring_ds_url  = var.spring_datasource_url
  _spring_ds_user = var.spring_datasource_user
  _spring_ds_pass = var.spring_datasource_pass

  _all_env = {
    PORT                        = tostring(var.app_port)
    APP_ENV                     = "production"
    DATABASE_URL                = local._db_url
    DB_HOST                     = local._db_host
    DB_PORT                     = local._db_port
    DB_NAME                     = local._db_name
    DB_USER                     = local._db_user
    DB_PASSWORD                 = local._db_password
    MONGO_URI                   = var.mongo_uri
    REDIS_URL                   = var.redis_url
    SECRET_KEY                  = var.secret_key
    JWT_SECRET                  = var.jwt_secret
    SPRING_DATASOURCE_URL       = local._spring_ds_url
    SPRING_DATASOURCE_USERNAME  = local._spring_ds_user
    SPRING_DATASOURCE_PASSWORD  = local._spring_ds_pass
    SPRING_DATA_MONGODB_URI     = var.spring_mongodb_uri
  }
  app_env = { for k, v in local._all_env : k => v if v != "" }
}

# ── VPC ────────────────────────────────────────────────────────────────────────
data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_safe}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# ── EKS Cluster ────────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${local.name_safe}-eks"
  cluster_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      name           = "${local.name_safe}-ng"
      instance_types = [var.node_instance_type]
      min_size       = var.min_nodes
      max_size       = var.max_nodes
      desired_size   = var.replica_count

      labels = {
        project = var.project_name
      }
    }
  }

  # Allow cluster creator to manage resources without aws-auth configmap
  enable_cluster_creator_admin_permissions = true
}

# ── ECR ────────────────────────────────────────────────────────────────────────
data "aws_ecr_repository" "app" {
  name = local.ecr_name
}

# ── Kubernetes Namespace ────────────────────────────────────────────────────────
resource "kubernetes_namespace" "app" {
  depends_on = [module.eks]
  metadata {
    name = local.namespace
    labels = {
      project = var.project_name
    }
  }
}

# ── ECR Pull Secret (allows pods to pull from private ECR) ────────────────────
data "aws_caller_identity" "current" {}

resource "kubernetes_secret" "ecr_pull" {
  depends_on = [kubernetes_namespace.app]
  metadata {
    name      = "ecr-pull-secret"
    namespace = local.namespace
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com" = {
          auth = base64encode("AWS:${data.aws_ecr_authorization_token.token.password}")
        }
      }
    })
  }
}

data "aws_ecr_authorization_token" "token" {}

# ── App Secret (env vars) ──────────────────────────────────────────────────────
resource "kubernetes_secret" "app_env" {
  depends_on = [kubernetes_namespace.app]
  metadata {
    name      = "${local.name_safe}-env"
    namespace = local.namespace
  }
  data = local.app_env
}

# ── Deployment ─────────────────────────────────────────────────────────────────
resource "kubernetes_deployment" "app" {
  depends_on = [module.eks, kubernetes_namespace.app]

  metadata {
    name      = local.name_safe
    namespace = local.namespace
    labels    = { app = local.name_safe }
  }

  spec {
    replicas = var.replica_count

    selector {
      match_labels = { app = local.name_safe }
    }

    template {
      metadata {
        labels = { app = local.name_safe }
      }

      spec {
        image_pull_secrets {
          name = kubernetes_secret.ecr_pull.metadata[0].name
        }

        container {
          name  = local.name_safe
          image = var.container_image

          port {
            container_port = var.app_port
          }

          # Inject env vars from Kubernetes secret
          dynamic "env_from" {
            for_each = length(local.app_env) > 0 ? [1] : []
            content {
              secret_ref {
                name = kubernetes_secret.app_env.metadata[0].name
              }
            }
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            http_get {
              path = var.health_check_path
              port = var.app_port
            }
            initial_delay_seconds = 30            period_seconds        = 15
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = var.health_check_path
              port = var.app_port
            }
            initial_delay_seconds = 15            period_seconds        = 10
            failure_threshold     = 3
          }
        }
      }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }
  }
}

# ── Kubernetes Service (ClusterIP) ────────────────────────────────────────────
resource "kubernetes_service" "app" {
  depends_on = [kubernetes_namespace.app]
  metadata {
    name      = local.name_safe
    namespace = local.namespace
  }
  spec {
    selector = { app = local.name_safe }
    port {
      port        = 80
      target_port = var.app_port
    }
    type = "ClusterIP"
  }
}

# ── AWS Load Balancer Controller (installs the ALB Ingress Controller) ────────
resource "helm_release" "aws_lbc" {
  depends_on = [module.eks]
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
}

# ── Ingress (ALB) ──────────────────────────────────────────────────────────────
resource "kubernetes_ingress_v1" "app" {
  depends_on = [helm_release.aws_lbc]
  metadata {
    name      = "${local.name_safe}-ingress"
    namespace = local.namespace
    annotations = {
      "kubernetes.io/ingress.class"                        = "alb"
      "alb.ingress.kubernetes.io/scheme"                   = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"              = "ip"
      "alb.ingress.kubernetes.io/healthcheck-path"         = var.health_check_path
      "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = "30"
      "alb.ingress.kubernetes.io/healthy-threshold-count"  = "2"
      "alb.ingress.kubernetes.io/unhealthy-threshold-count" = "3"
    }
  }
  spec {
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.app.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

# ── RDS (optional managed database) ──────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "${local.name_safe}-rds-subnet"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "rds" {
  name        = "${local.name_safe}-rds-sg"
  description = "Allow EKS pods to reach RDS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "main" {
  identifier             = "${local.name_safe}-db"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = local._rds_db_name
  username               = local._rds_user
  password               = var.rds_db_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = true
  publicly_accessible    = false
  multi_az               = false
}

# ── Outputs ────────────────────────────────────────────────────────────────────
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "alb_hostname" {
  value       = try(kubernetes_ingress_v1.app.status[0].load_balancer[0].ingress[0].hostname, "")
  description = "ALB DNS name — app is live at http://<this value>"
}

output "namespace" {
  value = local.namespace
}

output "ecr_repository_url" {
  value = data.aws_ecr_repository.app.repository_url
}
