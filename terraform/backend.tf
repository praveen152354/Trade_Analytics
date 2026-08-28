# Remote state, shared between local applies and CI. Without this, the
# GitHub Actions "terraform apply" job checks out a fresh repo with no state
# file (state is git-ignored, correctly — it can contain sensitive values)
# and tries to recreate everything from scratch, colliding with what
# already exists from local applies ("EntityAlreadyExists", "role already
# exists", etc).
#
# The bucket/table themselves are NOT managed by this Terraform config —
# Terraform can't create the backend it's about to use (chicken-and-egg).
# They're created once by terraform/_bootstrap_state_backend.py. Backend
# blocks also can't reference variables, so these are literal values,
# matching that script.
terraform {
  backend "s3" {
    bucket       = "trade-analytics-tfstate-ae7837e9"
    key          = "trade-analytics/terraform.tfstate"
    region       = "eu-north-1"
    use_lockfile = true # native S3 locking (Terraform >= 1.10) — the DynamoDB table this project also creates is unused with this, kept only as a fallback for older Terraform versions
    encrypt      = true
  }
}
