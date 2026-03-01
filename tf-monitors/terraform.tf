terraform {
  required_providers {
    uptimekuma = {
      source  = "breml/uptimekuma"
      version = "~> 0.1"
    }
  }

  required_version = ">= 1.11"

  backend "local" {
    path = "terraform.tfstate"
  }
}
