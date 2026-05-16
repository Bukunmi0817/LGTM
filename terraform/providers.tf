terraform {
  required_version = ">= 1.6.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# No AWS provider needed — the server already exists.
# Terraform connects directly via SSH and configures it.
