terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }

    porkbun = {
      source  = "marcfrederick/porkbun"
      version = "1.3.1"
    }

    random = {
      source  = "hashicorp/random"
      version = "3.8.1"
    }

    local = {
      source  = "hashicorp/local"
      version = "2.5.2"
    }
  }

  required_version = ">= 1.7"
}
