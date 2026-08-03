# DevOps 一键部署（从创建服务器开始）

本项目 = AI 运维告警分析前端 + 阿里云 DevOps 自动化流水线。

## 一键流程

推送到 `main` 分支后，GitHub Actions 自动执行：

```text
1. OIDC 免密认证阿里云
2. 创建 OSS 状态桶（不存在时）
3. Terraform apply：创建/更新 VPC、安全组、RAM 角色、ECS 服务器
   - 服务器通过 cloud-init 自动安装 Docker + ACR 免密拉取助手
4. 构建前端镜像并推送到 ACR
5. 等待新服务器就绪（实例 Running + Docker 可用）
6. 云助手 RunCommand 自动拉取镜像并启动容器（80 端口）
```

访问地址是流水线日志里的 `ECS_PUBLIC_IP`（即 `http://<公网IP>`）。

## 前置条件：RAM 角色权限

OIDC 角色 `GitHubActionsRole`（已在阿里云 RAM 控制台配置信任 GitHub OIDC）需要以下权限，
流水线才能创建服务器和读写状态：

- **ECS**：`RunInstances` / `CreateInstance` / `DescribeInstances` / `DeleteInstance` / `RunCommand` / `DescribeInvocations` / `DescribeInvocationResults` / 安全组相关
- **VPC**：`CreateVpc` / `CreateVSwitch` / `Describe*`（VPC、交换机、安全组）
- **RAM**：`CreateRole` / `AttachPolicyToRole` / `DetachPolicyFromRole` / `PassRole`（给 ECS 绑定拉取 ACR 的角色）
- **OSS**：`CreateBucket` / `PutObject` / `GetObject` / `ListObjects`（存放 Terraform 状态）
- **ACR**：镜像推送权限（已有）

> 说明：Terraform 状态存放在 OSS 桶 `devops-tfstate-1612262844714561`，流水线首次运行时自动创建。

### ACR 登录凭据（个人版限制）

ACR **个人版不支持 OIDC/STS 临时凭证登录**（官方限制），推镜像必须使用固定密码。
请在 GitHub 仓库 Settings → Secrets and variables → Actions 中配置两个 Secret：

- `ACR_USERNAME`：阿里云账号登录名（控制台 ACR 个人版 → 访问凭证可查看）
- `ACR_PASSWORD`：ACR 固定密码（控制台 ACR 个人版 → 访问凭证 → 设置固定密码）

### 角色信任策略（重要坑点）

角色名实际为 `githubactionsrole`（全小写），其信任策略必须放行 GitHub OIDC 担任该角色。
**GitHub 的 `sub` 声明格式包含账号 ID 和仓库 ID**（形如
`repo:owner@ownerId/repo@repoId:...`），通配符必须放在仓库 ID 之后，否则 AssumeRole 会报
`AuthenticationFail.NoPermission`。当前仓库对应的完整信任策略：

```json
{
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Federated": "acs:ram::1612262844714561:oidc-provider/GitHub"
      },
      "Condition": {
        "StringEquals": {
          "oidc:aud": "sigstore",
          "oidc:iss": "https://token.actions.githubusercontent.com"
        },
        "StringLike": {
          "oidc:sub": "repo:1027364768abc-bot@268580485/DevOps@1321269390:*"
        }
      }
    }
  ],
  "Version": "1"
}
```

## 注意事项

- **首次运行会重建服务器**：本次改造给 ECS 增加了 `user_data`（cloud-init），
  Terraform 检测到该变更会**重建实例并释放旧服务器**，公网 IP 会变化。
  后续推送若无基础设施变更则复用同一台。
- 若需要固定公网 IP，可给 ECS 增加弹性公网 IP（EIP），避免重建后地址变化。
- 前端 `nginx.conf` 里 `/api/` 代理指向已有后端 `114.55.94.221:8082`，不受影响。

## 本地操作（可选）

```bash
cd aliyun-terraform
export ALICLOUD_ACCESS_KEY_ID=xxx
export ALICLOUD_ACCESS_KEY_SECRET=xxx
terraform init
terraform plan     # 预览变更
terraform apply    # 应用
terraform destroy  # 销毁全部资源
```

`ansible/` 目录保留为手工初始化服务器的可选方案，自动流水线已改用 cloud-init，不再依赖 SSH。
