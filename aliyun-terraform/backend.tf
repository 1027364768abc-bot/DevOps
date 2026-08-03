# Terraform 远端状态：存放在阿里云 OSS，供 CI 每次运行时读取/更新，
# 避免本地 tfstate 漂移。流水线会自动创建该 bucket。
terraform {
  backend "oss" {
    bucket = "devops-tfstate-1612262844714561"
    key    = "terraform.tfstate"
    region = "cn-hangzhou"
  }
}
