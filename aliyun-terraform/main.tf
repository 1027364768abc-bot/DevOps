terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 1.220.0" # 升级版本要求，完美支持 OIDC 语法
    }
  }
}

provider "alicloud" {
  region = "cn-hangzhou"
}

# --------------------------------------------------------
# 1. 网络与安全组资源
# --------------------------------------------------------
resource "alicloud_vpc" "vpc" {
  vpc_name   = "devops-vpc"
  cidr_block = "172.16.0.0/12"
}

resource "alicloud_vswitch" "vswitch" {
  vpc_id       = alicloud_vpc.vpc.id
  cidr_block   = "172.16.1.0/24"
  zone_id      = "cn-hangzhou-i"
  vswitch_name = "devops-vswitch"
}

resource "alicloud_security_group" "sg" {
  security_group_name = "devops-sg"
  description         = "Security group for DevOps ECS"
  vpc_id              = alicloud_vpc.vpc.id
}

resource "alicloud_security_group_rule" "allow_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 1
  security_group_id = alicloud_security_group.sg.id
  cidr_ip           = "0.0.0.0/0"
}

# --------------------------------------------------------
# 2. ECS 服务器与免密拉取 ACR 的角色
# --------------------------------------------------------
resource "alicloud_ram_role" "ecs_role" {
  role_name = "ECSRoleForACRAuto"
  document  = <<EOF
  {
    "Statement": [
      {
        "Action": "sts:AssumeRole",
        "Effect": "Allow",
        "Principal": {
          "Service": ["ecs.aliyuncs.com"]
        }
      }
    ],
    "Version": "1"
  }
  EOF
  description = "Role for ECS to pull ACR image without password"
}

resource "alicloud_ram_role_policy_attachment" "attach_acr_readonly" {
  role_name   = alicloud_ram_role.ecs_role.role_name
  policy_name = "AliyunContainerRegistryReadOnlyAccess"
  policy_type = "System"
}

resource "alicloud_instance" "ecs" {
  availability_zone          = "cn-hangzhou-i"
  security_groups            = [alicloud_security_group.sg.id]
  instance_type              = "ecs.t6-c1m1.large"
  system_disk_category       = "cloud_essd"
  image_id                   = "ubuntu_22_04_x64_20G_alibase_20230515.vhd"
  instance_name              = "devops-ecs-node"
  vswitch_id                 = alicloud_vswitch.vswitch.id
  internet_max_bandwidth_out = 5

  role_name = alicloud_ram_role.ecs_role.role_name
}








# --------------------------------------------------------
# 4. 输出变量
# --------------------------------------------------------
output "ecs_public_ip" {
  value = alicloud_instance.ecs.public_ip
}

output "ecs_instance_id" {
  value = alicloud_instance.ecs.id
}

