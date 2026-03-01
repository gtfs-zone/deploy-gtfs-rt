provider "docker" {
  host = var.docker_host
}

provider "porkbun" {
  api_key        = var.porkbun_api_key
  secret_api_key = var.porkbun_secret_api_key
}

provider "random" {}

provider "local" {}
