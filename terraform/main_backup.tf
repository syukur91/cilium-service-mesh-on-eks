provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

data "aws_availability_zones" "available" {}

locals {
  name   = basename(path.cwd)
  region = "us-west-2"
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  cilium_chart_version = "1.14.7"

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                   = local.name
  cluster_version                = "1.29"
  cluster_endpoint_public_access = true

  # Give the Terraform identity admin access to the cluster
  # which will allow resources to be deployed into the cluster
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns    = {}
  # kube-proxy = {}
    vpc-cni    = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  

  eks_managed_node_groups = {
    initial = {
      instance_types = ["m5.large"]

      min_size     = 1
      max_size     = 5
      desired_size = 2
    }
  }

  tags = local.tags
}

################################################################################
# EKS Blueprints Addons
################################################################################


module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.14"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  enable_aws_load_balancer_controller = true
  
}


################################################################################
# Add the Cilium Helm release
################################################################################

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = local.cilium_chart_version 
  namespace  = "kube-system"
  
  set {
    name  = "hubble.enabled"
    value = "true"
  }

  set {
    name  = "hubble.metrics.enabled"
    value = "{dns,drop,tcp,flow,icmp,http}"
  }

  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }
  
   set {
    name  = "hubble.tls.auto.enabled"
    value = "true"
  }

   set {
    name  = "ingressController.enabled"
    value = "true"
  }
  
     set {
    name  = "ingressController.loadbalancerMode"
    value = "shared"
  }

  set {
    name  = "hubble.ui.enabled"
    value = "true"
  }

  set {
    name  = "hubble.ui.service.type"
    value = "NodePort"
  }

  set {
    name  = "hubble.relay.service.type"
    value = "NodePort"
  }

  set {
    name  = "kubeProxyReplacement"
    value = "strict"
  }

  set {
    name  = "encryption.enabled"
    value = "true"
  }

  set {
    name  = "encryption.type"
    value = "wireguard"
  }

  set {
    name  = "encryption.nodeEncryption"
    value = "true"
  }

  set {
    name  = "routingMode"
    value = "native"
  }

  set {
    name  = "ipv4NativeRoutingCIDR"
    value = "0.0.0.0/0"
  }

  set {
    name  = "bpf.masquerade"
    value = "false"
  }

  set {
    name  = "nodePort.enabled"
    value = "true"
  }

  set {
    name  = "autoDirectNodeRoutes"
    value = "true"
  }

  set {
    name  = "hostLegacyRouting"
    value = "false"
  }

  set {
    name  = "cni.chainingMode"
    value = "aws-cni"
  }

  set {
    name  = "cni.install"
    value = "true"
  }

  set {
    name  = "ingressController.enabled"
    value = "true"
  }

  set {
    name  = "ingressController.loadbalancerMode"
    value = "shared"
  }

  values = [
        yamlencode(
          {
            ingressController = {
              service = {
                annotations = {
                  "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
              }
            }
          }
        }
        )
      ]
    depends_on = [module.eks_blueprints_addons]
  }

################################################################################
# Dependencies 
################################################################################

resource "null_resource" "update_kubeconfig" {
  triggers = {
    cluster_name = module.eks.cluster_name
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
    aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}
    EOT
  }
  depends_on = [module.eks]
}

resource "null_resource" "pre_helm_commands" {
  triggers = {
    cluster_name = module.eks.cluster_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl -n kube-system delete ds kube-proxy
      kubectl -n kube-system delete cm kube-proxy
    EOT
  }
  depends_on = [null_resource.update_kubeconfig]
}


################################################################################
# Supporting Resources
################################################################################


module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}