terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.39.0, < 5.0.0"
    }

    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0, < 3.0.0"
    }

    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0, < 4.0.0"
    }

    time = {
      source  = "hashicorp/time"
      version = ">= 0.12.0, < 1.0.0"
    }

    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0, < 5.0.0"
    }
  }

  backend "azurerm" {
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  subscription_id     = var.subscription_id
  storage_use_azuread = true
}