terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      # Sandbox-friendly: allow `terraform destroy` + re-create without name clashes
      purge_soft_delete_on_destroy = true
    }
  }
}

# ---------------------------------------------------------------------------
# Shared
# ---------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

# ACR and Key Vault names must be globally unique
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  # Short name prefix for all resources (2-10 lowercase letters/digits, e.g. your initials)
  prefix = "engfundape"

  location       = "switzerlandnorth"
  location_short = "chn"

  # Optional GitHub repo as "owner/name". If set, GitHub Actions on main can log in
  # as the managed identity via OIDC (no secrets). Leave empty to skip.
  github_repository = "Alepernicolo/engineering-fundamentals"

  # AKS: a single small node is enough for ArgoCD + the demo app
  aks_node_count = 1
  aks_vm_size    = "Standard_D2s_v5"

  name_suffix = "${local.prefix}${random_string.suffix.result}"
  tags = {
    project = "engineering-fundamentals"
    owner   = "APE"
  }
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.prefix}-${local.location_short}"
  location = local.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# Container Registry
# ---------------------------------------------------------------------------

resource "azurerm_container_registry" "main" {
  name                = "acr${local.prefix}${local.location_short}" # alphanumeric only, 5-50 chars
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false # use Entra ID / managed identity instead of admin creds (Part B.2)
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Key Vault
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "main" {
  name                       = "kv-${local.prefix}-${local.location_short}" # 3-24 chars
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = local.tags
}

# Let whoever runs Terraform manage secrets in the vault
resource "azurerm_role_assignment" "kv_admin_current_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---------------------------------------------------------------------------
# User Assigned Managed Identity
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "main" {
  name                = "id-${local.prefix}-${local.location_short}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

# Push images to ACR (GitHub Actions) - also includes pull rights
resource "azurerm_role_assignment" "identity_acr_push" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.main.principal_id
  principal_type       = "ServicePrincipal"
}

# Read secrets from Key Vault
resource "azurerm_role_assignment" "identity_kv_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.main.principal_id
  principal_type       = "ServicePrincipal"
}

# Optional: GitHub Actions OIDC login for workflows running on main
resource "azurerm_federated_identity_credential" "github_main" {
  count = local.github_repository == "" ? 0 : 1

  name                      = "github-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.main.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${local.github_repository}:ref:refs/heads/main"
}

# ---------------------------------------------------------------------------
# AKS Cluster (Part E - ArgoCD)
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${local.prefix}-${local.location_short}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = "aks-${local.prefix}-${local.location_short}"
  sku_tier            = "Free"

  default_node_pool {
    name       = "system"
    node_count = local.aks_node_count
    vm_size    = local.aks_vm_size
  }

  # Use the fixed node pool above instead of Node Auto Provisioning (Karpenter)
  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.main.id]
  }

  # Lets pods use Entra ID workload identity (e.g. with the user assigned identity / Key Vault)
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  tags = local.tags
}

# Allow AKS nodes to pull images from the ACR
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "acr_name" {
  value = azurerm_container_registry.main.name
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}

output "identity_client_id" {
  description = "Use as AZURE_CLIENT_ID in GitHub Actions (azure/login with OIDC)."
  value       = azurerm_user_assigned_identity.main.client_id
}

output "identity_principal_id" {
  value = azurerm_user_assigned_identity.main.principal_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  value = data.azurerm_client_config.current.subscription_id
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "aks_get_credentials" {
  description = "Run this to configure kubectl for the cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name}"
}

output "aks_oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.main.oidc_issuer_url
}
