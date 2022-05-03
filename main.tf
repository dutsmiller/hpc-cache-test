provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

data "azurerm_subscription" "current" {}

data "azuread_service_principal" "example" {
  display_name = "HPC Cache Resource Provider"
}

data "http" "my_ip" {
  url = "http://ifconfig.me"
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "num_targets" {
  description = "Number of Storage Containers/HPC Cache targets to create"
  type        = number
  default     = 1

  validation {
    condition = var.num_targets > 0 && var.num_targets < 21
    error_message = "The value of num_targets must be between 1 and 20."
  }
}

variable "owner" {
  description = "email address for tagging"
  type        = string
}

variable "additional_tags" {
  description = "additional tags for resources"
  type        = map(string)
  default     = {}
}

variable "access_ips" {
  description = "Access IPs for storage account management (IP running Terraform is automatically included)."
  type        = list(string)
  default     = []
}

locals {
  tags = merge({
    purpose = "terraform failure testing"
    owner   = var.owner
  }, var.additional_tags)

  storage_plane_ids = toset([for v in range(1, (var.num_targets+1)) : tostring(v)])
}

resource "random_string" "random" {
  length  = 12
  upper   = false
  number  = false
  special = false
}

resource "azurerm_resource_group" "example" {
  name     = "terraform-failure-testing-${random_string.random.result}"
  location = "eastus2"
  tags     = local.tags
}

resource "azurerm_virtual_network" "example" {
  name                = "example-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
}

resource "azurerm_subnet" "example" {
  name                 = "example-subnet"
  resource_group_name  = azurerm_resource_group.example.name
  virtual_network_name = azurerm_virtual_network.example.name
  address_prefixes     = ["10.0.1.0/24"]

  service_endpoints = ["Microsoft.Storage"]
}

resource "azurerm_storage_account" "example" {
  for_each = local.storage_plane_ids

  name                = "${random_string.random.result}${each.value}"
  resource_group_name = azurerm_resource_group.example.name
  location            = azurerm_resource_group.example.location
  tags                = local.tags

  access_tier              = "Hot"
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  is_hns_enabled           = true
  min_tls_version          = "TLS1_2"

  nfsv3_enabled             = true
  enable_https_traffic_only = true
  account_replication_type  = "LRS"

  network_rules {
    default_action             = "Deny"
    ip_rules                   = concat([data.http.my_ip.body], var.access_ips)
    virtual_network_subnet_ids = [azurerm_subnet.example.id]
    bypass                     = ["AzureServices"]
  }
}


resource "azurerm_storage_container" "example" {
  for_each = local.storage_plane_ids

  depends_on = [
    azurerm_storage_account.example
  ]

  name                  = "example"
  storage_account_name  = azurerm_storage_account.example[each.value].name
  container_access_type = "private"
}

resource "azurerm_role_assignment" "example_storage_account_contrib" {
  for_each = local.storage_plane_ids

  depends_on = [
    azurerm_storage_account.example
  ]

  scope                = azurerm_storage_account.example[each.value].id
  role_definition_name = "Storage Account Contributor"
  principal_id         = data.azuread_service_principal.example.object_id
}

resource "azurerm_role_assignment" "example_storage_blob_data_contrib" {
  for_each = local.storage_plane_ids

  depends_on = [
    azurerm_storage_account.example
  ]

  scope                = azurerm_storage_account.example[each.value].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azuread_service_principal.example.object_id
}

resource "azurerm_hpc_cache" "example" {
  depends_on = [
    azurerm_role_assignment.example_storage_account_contrib,
    azurerm_role_assignment.example_storage_blob_data_contrib
  ]

  name                = random_string.random.result
  resource_group_name = azurerm_resource_group.example.name
  location            = azurerm_resource_group.example.location
  cache_size_in_gb    = 21623
  subnet_id           = azurerm_subnet.example.id
  sku_name            = "Standard_L4_5G"
}

resource "azurerm_hpc_cache_blob_nfs_target" "example" {
  for_each = local.storage_plane_ids

  depends_on = [
    azurerm_hpc_cache.example,
    azurerm_storage_container.example
  ]

  name                 = "example-hpc-target-${each.value}"
  resource_group_name  = azurerm_resource_group.example.name
  cache_name           = azurerm_hpc_cache.example.name
  storage_container_id = azurerm_storage_container.example[each.value].resource_manager_id
  namespace_path       = "/p-${each.value}"
  usage_model          = "READ_HEAVY_INFREQ"
}