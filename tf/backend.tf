# Local state is acceptable for a single-host deployment.
# Ensure terraform.tfstate is gitignored.
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
