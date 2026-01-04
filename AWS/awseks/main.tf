provider "aws" {
  region = local.region
}

# Helm provider configuration removed because it referenced module outputs (module.eks.*),
# which creates a circular dependency: provider configuration cannot depend on resources created
# in the same run. Configure the Helm provider separately (for example, in a follow-up apply
# after the EKS cluster is created) or use an external kubeconfig/data sources in a way that
# does not introduce provider-level references to resources created in this same configuration.
#
# Example approaches:
#  - Run a second Terraform apply that configures Helm releases after the cluster is available.
#  - Configure the Helm provider to use a kubeconfig file or an external authentication mechanism
#    that does not reference module outputs.
#
# provider "helm" {
#   kubernetes = {
#     host                   = var.kube_host
#     cluster_ca_certificate = base64decode(var.kube_cluster_ca)
#     exec = {
#       api_version = "client.authentication.k8s.io/v1beta1"
#       command     = "aws"
#       args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
#     }
#   }
# }

data "aws_availability_zones" "available" {
  # Exclude local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ecrpublic_authorization_token" "token" {
  region = "us-east-1"
}

locals {
  name   = "ex-${basename(path.cwd)}"
  region = "eu-west-1"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Example    = local.name
    GithubRepo = "terraform-aws-eks"
    GithubOrg  = "terraform-aws-modules"
  }
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source = "terraform-aws-modules/eks/aws"

  name               = local.name
  kubernetes_version = "1.33"

  # Gives Terraform identity admin access to cluster which will
  # allow deploying resources (Karpenter) into the cluster
  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true

  # EKS Provisioned Control Plane configuration
  control_plane_scaling_config = {
    tier = "standard"
  }

  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  eks_managed_node_groups = {
    karpenter = {
        ami_type       = "AL2023_x86_64_STANDARD"
        instance_types = ["c7i-flex.large"]
  
        min_size     = 1
        max_size     = 2
        desired_size = 1
  
        labels = {
          # Used to ensure Karpenter runs on nodes that it does not manage
          "karpenter.sh/controller" = "true"
        }
      }
  }

  # node_security_group_tags is not a supported argument for this eks module version.
  # To apply tags to security groups created for nodes, tag the resources where they are created
  # (for example in the node group/module that manages nodes) or use the module's supported
  # tagging inputs according to its documentation.
  # node_security_group_tags = merge(local.tags, {
  #   "karpenter.sh/discovery" = local.name
  # })

  # tags is not a supported top-level argument for this eks module version.
  # Tagging should be done via the module inputs that the module exposes for tagging
  # of the resources it creates; check the module's README for the correct inputs.
  # tags = local.tags
}

################################################################################
# Karpenter
################################################################################

module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name = module.eks.cluster_name

  # Name needs to match role name passed to the EC2NodeClass
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = local.name
  create_pod_identity_association = true

  # Used to attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

#module "karpenter_disabled" {
#  source = "../../modules/karpenter"
# The helm_release resource is omitted here because managing Helm releases with the
# Helm provider in the same Terraform run that creates the EKS cluster can create
# provider configuration cycles (the Helm provider often needs cluster connection
# details produced by the EKS module).
#
# Deploy this Helm chart in a separate step after the cluster is created, for example:
#  - Run a separate Terraform apply that configures Helm releases using a provider
#    configured from a kubeconfig that points to the newly created cluster, or
#  - Use an external deployment tool (helm/flux/argocd) once the cluster exists.
#
# Example placeholder for later:
# resource "helm_release" "karpenter" {
#   # configure after cluster exists
# }
 #   settings:
 #     clusterName: ${module.eks.cluster_name}
   #   clusterEndpoint: ${module.eks.cluster_endpoint}
   #   interruptionQueue: ${module.karpenter.queue_name}
#}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}