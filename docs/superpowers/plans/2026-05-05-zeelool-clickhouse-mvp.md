# Zeelool ClickHouse MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **⚠ 运维红线 / OPERATOR GOTCHAS（读一遍再动手）**
>
> 1. **EBS `ModifyVolume` 有 6 小时 AWS 级冷却期**（每个 volume 的每个属性独立计时）。如果 size / IOPS / throughput 要一起调，**务必在同一次 `terraform apply` 里全部提交**——分两次改之间要干等 6 小时。详见附录 C。
> 2. **`default` 用户不得用空密码**。部署流程要求先往 SSM Parameter Store `/<name_prefix>/default-user-password` 写入 SecureString，再跑 `scripts/render-and-push-ck-config.sh`。不做这一步 = 整个 VPC 对数据裸奔。详见 Task 16。
> 3. **`aws_ebs_volume.data` 默认 `prevent_destroy = true`**。`terraform destroy` 会在这里失败是正常的——走 `scripts/teardown.sh`，它会引导你完成"确认 → 清空 bucket → 临时摘锁 → destroy → 恢复锁"的完整流程。
> 4. **此 plan 针对 Keith 环境首次部署编写**（`ap-northeast-1` / 既有 VPC）。交付给其他环境时请先阅读 `docs/CUSTOMER-ONBOARDING.md`，只改 `terraform/envs/prod/terraform.tfvars` 即可换 region / VPC / 子网 / 机型，不用改模块代码。

**Goal:** 在 AWS 东京区域（ap-northeast-1）基于 Graviton 8g 部署一套跨 2 AZ 高可用的 ClickHouse 存算一体集群（1 shard × 2 replica + 3 Keeper 跨 3 AZ），覆盖 spec v0.3 的 Phase 0-4 + Phase 6，为后续的表结构（Phase 5）与监控（Phase 7）打好底座。

**Architecture:** Terraform 管所有 AWS 资源（复用已有 VPC / 子网 / NAT，自建 SG / IAM / EC2 / EBS / NLB / Route53 / S3 / SSM Documents）。EC2 启动时 cloud-init 仅做最小化 bootstrap（格式化挂载数据盘、设置 hostname、确保 SSM Agent 运行）；CK 和 Keeper 的安装、配置渲染、系统服务启动全部走 **SSM State Manager Associations** 调度 **SSM Documents** 完成。CK 采用 `ReplicatedMergeTree` 引擎 + Keeper 作为 coordination 层；写入入口 + 客户端访问走 internal NLB 跨 AZ。每日 02:00 JST 通过 EventBridge 触发 SSM Document 对 ck-01 执行 `BACKUP TO S3` 命令落备份。

**Tech Stack:**
- Terraform 1.8+（AWS Provider ~> 5.0）
- ClickHouse 25.3 LTS（官方 RPM，ARM64）
- ClickHouse Keeper 25.3（独立二进制，非嵌入式）
- Amazon Linux 2023 ARM64（AMI id 通过 SSM Parameter 动态解析）
- EC2：`r8g.xlarge`（CK）× 2；`t4g.small`（Keeper）× 3
- EBS：gp3，静态私网 IP
- Network Load Balancer（internal，跨 3 AZ）+ Route53 Private Hosted Zone
- S3 + KMS（AWS 托管密钥）+ EventBridge（备份调度）
- AWS Profile：`default` / Region：`ap-northeast-1` / VPC：`vpc-XXXXXXXXXXXXXXXXX`

**Out of scope（明确延后，不在本 plan）：**
- Phase 5：数据模型与 DDL（占位 SSM Document `bootstrap-schema` 会建出来，但内部 SQL 留 TODO）
- Phase 7：监控告警（AMP / AMG / Runbook）
- dev 环境
- 跨 Region 灾备

---

## File Structure

```
2026-project/zeelool-clickhouse/
├── README.md                             # Task 1 创建
├── .gitignore                            # Task 1 创建
├── terraform/
│   ├── backend.tf                        # Task 2: S3 state backend
│   ├── envs/prod/
│   │   ├── provider.tf                   # Task 2
│   │   ├── variables.tf                  # Task 2
│   │   ├── terraform.tfvars              # Task 2
│   │   ├── main.tf                       # Task 4/7/11/14/17/19 渐进增补
│   │   └── outputs.tf                    # Task 4/11/14/17/19
│   └── modules/
│       ├── network/                      # Task 3：SG + S3 Gateway Endpoint
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── iam/                          # Task 4：EC2 Instance Profile
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── ssm-documents/                # Task 7：SSM Documents
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── keeper-node/                  # Task 11：Keeper EC2 + EBS
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   ├── outputs.tf
│       │   └── user_data.sh.tftpl
│       ├── clickhouse-node/              # Task 14：CK EC2 + EBS + 数据盘
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   ├── outputs.tf
│       │   └── user_data.sh.tftpl
│       ├── nlb/                          # Task 17：NLB + TG + R53
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       └── backup-s3/                    # Task 19：S3 bucket + KMS + lifecycle + EventBridge
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
├── ssm-documents/                        # SSM Documents（被 modules/ssm-documents 引用）
│   ├── install-keeper.yml                # Task 6
│   ├── render-keeper-config.yml          # Task 6
│   ├── install-clickhouse.yml            # Task 8
│   ├── render-clickhouse-config.yml      # Task 8
│   ├── bootstrap-schema.yml              # Task 8（占位）
│   └── run-backup.yml                    # Task 18
├── config/
│   ├── clickhouse/
│   │   ├── config.d/
│   │   │   ├── remote-servers.xml.tftpl  # Task 13
│   │   │   ├── zookeeper.xml.tftpl       # Task 13
│   │   │   ├── macros.xml.tftpl          # Task 13
│   │   │   └── logger.xml                # Task 13
│   │   └── users.d/
│   │       └── default-user.xml.tftpl    # Task 13
│   └── keeper/
│       └── keeper_config.xml.tftpl       # Task 5
└── docs/
    ├── superpowers/                      # 已存在
    └── runbooks/                         # Phase 7 占位
```

**设计决策**：
- SSM Documents 用 YAML 而非 JSON（可读性 > 紧凑性）。
- 配置文件用 Terraform templatefile（`.tftpl` 后缀）直接渲染，再通过 SSM Document 的 `aws:downloadContent` 或参数传递下发。
- 模块粒度按「一个 AWS 资源组」切分，不按技术层切。
- 目录 `config/` 仅存模板；任何"最终渲染后的配置"都由 SSM Document 在节点上生成。

---

## 前置条件（开工前手动完成）

在开始 Task 1 之前确保：

- 已登录 AWS profile `default`，region `ap-northeast-1`：
  ```bash
  aws --profile default --region ap-northeast-1 sts get-caller-identity
  ```
- 已安装 Terraform 1.8+：`terraform version`
- 已登录 GitHub / Git，SSH key 或 HTTPS token 可用
- VPC `vpc-XXXXXXXXXXXXXXXXX` 及 3 个 private 子网仍然存在：
  ```bash
  aws --profile default --region ap-northeast-1 ec2 describe-vpcs --vpc-ids vpc-XXXXXXXXXXXXXXXXX --query 'Vpcs[0].State' --output text
  ```
  预期输出：`available`

---

## Task 1：项目骨架与 Git 初始化

**Files:**
- Create: `2026-project/zeelool-clickhouse/README.md`
- Create: `2026-project/zeelool-clickhouse/.gitignore`

- [ ] **Step 1：进入项目目录**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse
pwd
```

Expected: `/root/keith-space/2026-project/zeelool-clickhouse`

- [ ] **Step 2：创建 README.md**

内容：

```markdown
# Zeelool ClickHouse Cluster

高可用 ClickHouse 集群（1 shard × 2 replica + 3 Keeper 跨 3 AZ），部署于 AWS ap-northeast-1，基于 Graviton 8g。

**设计文档：** [docs/superpowers/specs/2026-05-04-zeelool-clickhouse-design.md](docs/superpowers/specs/2026-05-04-zeelool-clickhouse-design.md)

**实施计划：** [docs/superpowers/plans/2026-05-05-zeelool-clickhouse-mvp.md](docs/superpowers/plans/2026-05-05-zeelool-clickhouse-mvp.md)

## Quick start

```bash
cd terraform/envs/prod
terraform init
terraform plan
terraform apply
```

## 目录

- `terraform/` — 基础设施即代码
- `ssm-documents/` — SSM Document 定义
- `config/` — ClickHouse / Keeper 配置模板
- `docs/` — 设计文档与 runbook
```

- [ ] **Step 3：创建 .gitignore**

```gitignore
# Terraform
**/.terraform/*
*.tfstate
*.tfstate.*
*.tfvars.local
.terraform.lock.hcl

# Secrets
*.pem
*.key
credentials

# IDE
.vscode/
.idea/

# OS
.DS_Store
Thumbs.db
```

- [ ] **Step 4：验证文件就位**

```bash
ls -la
```

Expected: 能看到 `README.md`、`.gitignore`、`docs/`。

- [ ] **Step 5：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/README.md \
        2026-project/zeelool-clickhouse/.gitignore \
        2026-project/zeelool-clickhouse/docs/
git commit -m "feat(zeelool-ck): scaffold project structure and docs"
```

---

## Task 2：Terraform Backend 与 Provider 骨架

**Files:**
- Create: `terraform/backend.tf`
- Create: `terraform/envs/prod/provider.tf`
- Create: `terraform/envs/prod/variables.tf`
- Create: `terraform/envs/prod/terraform.tfvars`
- Create: `terraform/envs/prod/main.tf`（空占位）
- Create: `terraform/envs/prod/outputs.tf`（空占位）

- [ ] **Step 1：手动创建 S3 backend bucket（一次性 bootstrap）**

```bash
aws --profile default --region ap-northeast-1 s3api create-bucket \
  --bucket zeelool-ck-tfstate-apne1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1

aws --profile default --region ap-northeast-1 s3api put-bucket-versioning \
  --bucket zeelool-ck-tfstate-apne1 \
  --versioning-configuration Status=Enabled

aws --profile default --region ap-northeast-1 s3api put-bucket-encryption \
  --bucket zeelool-ck-tfstate-apne1 \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws --profile default --region ap-northeast-1 s3api put-public-access-block \
  --bucket zeelool-ck-tfstate-apne1 \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Expected：4 条命令都 200 OK，无错误输出。

- [ ] **Step 2：创建 DynamoDB lock 表**

```bash
aws --profile default --region ap-northeast-1 dynamodb create-table \
  --table-name zeelool-ck-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

aws --profile default --region ap-northeast-1 dynamodb wait table-exists \
  --table-name zeelool-ck-tflock
```

Expected：第二条命令完成后退出码 0。

- [ ] **Step 3：写 `terraform/backend.tf`**

```hcl
terraform {
  required_version = ">= 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}
```

- [ ] **Step 4：写 `terraform/envs/prod/provider.tf`**

```hcl
terraform {
  backend "s3" {
    bucket         = "zeelool-ck-tfstate-apne1"
    key            = "envs/prod/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "zeelool-ck-tflock"
    encrypt        = true
    profile        = "default"
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = {
      Project     = "zeelool-clickhouse"
      Environment = "prod"
      ManagedBy   = "terraform"
      Owner       = "keith"
    }
  }
}
```

- [ ] **Step 5：写 `terraform/envs/prod/variables.tf`**

```hcl
variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "profile" {
  type    = string
  default = "default"
}

variable "vpc_id" {
  type        = string
  description = "Existing VPC to deploy into"
}

variable "private_subnet_ids" {
  type        = map(string)
  description = "Map of AZ -> private subnet ID (az1a, az1c, az1d)"
}

variable "private_hosted_zone_name" {
  type        = string
  default     = "internal.zeelool"
  description = "Route53 private hosted zone name (will be created if missing)"
}

variable "cluster_name" {
  type    = string
  default = "zeelool_ck"
}

# Static private IPs — simplifies cross-node config rendering
variable "keeper_private_ips" {
  type    = map(string)
  default = {
    "az1a" = "10.0.11.100"
    "az1c" = "10.0.12.100"
    "az1d" = "10.0.13.100"
  }
}

variable "clickhouse_private_ips" {
  type    = map(string)
  default = {
    "az1a" = "10.0.11.200"
    "az1c" = "10.0.12.200"
  }
}
```

- [ ] **Step 6：写 `terraform/envs/prod/terraform.tfvars`**

```hcl
vpc_id = "vpc-XXXXXXXXXXXXXXXXX"

private_subnet_ids = {
  "az1a" = "subnet-XXXXXXXXXXXXXXXXX"
  "az1c" = "subnet-YYYYYYYYYYYYYYYYY"
  "az1d" = "subnet-ZZZZZZZZZZZZZZZZZ"
}
```

- [ ] **Step 7：创建空占位 `main.tf` 和 `outputs.tf`**

`terraform/envs/prod/main.tf`:

```hcl
# Terraform composition - modules will be wired in subsequent tasks.
```

`terraform/envs/prod/outputs.tf`:

```hcl
# Outputs - populated in subsequent tasks.
```

- [ ] **Step 8：terraform init & validate**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform init
terraform validate
```

Expected：`Terraform has been successfully initialized!` 以及 `Success! The configuration is valid.`

- [ ] **Step 9：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/terraform/
git commit -m "feat(zeelool-ck): terraform backend + provider scaffolding"
```

---

## Task 3：network 模块（Security Groups + S3 Gateway Endpoint）

**Files:**
- Create: `terraform/modules/network/main.tf`
- Create: `terraform/modules/network/variables.tf`
- Create: `terraform/modules/network/outputs.tf`

- [ ] **Step 1：写 `modules/network/variables.tf`**

```hcl
variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR for intra-VPC SG rules"
  default     = "10.0.0.0/16"
}

variable "private_route_table_ids" {
  type        = list(string)
  description = "Private route table IDs to associate with S3 gateway endpoint"
}
```

- [ ] **Step 2：写 `modules/network/main.tf`**

```hcl
# Security group shared by CK nodes, Keeper nodes, and NLB.
resource "aws_security_group" "clickhouse" {
  name        = "zeelool-ck-clickhouse"
  description = "ClickHouse data nodes"
  vpc_id      = var.vpc_id

  ingress {
    description = "CK native TCP"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "CK HTTP"
    from_port   = 8123
    to_port     = 8123
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "CK interserver replication"
    from_port   = 9009
    to_port     = 9009
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all egress (SSM, S3, Keeper, peers)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "zeelool-ck-clickhouse" }
}

resource "aws_security_group" "keeper" {
  name        = "zeelool-ck-keeper"
  description = "ClickHouse Keeper nodes"
  vpc_id      = var.vpc_id

  ingress {
    description = "Keeper client port"
    from_port   = 9181
    to_port     = 9181
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Keeper raft peer"
    from_port   = 9234
    to_port     = 9234
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all egress (SSM, peers)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "zeelool-ck-keeper" }
}

resource "aws_security_group" "nlb" {
  name        = "zeelool-ck-nlb"
  description = "Internal NLB for ClickHouse"
  vpc_id      = var.vpc_id

  ingress {
    description = "CK native TCP via NLB"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "CK HTTP via NLB"
    from_port   = 8123
    to_port     = 8123
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "zeelool-ck-nlb" }
}

# S3 Gateway Endpoint — free, keeps backup traffic off NAT Gateway.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.ap-northeast-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids

  tags = { Name = "zeelool-ck-s3-gw" }
}
```

- [ ] **Step 3：写 `modules/network/outputs.tf`**

```hcl
output "clickhouse_sg_id" {
  value = aws_security_group.clickhouse.id
}

output "keeper_sg_id" {
  value = aws_security_group.keeper.id
}

output "nlb_sg_id" {
  value = aws_security_group.nlb.id
}

output "s3_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
```

- [ ] **Step 4：terraform validate**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform validate
```

Expected：`Success!`

- [ ] **Step 5：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/terraform/modules/network/
git commit -m "feat(zeelool-ck): network module with SGs and S3 gateway endpoint"
```

---

## Task 4：iam 模块 + 在 prod 环境装配 network & iam，首次 apply

**Files:**
- Create: `terraform/modules/iam/main.tf`
- Create: `terraform/modules/iam/variables.tf`
- Create: `terraform/modules/iam/outputs.tf`
- Modify: `terraform/envs/prod/main.tf`
- Modify: `terraform/envs/prod/outputs.tf`

- [ ] **Step 1：写 `modules/iam/variables.tf`**

```hcl
variable "backup_bucket_arn" {
  type        = string
  description = "Backup bucket ARN for S3 PutObject/GetObject (may be empty before Task 18)"
  default     = ""
}
```

- [ ] **Step 2：写 `modules/iam/main.tf`**

```hcl
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ck_node" {
  name               = "zeelool-ck-node-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.ck_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "backup" {
  count = var.backup_bucket_arn == "" ? 0 : 1

  statement {
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",           # BACKUP writes + deletes a .lock sentinel
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:AbortMultipartUpload",
      "s3:ListBucketMultipartUploads"
    ]
    resources = [
      var.backup_bucket_arn,
      "${var.backup_bucket_arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "backup" {
  count  = var.backup_bucket_arn == "" ? 0 : 1
  name   = "zeelool-ck-backup"
  role   = aws_iam_role.ck_node.id
  policy = data.aws_iam_policy_document.backup[0].json
}

resource "aws_iam_instance_profile" "ck_node" {
  name = "zeelool-ck-node"
  role = aws_iam_role.ck_node.name
}
```

- [ ] **Step 3：写 `modules/iam/outputs.tf`**

```hcl
output "instance_profile_name" {
  value = aws_iam_instance_profile.ck_node.name
}

output "instance_profile_arn" {
  value = aws_iam_instance_profile.ck_node.arn
}

output "role_name" {
  value = aws_iam_role.ck_node.name
}

output "role_arn" {
  value = aws_iam_role.ck_node.arn
}
```

- [ ] **Step 4：装配 `envs/prod/main.tf` — 引入 network 与 iam**

```hcl
# Data: look up private route tables for S3 Gateway Endpoint association.
data "aws_route_tables" "private" {
  vpc_id = var.vpc_id

  filter {
    name   = "tag:Name"
    values = ["keithyu-tokyo-rtb-private*"]
  }
}

module "network" {
  source = "../../modules/network"

  vpc_id                  = var.vpc_id
  private_route_table_ids = data.aws_route_tables.private.ids
}

module "iam" {
  source = "../../modules/iam"

  # backup_bucket_arn stays empty until Task 18 wires it.
}
```

- [ ] **Step 5：`envs/prod/outputs.tf`**

```hcl
output "clickhouse_sg_id" {
  value = module.network.clickhouse_sg_id
}

output "keeper_sg_id" {
  value = module.network.keeper_sg_id
}

output "nlb_sg_id" {
  value = module.network.nlb_sg_id
}

output "s3_endpoint_id" {
  value = module.network.s3_endpoint_id
}

output "instance_profile_name" {
  value = module.iam.instance_profile_name
}
```

- [ ] **Step 6：terraform plan 并 review**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform init -upgrade
terraform plan -out=tfplan
```

Expected：`Plan: 7 to add, 0 to change, 0 to destroy.`（3 SG + 1 endpoint + 1 role + 1 policy attach + 1 instance profile）

- [ ] **Step 7：terraform apply**

```bash
terraform apply tfplan
```

Expected：`Apply complete! Resources: 7 added, 0 changed, 0 destroyed.`

- [ ] **Step 8：verify 资源创建成功**

```bash
aws --profile default --region ap-northeast-1 ec2 describe-security-groups \
  --filters "Name=tag:Project,Values=zeelool-clickhouse" \
  --query 'SecurityGroups[].GroupName' --output text
```

Expected 输出：`zeelool-ck-clickhouse zeelool-ck-keeper zeelool-ck-nlb`（顺序可能不同）

```bash
aws --profile default --region ap-northeast-1 iam get-instance-profile \
  --instance-profile-name zeelool-ck-node \
  --query 'InstanceProfile.InstanceProfileName' --output text
```

Expected：`zeelool-ck-node`

- [ ] **Step 9：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/terraform/
git commit -m "feat(zeelool-ck): iam module + apply network & iam (Phase 0 done)"
```

---

## Task 5：Keeper 配置模板（`keeper_config.xml.tftpl`）

**Files:**
- Create: `config/keeper/keeper_config.xml.tftpl`

- [ ] **Step 1：写 `config/keeper/keeper_config.xml.tftpl`**

```xml
<clickhouse>
    <logger>
        <level>information</level>
        <log>/var/log/clickhouse-keeper/clickhouse-keeper.log</log>
        <errorlog>/var/log/clickhouse-keeper/clickhouse-keeper.err.log</errorlog>
        <size>100M</size>
        <count>10</count>
    </logger>

    <listen_host>0.0.0.0</listen_host>
    <max_connections>4096</max_connections>

    <keeper_server>
        <server_id>${server_id}</server_id>
        <tcp_port>9181</tcp_port>
        <log_storage_path>/var/lib/clickhouse-keeper/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse-keeper/coordination/snapshots</snapshot_storage_path>

        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>information</raft_logs_level>
            <snapshot_distance>10000</snapshot_distance>
            <reserved_log_items>1000</reserved_log_items>
            <auto_forwarding>true</auto_forwarding>
        </coordination_settings>

        <raft_configuration>
%{ for peer in peers ~}
            <server>
                <id>${peer.id}</id>
                <hostname>${peer.ip}</hostname>
                <port>9234</port>
            </server>
%{ endfor ~}
        </raft_configuration>
    </keeper_server>
</clickhouse>
```

- [ ] **Step 2：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/config/keeper/keeper_config.xml.tftpl
git commit -m "feat(zeelool-ck): keeper config template"
```

---

## Task 6：Keeper 相关 SSM Documents

**Files:**
- Create: `ssm-documents/install-keeper.yml`
- Create: `ssm-documents/render-keeper-config.yml`

- [ ] **Step 1：写 `ssm-documents/install-keeper.yml`**

```yaml
schemaVersion: "2.2"
description: "Install ClickHouse Keeper 25.3 on Amazon Linux 2023 ARM64"
parameters:
  KeeperVersion:
    type: String
    default: "25.3.2.39"
    description: "ClickHouse Keeper package version"
mainSteps:
  - name: installKeeper
    action: aws:runShellScript
    inputs:
      runCommand:
        - "set -euxo pipefail"
        - 'if rpm -q clickhouse-keeper >/dev/null 2>&1; then echo "already installed"; exit 0; fi'
        - "dnf install -y yum-utils"
        - "dnf config-manager --add-repo https://packages.clickhouse.com/rpm/clickhouse.repo"
        - "dnf install -y --enablerepo=clickhouse-lts clickhouse-keeper-{{ KeeperVersion }}"
        - "systemctl daemon-reload"
        - "systemctl enable clickhouse-keeper"
```

- [ ] **Step 2：写 `ssm-documents/render-keeper-config.yml`**

```yaml
schemaVersion: "2.2"
description: "Render /etc/clickhouse-keeper/keeper_config.xml and restart service"
parameters:
  ConfigXml:
    type: String
    description: "Full content of keeper_config.xml (base64-encoded)"
mainSteps:
  - name: writeConfig
    action: aws:runShellScript
    inputs:
      runCommand:
        - "set -euxo pipefail"
        - "mkdir -p /etc/clickhouse-keeper"
        - "mkdir -p /var/lib/clickhouse-keeper/coordination/log"
        - "mkdir -p /var/lib/clickhouse-keeper/coordination/snapshots"
        - "mkdir -p /var/log/clickhouse-keeper"
        - "echo '{{ ConfigXml }}' | base64 -d > /etc/clickhouse-keeper/keeper_config.xml"
        - "chown -R clickhouse:clickhouse /etc/clickhouse-keeper /var/lib/clickhouse-keeper /var/log/clickhouse-keeper"
        - "systemctl restart clickhouse-keeper"
        - "sleep 3"
        - "systemctl is-active clickhouse-keeper"
```

- [ ] **Step 3：YAML 语法快速检查**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse
python3 -c "import yaml; yaml.safe_load(open('ssm-documents/install-keeper.yml')); yaml.safe_load(open('ssm-documents/render-keeper-config.yml')); print('ok')"
```

Expected：`ok`

- [ ] **Step 4：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/ssm-documents/install-keeper.yml \
        2026-project/zeelool-clickhouse/ssm-documents/render-keeper-config.yml
git commit -m "feat(zeelool-ck): keeper install/render-config SSM Documents"
```

---

## Task 7：ssm-documents 模块 + 注册 Keeper Documents

**Files:**
- Create: `terraform/modules/ssm-documents/main.tf`
- Create: `terraform/modules/ssm-documents/variables.tf`
- Create: `terraform/modules/ssm-documents/outputs.tf`
- Modify: `terraform/envs/prod/main.tf`

- [ ] **Step 1：写 `modules/ssm-documents/variables.tf`**

```hcl
variable "document_dir" {
  type        = string
  description = "Path to ssm-documents/ directory relative to this module"
  default     = "../../../ssm-documents"
}

variable "name_prefix" {
  type    = string
  default = "zeelool-ck"
}
```

- [ ] **Step 2：写 `modules/ssm-documents/main.tf`**

```hcl
# Keeper documents
resource "aws_ssm_document" "install_keeper" {
  name            = "${var.name_prefix}-install-keeper"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/install-keeper.yml")

  tags = { Name = "${var.name_prefix}-install-keeper" }
}

resource "aws_ssm_document" "render_keeper_config" {
  name            = "${var.name_prefix}-render-keeper-config"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/render-keeper-config.yml")

  tags = { Name = "${var.name_prefix}-render-keeper-config" }
}
```

- [ ] **Step 3：写 `modules/ssm-documents/outputs.tf`**

```hcl
output "install_keeper_doc_name" {
  value = aws_ssm_document.install_keeper.name
}

output "render_keeper_config_doc_name" {
  value = aws_ssm_document.render_keeper_config.name
}
```

- [ ] **Step 4：在 `envs/prod/main.tf` 追加 module 调用**

追加到文件末尾：

```hcl
module "ssm_documents" {
  source = "../../modules/ssm-documents"
}
```

- [ ] **Step 5：terraform plan & apply**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform plan -out=tfplan
terraform apply tfplan
```

Expected：`Plan: 2 to add`；`Apply complete! Resources: 2 added`

- [ ] **Step 6：verify SSM Document 注册成功**

```bash
aws --profile default --region ap-northeast-1 ssm list-documents \
  --filters "Key=Name,Values=zeelool-ck" \
  --query 'DocumentIdentifiers[].Name' --output text
```

Expected 输出包含：`zeelool-ck-install-keeper` 和 `zeelool-ck-render-keeper-config`。

- [ ] **Step 7：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/terraform/
git commit -m "feat(zeelool-ck): ssm-documents module with keeper documents registered"
```

---

## Task 8：ClickHouse 相关 SSM Documents（含 schema 占位）

**Files:**
- Create: `ssm-documents/install-clickhouse.yml`
- Create: `ssm-documents/render-clickhouse-config.yml`
- Create: `ssm-documents/bootstrap-schema.yml`
- Modify: `terraform/modules/ssm-documents/main.tf`
- Modify: `terraform/modules/ssm-documents/outputs.tf`

- [ ] **Step 1：写 `ssm-documents/install-clickhouse.yml`**

```yaml
schemaVersion: "2.2"
description: "Install ClickHouse Server 25.3 on Amazon Linux 2023 ARM64"
parameters:
  ClickHouseVersion:
    type: String
    default: "25.3.2.39"
mainSteps:
  - name: installClickHouse
    action: aws:runShellScript
    inputs:
      runCommand:
        - "set -euxo pipefail"
        - 'if rpm -q clickhouse-server >/dev/null 2>&1; then echo "already installed"; exit 0; fi'
        - "dnf install -y yum-utils"
        - "dnf config-manager --add-repo https://packages.clickhouse.com/rpm/clickhouse.repo"
        - "dnf install -y --enablerepo=clickhouse-lts clickhouse-server-{{ ClickHouseVersion }} clickhouse-client-{{ ClickHouseVersion }} clickhouse-common-static-{{ ClickHouseVersion }}"
        - "systemctl daemon-reload"
        - "systemctl enable clickhouse-server"
```

- [ ] **Step 2：写 `ssm-documents/render-clickhouse-config.yml`**

```yaml
schemaVersion: "2.2"
description: "Render ClickHouse config.d/*.xml, users.d/*.xml and restart clickhouse-server"
parameters:
  RemoteServersXml:
    type: String
    description: "base64 of remote-servers.xml"
  ZookeeperXml:
    type: String
    description: "base64 of zookeeper.xml (points to Keeper ensemble)"
  MacrosXml:
    type: String
    description: "base64 of macros.xml (shard/replica identity)"
  UsersXml:
    type: String
    description: "base64 of users.d/default-user.xml"
mainSteps:
  - name: writeConfigs
    action: aws:runShellScript
    inputs:
      runCommand:
        - "set -euxo pipefail"
        - "mkdir -p /etc/clickhouse-server/config.d /etc/clickhouse-server/users.d"
        - "echo '{{ RemoteServersXml }}' | base64 -d > /etc/clickhouse-server/config.d/remote-servers.xml"
        - "echo '{{ ZookeeperXml }}' | base64 -d > /etc/clickhouse-server/config.d/zookeeper.xml"
        - "echo '{{ MacrosXml }}' | base64 -d > /etc/clickhouse-server/config.d/macros.xml"
        - "echo '{{ UsersXml }}' | base64 -d > /etc/clickhouse-server/users.d/default-user.xml"
        - "chown -R clickhouse:clickhouse /etc/clickhouse-server"
        - "systemctl restart clickhouse-server"
        - "sleep 5"
        - "systemctl is-active clickhouse-server"
        - "clickhouse-client --query 'SELECT 1'"
```

- [ ] **Step 3：写 `ssm-documents/bootstrap-schema.yml`**

```yaml
schemaVersion: "2.2"
description: "Apply ClickHouse schema (DDL). Placeholder until Phase 5 data model is finalized."
parameters:
  DdlSql:
    type: String
    default: "SELECT 'schema ddl not yet defined'"
    description: "Base64-encoded DDL SQL script. Default is a no-op until Phase 5."
  Base64Encoded:
    type: String
    default: "false"
    allowedValues: ["true", "false"]
mainSteps:
  - name: applySchema
    action: aws:runShellScript
    inputs:
      runCommand:
        - "set -euxo pipefail"
        - 'if [ "{{ Base64Encoded }}" = "true" ]; then echo "{{ DdlSql }}" | base64 -d | clickhouse-client --multiquery; else clickhouse-client --query "{{ DdlSql }}"; fi'
```

- [ ] **Step 4：语法检查**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse
python3 -c "
import yaml
for f in ['install-clickhouse.yml','render-clickhouse-config.yml','bootstrap-schema.yml']:
    yaml.safe_load(open(f'ssm-documents/{f}'))
print('ok')
"
```

Expected：`ok`

- [ ] **Step 5：修改 `modules/ssm-documents/main.tf` 追加资源**

在文件末尾追加：

```hcl
resource "aws_ssm_document" "install_clickhouse" {
  name            = "${var.name_prefix}-install-clickhouse"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/install-clickhouse.yml")

  tags = { Name = "${var.name_prefix}-install-clickhouse" }
}

resource "aws_ssm_document" "render_clickhouse_config" {
  name            = "${var.name_prefix}-render-clickhouse-config"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/render-clickhouse-config.yml")

  tags = { Name = "${var.name_prefix}-render-clickhouse-config" }
}

resource "aws_ssm_document" "bootstrap_schema" {
  name            = "${var.name_prefix}-bootstrap-schema"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/bootstrap-schema.yml")

  tags = { Name = "${var.name_prefix}-bootstrap-schema" }
}
```

- [ ] **Step 6：修改 `modules/ssm-documents/outputs.tf` 追加**

```hcl
output "install_clickhouse_doc_name" {
  value = aws_ssm_document.install_clickhouse.name
}

output "render_clickhouse_config_doc_name" {
  value = aws_ssm_document.render_clickhouse_config.name
}

output "bootstrap_schema_doc_name" {
  value = aws_ssm_document.bootstrap_schema.name
}
```

- [ ] **Step 7：terraform plan & apply**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform plan -out=tfplan
terraform apply tfplan
```

Expected：`Plan: 3 to add`；`Apply complete! Resources: 3 added`。

- [ ] **Step 8：验证 5 个 Document 都已注册**

```bash
aws --profile default --region ap-northeast-1 ssm list-documents \
  --filters "Key=Name,Values=zeelool-ck" \
  --query 'DocumentIdentifiers[].Name' --output text | tr '\t' '\n' | sort
```

Expected 包含这 5 个：

```
zeelool-ck-bootstrap-schema
zeelool-ck-install-clickhouse
zeelool-ck-install-keeper
zeelool-ck-render-clickhouse-config
zeelool-ck-render-keeper-config
```

- [ ] **Step 9：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/ssm-documents/ \
        2026-project/zeelool-clickhouse/terraform/modules/ssm-documents/
git commit -m "feat(zeelool-ck): clickhouse SSM documents + schema placeholder (Phase 1 done)"
```

---

## Task 9：keeper-node 模块 — EC2 + EBS + user_data

**Files:**
- Create: `terraform/modules/keeper-node/main.tf`
- Create: `terraform/modules/keeper-node/variables.tf`
- Create: `terraform/modules/keeper-node/outputs.tf`
- Create: `terraform/modules/keeper-node/user_data.sh.tftpl`

- [ ] **Step 1：`modules/keeper-node/variables.tf`**

```hcl
variable "name" {
  type        = string
  description = "Hostname-friendly node name, e.g. keeper-01"
}

variable "server_id" {
  type        = number
  description = "Keeper Raft server_id, 1..3"
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}

variable "ami_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "private_ip" {
  type = string
}

variable "security_group_ids" {
  type = list(string)
}

variable "instance_profile_name" {
  type = string
}

variable "root_volume_gb" {
  type    = number
  default = 50
}
```

- [ ] **Step 2：`modules/keeper-node/user_data.sh.tftpl`**

```bash
#!/bin/bash
set -euxo pipefail

# Set hostname
hostnamectl set-hostname ${name}
echo "127.0.1.1 ${name}" >> /etc/hosts

# SSM Agent is pre-installed on AL2023, just ensure enabled
systemctl enable --now amazon-ssm-agent || true

# Tag readiness for SSM State Manager targeting
touch /var/log/cloud-init-bootstrap.done
```

- [ ] **Step 3：`modules/keeper-node/main.tf`**

```hcl
resource "aws_instance" "keeper" {
  ami           = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  private_ip    = var.private_ip

  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.instance_profile_name

  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
    tags        = { Name = "${var.name}-root" }
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    name = var.name
  })

  tags = {
    Name     = var.name
    Role     = "keeper"
    ServerId = tostring(var.server_id)
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
```

- [ ] **Step 4：`modules/keeper-node/outputs.tf`**

```hcl
output "instance_id" {
  value = aws_instance.keeper.id
}

output "private_ip" {
  value = aws_instance.keeper.private_ip
}

output "name" {
  value = var.name
}

output "server_id" {
  value = var.server_id
}
```

- [ ] **Step 5：terraform validate**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform validate
```

Expected：`Success!`

- [ ] **Step 6：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/terraform/modules/keeper-node/
git commit -m "feat(zeelool-ck): keeper-node module (EC2 + EBS + user_data)"
```

---

## Task 10：部署 3 个 Keeper 实例（先起机器，先不做 SSM Association）

**Files:**
- Modify: `terraform/envs/prod/main.tf`
- Modify: `terraform/envs/prod/outputs.tf`

- [ ] **Step 1：在 `envs/prod/main.tf` 追加 AMI 数据源与 3 个 Keeper 模块调用**

```hcl
# Latest Amazon Linux 2023 ARM64 AMI via SSM parameter
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  keeper_nodes = {
    "keeper-01" = { az = "az1a", server_id = 1 }
    "keeper-02" = { az = "az1c", server_id = 2 }
    "keeper-03" = { az = "az1d", server_id = 3 }
  }
}

module "keeper" {
  source   = "../../modules/keeper-node"
  for_each = local.keeper_nodes

  name                  = each.key
  server_id             = each.value.server_id
  ami_id                = data.aws_ssm_parameter.al2023_arm64.value
  subnet_id             = var.private_subnet_ids[each.value.az]
  private_ip            = var.keeper_private_ips[each.value.az]
  security_group_ids    = [module.network.keeper_sg_id]
  instance_profile_name = module.iam.instance_profile_name
}
```

- [ ] **Step 2：在 `envs/prod/outputs.tf` 追加**

```hcl
output "keeper_instance_ids" {
  value = { for k, m in module.keeper : k => m.instance_id }
}

output "keeper_private_ips" {
  value = { for k, m in module.keeper : k => m.private_ip }
}
```

- [ ] **Step 3：terraform plan**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform plan -out=tfplan
```

Expected：`Plan: 3 to add`（3 EC2 实例）。

- [ ] **Step 4：terraform apply**

```bash
terraform apply tfplan
```

Expected：`Apply complete! Resources: 3 added`。

- [ ] **Step 5：等待 SSM Agent 上线**

```bash
for i in 1 2 3; do
  instance_id=$(terraform output -json keeper_instance_ids | jq -r ".\"keeper-0$i\"")
  echo "Waiting for $instance_id..."
  until aws --profile default --region ap-northeast-1 ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$instance_id" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null | grep -q "Online"; do
    sleep 5
  done
  echo "  $instance_id Online"
done
```

Expected：3 个 instance 陆续报 `Online`（通常 60-120 秒内）。

- [ ] **Step 6：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/terraform/
git commit -m "feat(zeelool-ck): deploy 3 keeper EC2 instances"
```

---

## Task 11：安装 Keeper（通过 SSM Run Command 一次性触发）

**Files:**（仅 shell 脚本操作，无 Terraform 变更）

- [ ] **Step 1：对 3 个 Keeper 触发 `install-keeper`**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod

INSTANCE_IDS=$(terraform output -json keeper_instance_ids | jq -r 'to_entries | map(.value) | join(",")')
echo "Targeting: $INSTANCE_IDS"

COMMAND_ID=$(aws --profile default --region ap-northeast-1 ssm send-command \
  --document-name "zeelool-ck-install-keeper" \
  --instance-ids $(echo $INSTANCE_IDS | tr ',' ' ') \
  --query 'Command.CommandId' --output text)

echo "Command ID: $COMMAND_ID"
```

- [ ] **Step 2：等待所有节点安装完成**

```bash
while true; do
  STATUSES=$(aws --profile default --region ap-northeast-1 ssm list-command-invocations \
    --command-id "$COMMAND_ID" \
    --query 'CommandInvocations[].Status' --output text)
  echo "Current: $STATUSES"
  if echo "$STATUSES" | grep -qvE "Success|Failed|Cancelled|TimedOut"; then
    sleep 5
    continue
  fi
  break
done
echo "All done. Final: $STATUSES"
```

Expected：最终所有 3 个状态都是 `Success`。若有 `Failed`，查看 `aws ssm get-command-invocation --command-id $COMMAND_ID --instance-id <id>` 并修复。

- [ ] **Step 3：验证 Keeper binary 已装但尚未启动（配置还未下发）**

```bash
INSTANCE_ID=$(terraform output -json keeper_instance_ids | jq -r '."keeper-01"')
aws --profile default --region ap-northeast-1 ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$INSTANCE_ID" \
  --parameters 'commands=["rpm -q clickhouse-keeper"]' \
  --query 'Command.CommandId' --output text
# 等 5 秒后再查
```

Expected：package 版本字符串（如 `clickhouse-keeper-25.3.2.39-x86_64`）。

- [ ] **Step 4：Commit 标记本步骤完成（无文件变化，以空 commit 记录进度）**

```bash
cd /root/keith-space
git commit --allow-empty -m "ops(zeelool-ck): keeper binaries installed via SSM"
```

---

## Task 12：下发 Keeper 配置并启动集群

**Files:**（操作性 shell + 临时 Terraform 变量，无新模块）

- [ ] **Step 1：在本地生成 3 份 keeper_config.xml**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse

mkdir -p /tmp/keeper-configs

for i in 1 2 3; do
  case $i in
    1) az=az1a ;;
    2) az=az1c ;;
    3) az=az1d ;;
  esac

  cat > /tmp/keeper-configs/keeper-0${i}.xml <<EOF
<clickhouse>
    <logger>
        <level>information</level>
        <log>/var/log/clickhouse-keeper/clickhouse-keeper.log</log>
        <errorlog>/var/log/clickhouse-keeper/clickhouse-keeper.err.log</errorlog>
        <size>100M</size>
        <count>10</count>
    </logger>
    <listen_host>0.0.0.0</listen_host>
    <max_connections>4096</max_connections>
    <keeper_server>
        <server_id>${i}</server_id>
        <tcp_port>9181</tcp_port>
        <log_storage_path>/var/lib/clickhouse-keeper/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse-keeper/coordination/snapshots</snapshot_storage_path>
        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>information</raft_logs_level>
            <snapshot_distance>10000</snapshot_distance>
            <reserved_log_items>1000</reserved_log_items>
            <auto_forwarding>true</auto_forwarding>
        </coordination_settings>
        <raft_configuration>
            <server><id>1</id><hostname>10.0.11.100</hostname><port>9234</port></server>
            <server><id>2</id><hostname>10.0.12.100</hostname><port>9234</port></server>
            <server><id>3</id><hostname>10.0.13.100</hostname><port>9234</port></server>
        </raft_configuration>
    </keeper_server>
</clickhouse>
EOF
done

ls -la /tmp/keeper-configs/
```

Expected：3 个 xml 文件生成。

- [ ] **Step 2：对每个节点调用 render-keeper-config**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod

declare -A KEEPER_CMDS
for i in 1 2 3; do
  instance_id=$(terraform output -json keeper_instance_ids | jq -r ".\"keeper-0${i}\"")
  config_b64=$(base64 -w0 /tmp/keeper-configs/keeper-0${i}.xml)
  cmd_id=$(aws --profile default --region ap-northeast-1 ssm send-command \
    --document-name "zeelool-ck-render-keeper-config" \
    --instance-ids "$instance_id" \
    --parameters "ConfigXml=${config_b64}" \
    --query 'Command.CommandId' --output text)
  KEEPER_CMDS[$i]=$cmd_id
  echo "keeper-0${i} ($instance_id) → $cmd_id"
done
```

- [ ] **Step 3：等待 3 个命令完成**

```bash
for i in 1 2 3; do
  cmd_id=${KEEPER_CMDS[$i]}
  instance_id=$(terraform output -json keeper_instance_ids | jq -r ".\"keeper-0${i}\"")
  aws --profile default --region ap-northeast-1 ssm wait command-executed \
    --command-id "$cmd_id" \
    --instance-id "$instance_id"
  status=$(aws --profile default --region ap-northeast-1 ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$instance_id" \
    --query 'Status' --output text)
  echo "keeper-0${i}: $status"
done
```

Expected：3 个都是 `Success`。

- [ ] **Step 4：验证 Keeper Raft 集群成环**

```bash
INSTANCE_ID=$(terraform output -json keeper_instance_ids | jq -r '."keeper-01"')

CMD_ID=$(aws --profile default --region ap-northeast-1 ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$INSTANCE_ID" \
  --parameters 'commands=["echo mntr | nc -q 2 localhost 9181"]' \
  --query 'Command.CommandId' --output text)

sleep 5

aws --profile default --region ap-northeast-1 ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text
```

Expected 输出包含类似：

```
zk_version  v25.3...
zk_server_state  leader   (或 follower)
zk_followers  2           (如果是 leader)
zk_synced_followers  2
```

若看到 `leader` + `followers=2 synced_followers=2`，Raft 仲裁成功。**这是 Phase 2 的关键里程碑。**

- [ ] **Step 5：Commit（标记里程碑）**

```bash
cd /root/keith-space
git commit --allow-empty -m "ops(zeelool-ck): keeper cluster formed, raft quorum healthy (Phase 2 done)"
```

---

## Task 13：ClickHouse 配置模板（remote-servers / zookeeper / macros / users）

**Files:**
- Create: `config/clickhouse/config.d/remote-servers.xml.tftpl`
- Create: `config/clickhouse/config.d/zookeeper.xml.tftpl`
- Create: `config/clickhouse/config.d/macros.xml.tftpl`
- Create: `config/clickhouse/config.d/logger.xml`
- Create: `config/clickhouse/users.d/default-user.xml.tftpl`

- [ ] **Step 1：`config/clickhouse/config.d/remote-servers.xml.tftpl`**

```xml
<clickhouse>
    <remote_servers>
        <${cluster_name}>
            <shard>
                <internal_replication>true</internal_replication>
%{ for replica in replicas ~}
                <replica>
                    <host>${replica.host}</host>
                    <port>9000</port>
                </replica>
%{ endfor ~}
            </shard>
        </${cluster_name}>
    </remote_servers>
</clickhouse>
```

- [ ] **Step 2：`config/clickhouse/config.d/zookeeper.xml.tftpl`**

```xml
<clickhouse>
    <zookeeper>
%{ for k in keepers ~}
        <node>
            <host>${k.host}</host>
            <port>9181</port>
        </node>
%{ endfor ~}
        <session_timeout_ms>30000</session_timeout_ms>
        <operation_timeout_ms>10000</operation_timeout_ms>
    </zookeeper>
</clickhouse>
```

- [ ] **Step 3：`config/clickhouse/config.d/macros.xml.tftpl`**

```xml
<clickhouse>
    <macros>
        <cluster>${cluster_name}</cluster>
        <shard>${shard}</shard>
        <replica>${replica}</replica>
    </macros>
</clickhouse>
```

- [ ] **Step 4：`config/clickhouse/config.d/logger.xml`**

```xml
<clickhouse>
    <logger>
        <level>information</level>
        <log>/var/log/clickhouse-server/clickhouse-server.log</log>
        <errorlog>/var/log/clickhouse-server/clickhouse-server.err.log</errorlog>
        <size>500M</size>
        <count>10</count>
    </logger>
    <listen_host>0.0.0.0</listen_host>
</clickhouse>
```

- [ ] **Step 5：`config/clickhouse/users.d/default-user.xml.tftpl`**

```xml
<clickhouse>
    <users>
        <default>
            <password_sha256_hex>${default_password_sha256}</password_sha256_hex>
            <networks>
                <ip>10.0.0.0/16</ip>
                <ip>127.0.0.1</ip>
                <ip>::1</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>0</access_management>
        </default>
    </users>
</clickhouse>
```

- [ ] **Step 6：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/config/clickhouse/
git commit -m "feat(zeelool-ck): clickhouse config templates"
```

---

## Task 14：clickhouse-node 模块（EC2 + EBS 根盘 + 1500 GB 数据盘）

**Files:**
- Create: `terraform/modules/clickhouse-node/main.tf`
- Create: `terraform/modules/clickhouse-node/variables.tf`
- Create: `terraform/modules/clickhouse-node/outputs.tf`
- Create: `terraform/modules/clickhouse-node/user_data.sh.tftpl`

- [ ] **Step 1：`modules/clickhouse-node/variables.tf`**

```hcl
variable "name" {
  type = string
}

variable "replica_name" {
  type = string
}

variable "shard" {
  type    = string
  default = "01"
}

variable "instance_type" {
  type    = string
  default = "r8g.xlarge"
}

variable "ami_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "private_ip" {
  type = string
}

variable "security_group_ids" {
  type = list(string)
}

variable "instance_profile_name" {
  type = string
}

variable "root_volume_gb" {
  type    = number
  default = 50
}

variable "data_volume_gb" {
  type    = number
  default = 1500
}

variable "availability_zone" {
  type        = string
  description = "AZ for the data volume (must match subnet's AZ)"
}
```

- [ ] **Step 2：`modules/clickhouse-node/user_data.sh.tftpl`**

```bash
#!/bin/bash
set -euxo pipefail

hostnamectl set-hostname ${name}
echo "127.0.1.1 ${name}" >> /etc/hosts

# Wait for the attached data volume (NVMe enumeration can race cloud-init)
DATA_DEV=""
for _ in {1..30}; do
  # Pick the first NVMe device that is NOT the root disk.
  ROOT_DEV=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)
  CANDIDATE=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -v "^$ROOT_DEV$" | head -n1 || true)
  if [ -n "$CANDIDATE" ] && [ -b "/dev/$CANDIDATE" ]; then
    DATA_DEV="/dev/$CANDIDATE"
    break
  fi
  sleep 2
done
if [ -z "$DATA_DEV" ]; then
  echo "ERROR: data volume not found" >&2
  exit 1
fi

# Format only if no filesystem yet (idempotent across reboots)
if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
  mkfs.ext4 -L clickhouse-data "$DATA_DEV"
fi

mkdir -p /var/lib/clickhouse
if ! grep -q "LABEL=clickhouse-data" /etc/fstab; then
  echo "LABEL=clickhouse-data /var/lib/clickhouse ext4 defaults,noatime,nodiratime,nofail 0 2" >> /etc/fstab
fi
mountpoint -q /var/lib/clickhouse || mount /var/lib/clickhouse

systemctl enable --now amazon-ssm-agent || true

touch /var/log/cloud-init-bootstrap.done
```

- [ ] **Step 3：`modules/clickhouse-node/main.tf`**

```hcl
resource "aws_instance" "clickhouse" {
  ami           = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  private_ip    = var.private_ip

  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.instance_profile_name

  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
    tags        = { Name = "${var.name}-root" }
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    name = var.name
  })

  tags = {
    Name    = var.name
    Role    = "clickhouse"
    Shard   = var.shard
    Replica = var.replica_name
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${var.name}-data" }
}

resource "aws_volume_attachment" "data" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.data.id
  instance_id  = aws_instance.clickhouse.id
  stop_instance_before_detaching = true
}
```

- [ ] **Step 4：`modules/clickhouse-node/outputs.tf`**

```hcl
output "instance_id" {
  value = aws_instance.clickhouse.id
}

output "private_ip" {
  value = aws_instance.clickhouse.private_ip
}

output "name" {
  value = var.name
}

output "replica_name" {
  value = var.replica_name
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}
```

- [ ] **Step 5：terraform validate**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform validate
```

Expected：`Success!`

- [ ] **Step 6：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/terraform/modules/clickhouse-node/
git commit -m "feat(zeelool-ck): clickhouse-node module (EC2 + 1500GB data EBS)"
```

---

## Task 15：部署 2 个 CK 实例 + 安装 CK binary

**Files:**
- Modify: `terraform/envs/prod/main.tf`
- Modify: `terraform/envs/prod/outputs.tf`

- [ ] **Step 1：在 `envs/prod/main.tf` 追加 CK 模块调用**

```hcl
locals {
  clickhouse_nodes = {
    "ck-01" = { az = "az1a", replica = "ck-01", az_name = "ap-northeast-1a" }
    "ck-02" = { az = "az1c", replica = "ck-02", az_name = "ap-northeast-1c" }
  }
}

module "clickhouse" {
  source   = "../../modules/clickhouse-node"
  for_each = local.clickhouse_nodes

  name                  = each.key
  replica_name          = each.value.replica
  availability_zone     = each.value.az_name
  ami_id                = data.aws_ssm_parameter.al2023_arm64.value
  subnet_id             = var.private_subnet_ids[each.value.az]
  private_ip            = var.clickhouse_private_ips[each.value.az]
  security_group_ids    = [module.network.clickhouse_sg_id]
  instance_profile_name = module.iam.instance_profile_name
}
```

- [ ] **Step 2：`envs/prod/outputs.tf` 追加**

```hcl
output "clickhouse_instance_ids" {
  value = { for k, m in module.clickhouse : k => m.instance_id }
}

output "clickhouse_private_ips" {
  value = { for k, m in module.clickhouse : k => m.private_ip }
}
```

- [ ] **Step 3：terraform plan & apply**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform plan -out=tfplan
terraform apply tfplan
```

Expected：`Plan: 6 to add`（2 instance + 2 volume + 2 attachment）；`Apply complete!`。

- [ ] **Step 4：等待 SSM Agent + 数据盘挂载就绪**

```bash
for name in ck-01 ck-02; do
  instance_id=$(terraform output -json clickhouse_instance_ids | jq -r ".\"${name}\"")
  echo "Waiting for $name ($instance_id) SSM online..."
  until aws --profile default --region ap-northeast-1 ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$instance_id" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null | grep -q "Online"; do
    sleep 5
  done
done

# Verify data volume mounted
for name in ck-01 ck-02; do
  instance_id=$(terraform output -json clickhouse_instance_ids | jq -r ".\"${name}\"")
  cmd_id=$(aws --profile default --region ap-northeast-1 ssm send-command \
    --document-name "AWS-RunShellScript" \
    --instance-ids "$instance_id" \
    --parameters 'commands=["df -h /var/lib/clickhouse"]' \
    --query 'Command.CommandId' --output text)
  sleep 5
  aws --profile default --region ap-northeast-1 ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$instance_id" \
    --query 'StandardOutputContent' --output text
done
```

Expected：每个节点输出类似 `/dev/nvme1n1  1.5T ... /var/lib/clickhouse`。

- [ ] **Step 5：触发 `install-clickhouse` SSM Document**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod

CK_IDS=$(terraform output -json clickhouse_instance_ids | jq -r 'to_entries | map(.value) | join(" ")')

CMD_ID=$(aws --profile default --region ap-northeast-1 ssm send-command \
  --document-name "zeelool-ck-install-clickhouse" \
  --instance-ids $CK_IDS \
  --query 'Command.CommandId' --output text)

echo "Command ID: $CMD_ID"

# Wait
while true; do
  STATUSES=$(aws --profile default --region ap-northeast-1 ssm list-command-invocations \
    --command-id "$CMD_ID" \
    --query 'CommandInvocations[].Status' --output text)
  if echo "$STATUSES" | grep -qvE "Success|Failed|Cancelled|TimedOut"; then
    sleep 10; continue
  fi
  break
done
echo "Final: $STATUSES"
```

Expected：两个 `Success`。

- [ ] **Step 6：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/terraform/
git commit -m "feat(zeelool-ck): deploy 2 clickhouse EC2 + install binaries"
```

---

## Task 16：下发 ClickHouse 配置并形成副本集群

**Files:** `scripts/render-and-push-ck-config.sh`

> **安全红线（review 修订）：**
> - `default` 用户 **必须** 用 `password_sha256_hex`（SSM SecureString 存原文），不能用空密码
> - `<access_management>` 必须为 `0`，防止 default 账户在 VPC 内创建其他超级用户
> - 渲染流程由脚本 `scripts/render-and-push-ck-config.sh` 执行，以 `.tftpl` 模板为唯一来源
>
> 之前计划里的 inline `cat <<EOF` 方式（空密码 + access_management=1）已废弃。

- [ ] **Step 0：首次部署前，往 SSM Parameter Store 写入 default 用户密码**

```bash
PASS=$(openssl rand -base64 24 | tr -d '+/=' | head -c 32)
aws --region ap-northeast-1 ssm put-parameter \
  --name /zeelool-ck/default-user-password \
  --type SecureString --value "$PASS" \
  --description "ClickHouse default user password (zeelool-ck)"
echo "Password set. Store it in your password manager: $PASS"
```

- [ ] **Step 1：跑渲染 + 推送脚本**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse
./scripts/render-and-push-ck-config.sh
```

脚本会：
1. 从 SSM 读回密码、算 SHA256
2. 用 `.tftpl` 模板 + `sed/awk` 本地渲染所有节点的 XML（含 users.d/default-user.xml）
3. base64 后通过 `zeelool-ck-render-clickhouse-config` SSM Document 推到 ck-01 / ck-02

Expected：两个 `Success`。

— 以下 Step 2-3 是旧的手动 runbook，保留仅作参考，不应再跑 —

<details>
<summary>旧 runbook（已弃用）</summary>

- [ ] **（旧）Step 1：准备 4 份共享配置（不依赖节点）**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse

mkdir -p /tmp/ck-configs

# remote-servers.xml（两节点共享）
cat > /tmp/ck-configs/remote-servers.xml <<'EOF'
<clickhouse>
    <remote_servers>
        <zeelool_ck>
            <shard>
                <internal_replication>true</internal_replication>
                <replica><host>10.0.11.200</host><port>9000</port></replica>
                <replica><host>10.0.12.200</host><port>9000</port></replica>
            </shard>
        </zeelool_ck>
    </remote_servers>
</clickhouse>
EOF

# zookeeper.xml（两节点共享，指向 3 Keepers）
cat > /tmp/ck-configs/zookeeper.xml <<'EOF'
<clickhouse>
    <zookeeper>
        <node><host>10.0.11.100</host><port>9181</port></node>
        <node><host>10.0.12.100</host><port>9181</port></node>
        <node><host>10.0.13.100</host><port>9181</port></node>
        <session_timeout_ms>30000</session_timeout_ms>
        <operation_timeout_ms>10000</operation_timeout_ms>
    </zookeeper>
</clickhouse>
EOF

# users.d/default-user.xml — 先用空密码简化，生产需改
# 空密码 SHA256 = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
cat > /tmp/ck-configs/default-user.xml <<'EOF'
<clickhouse>
    <users>
        <default>
            <password></password>
            <networks>
                <ip>10.0.0.0/16</ip>
                <ip>127.0.0.1</ip>
                <ip>::1</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
        </default>
    </users>
</clickhouse>
EOF
```

- [ ] **Step 2：为每个节点生成 macros.xml（节点级差异）**

```bash
cat > /tmp/ck-configs/macros-ck-01.xml <<'EOF'
<clickhouse>
    <macros>
        <cluster>zeelool_ck</cluster>
        <shard>01</shard>
        <replica>ck-01</replica>
    </macros>
</clickhouse>
EOF

cat > /tmp/ck-configs/macros-ck-02.xml <<'EOF'
<clickhouse>
    <macros>
        <cluster>zeelool_ck</cluster>
        <shard>01</shard>
        <replica>ck-02</replica>
    </macros>
</clickhouse>
EOF
```

- [ ] **Step 3：对 ck-01、ck-02 分别触发 `render-clickhouse-config`**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod

RS_B64=$(base64 -w0 /tmp/ck-configs/remote-servers.xml)
ZK_B64=$(base64 -w0 /tmp/ck-configs/zookeeper.xml)
USERS_B64=$(base64 -w0 /tmp/ck-configs/default-user.xml)

declare -A CK_CMDS
for name in ck-01 ck-02; do
  instance_id=$(terraform output -json clickhouse_instance_ids | jq -r ".\"${name}\"")
  macros_b64=$(base64 -w0 /tmp/ck-configs/macros-${name}.xml)

  cmd_id=$(aws --profile default --region ap-northeast-1 ssm send-command \
    --document-name "zeelool-ck-render-clickhouse-config" \
    --instance-ids "$instance_id" \
    --parameters "RemoteServersXml=${RS_B64},ZookeeperXml=${ZK_B64},MacrosXml=${macros_b64},UsersXml=${USERS_B64}" \
    --query 'Command.CommandId' --output text)
  CK_CMDS[$name]=$cmd_id
  echo "$name ($instance_id) → $cmd_id"
done

# Wait all
for name in ck-01 ck-02; do
  cmd_id=${CK_CMDS[$name]}
  instance_id=$(terraform output -json clickhouse_instance_ids | jq -r ".\"${name}\"")
  aws --profile default --region ap-northeast-1 ssm wait command-executed \
    --command-id "$cmd_id" --instance-id "$instance_id"
  status=$(aws --profile default --region ap-northeast-1 ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$instance_id" \
    --query 'Status' --output text)
  echo "$name: $status"
done
```

Expected：两个都是 `Success`。

</details>

- [ ] **Step 4：验证 CK 两节点互见（shard 的两个 replica 相互识别）**

```bash
INSTANCE_ID=$(terraform output -json clickhouse_instance_ids | jq -r '."ck-01"')

CMD_ID=$(aws --profile default --region ap-northeast-1 ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$INSTANCE_ID" \
  --parameters 'commands=["clickhouse-client --query \"SELECT cluster, shard_num, replica_num, host_name, host_address, is_local FROM system.clusters WHERE cluster = '"'"'zeelool_ck'"'"' FORMAT PrettyCompactNoEscapes\""]' \
  --query 'Command.CommandId' --output text)

sleep 5

aws --profile default --region ap-northeast-1 ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text
```

Expected 输出（大致）：

```
cluster     shard_num replica_num host_name    host_address  is_local
zeelool_ck  1         1           10.0.11.200  10.0.11.200   1
zeelool_ck  1         2           10.0.12.200  10.0.12.200   0
```

- [ ] **Step 5：验证 Keeper 连接健康**

```bash
CMD_ID=$(aws --profile default --region ap-northeast-1 ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$INSTANCE_ID" \
  --parameters 'commands=["clickhouse-client --query \"SELECT name, keeper_api_version, status FROM system.zookeeper_connection\""]' \
  --query 'Command.CommandId' --output text)

sleep 5

aws --profile default --region ap-northeast-1 ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text
```

Expected：一行记录，`status=Connected`。若为 `Expired` 或空，检查 `system.zookeeper_log` 与 Keeper 侧网络连通性。

- [ ] **Step 6：端到端 smoke test — 建一个临时 Replicated 表并双向写读**

```bash
CMD_ID=$(aws --profile default --region ap-northeast-1 ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$INSTANCE_ID" \
  --parameters 'commands=["clickhouse-client -n --query \"
CREATE TABLE IF NOT EXISTS smoke_test ON CLUSTER zeelool_ck (id UInt32, ts DateTime DEFAULT now()) ENGINE = ReplicatedMergeTree('"'"'/clickhouse/tables/{shard}/smoke_test'"'"', '"'"'{replica}'"'"') ORDER BY id;
INSERT INTO smoke_test (id) VALUES (1),(2),(3);
SELECT hostName(), count() FROM smoke_test;
SELECT hostName(), count() FROM remote('"'"'10.0.12.200:9000'"'"', default, smoke_test);
DROP TABLE smoke_test ON CLUSTER zeelool_ck SYNC;
\""]' \
  --query 'Command.CommandId' --output text)

sleep 10

aws --profile default --region ap-northeast-1 ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text
```

Expected：
- 本机 count() = 3
- 远端 count() = 3（副本同步成功）

- [ ] **Step 7：Commit 里程碑**

```bash
cd /root/keith-space
git commit --allow-empty -m "ops(zeelool-ck): clickhouse replicas formed, smoke test pass (Phase 3 done)"
```

---

## Task 17：nlb 模块（NLB + target group + Route53 private zone 别名）

**Files:**
- Create: `terraform/modules/nlb/main.tf`
- Create: `terraform/modules/nlb/variables.tf`
- Create: `terraform/modules/nlb/outputs.tf`
- Modify: `terraform/envs/prod/main.tf`
- Modify: `terraform/envs/prod/outputs.tf`

- [ ] **Step 1：`modules/nlb/variables.tf`**

```hcl
variable "name" {
  type    = string
  default = "zeelool-ck-nlb"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs across AZs"
}

variable "security_group_ids" {
  type = list(string)
}

variable "target_instance_ids" {
  type        = map(string)
  description = "Map of CK node name -> instance ID"
}

variable "hosted_zone_name" {
  type = string
}

variable "dns_record_name" {
  type        = string
  default     = "clickhouse"
  description = "Subdomain under hosted_zone_name"
}
```

- [ ] **Step 2：`modules/nlb/main.tf`**

```hcl
resource "aws_lb" "this" {
  name                             = var.name
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.subnet_ids
  security_groups                  = var.security_group_ids
  enable_cross_zone_load_balancing = true

  tags = { Name = var.name }
}

resource "aws_lb_target_group" "native" {
  name        = "${var.name}-9000"
  port        = 9000
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "8123"
    path                = "/ping"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  deregistration_delay = 30
}

resource "aws_lb_target_group" "http" {
  name        = "${var.name}-8123"
  port        = 8123
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = "/ping"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  deregistration_delay = 30
}

resource "aws_lb_target_group_attachment" "native" {
  for_each = var.target_instance_ids

  target_group_arn = aws_lb_target_group.native.arn
  target_id        = each.value
  port             = 9000
}

resource "aws_lb_target_group_attachment" "http" {
  for_each = var.target_instance_ids

  target_group_arn = aws_lb_target_group.http.arn
  target_id        = each.value
  port             = 8123
}

resource "aws_lb_listener" "native" {
  load_balancer_arn = aws_lb.this.arn
  port              = 9000
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.native.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 8123
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }
}

# Private hosted zone — create if missing, otherwise adopt via data source.
resource "aws_route53_zone" "private" {
  name = var.hosted_zone_name

  vpc {
    vpc_id = var.vpc_id
  }

  tags = { Name = var.hosted_zone_name }

  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_record" "alias" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "${var.dns_record_name}.${var.hosted_zone_name}"
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
```

- [ ] **Step 3：`modules/nlb/outputs.tf`**

```hcl
output "dns_name" {
  value = aws_lb.this.dns_name
}

output "alias_fqdn" {
  value = aws_route53_record.alias.fqdn
}

output "nlb_arn" {
  value = aws_lb.this.arn
}
```

- [ ] **Step 4：在 `envs/prod/main.tf` 追加**

```hcl
module "nlb" {
  source = "../../modules/nlb"

  vpc_id             = var.vpc_id
  subnet_ids         = [for az in ["az1a", "az1c", "az1d"] : var.private_subnet_ids[az]]
  security_group_ids = [module.network.nlb_sg_id]
  target_instance_ids = { for k, m in module.clickhouse : k => m.instance_id }
  hosted_zone_name   = var.private_hosted_zone_name
}
```

- [ ] **Step 5：`envs/prod/outputs.tf` 追加**

```hcl
output "clickhouse_fqdn" {
  value = module.nlb.alias_fqdn
}

output "nlb_dns_name" {
  value = module.nlb.dns_name
}
```

- [ ] **Step 6：plan & apply**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform plan -out=tfplan
terraform apply tfplan
```

Expected：`Plan: 8 to add`（NLB + 2 TG + 4 attachments + 2 listener + 1 zone + 1 record ≈ 11 取决于实际计数），`Apply complete!`。

- [ ] **Step 7：等待 NLB target healthy（首次约 60-90s）**

```bash
NLB_ARN=$(terraform output -raw nlb_dns_name)
TG_HTTP_ARN=$(aws --profile default --region ap-northeast-1 elbv2 describe-target-groups \
  --names zeelool-ck-nlb-8123 --query 'TargetGroups[0].TargetGroupArn' --output text)

for _ in {1..30}; do
  HEALTHY=$(aws --profile default --region ap-northeast-1 elbv2 describe-target-health \
    --target-group-arn "$TG_HTTP_ARN" \
    --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`] | length(@)' --output text)
  echo "Healthy targets: $HEALTHY/2"
  [ "$HEALTHY" = "2" ] && break
  sleep 10
done
```

Expected：`Healthy targets: 2/2`。

- [ ] **Step 8：端到端验证：从运维 EC2 通过 NLB 访问 CK**

从当前 EC2（i-01e132939b01ff81b）：

```bash
# 先在本机装 clickhouse-client（一次性）
dnf install -y yum-utils 2>/dev/null || sudo dnf install -y yum-utils
sudo dnf config-manager --add-repo https://packages.clickhouse.com/rpm/clickhouse.repo 2>/dev/null
sudo dnf install -y --enablerepo=clickhouse-lts clickhouse-client 2>/dev/null

# 通过 FQDN 访问
FQDN=$(cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod && terraform output -raw clickhouse_fqdn)
clickhouse-client --host "$FQDN" --port 9000 --query "SELECT version(), hostName()"
```

Expected：返回 CK 版本 + 命中的某个 CK 节点的 hostname。

- [ ] **Step 9：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/terraform/
git commit -m "feat(zeelool-ck): NLB + Route53 private zone alias (Phase 4 done)"
```

---

## Task 18：run-backup SSM Document

**Files:**
- Create: `ssm-documents/run-backup.yml`
- Modify: `terraform/modules/ssm-documents/main.tf`
- Modify: `terraform/modules/ssm-documents/outputs.tf`

- [ ] **Step 1：`ssm-documents/run-backup.yml`**

```yaml
schemaVersion: "2.2"
description: "Trigger ClickHouse BACKUP TO S3 from ck-01 (full or incremental)."
parameters:
  BucketName:
    type: String
  BackupType:
    type: String
    default: "incremental"
    allowedValues: ["full", "incremental"]
  BackupDate:
    type: String
    description: "YYYY-MM-DD, typically from EventBridge schedule context"
mainSteps:
  - name: runBackup
    action: aws:runShellScript
    inputs:
      runCommand:
        - "set -euxo pipefail"
        - 'TABLE="default.events_local"'
        - 'S3_BASE="s3://{{ BucketName }}"'
        - 'BACKUP_TYPE="{{ BackupType }}"'
        - 'BACKUP_DATE="{{ BackupDate }}"'
        - 'if ! clickhouse-client --query "EXISTS TABLE ${TABLE}" | grep -q "^1$"; then echo "table ${TABLE} not yet created (Phase 5 pending), skipping"; exit 0; fi'
        - 'if [ "${BACKUP_TYPE}" = "full" ]; then TARGET="${S3_BASE}/full/${BACKUP_DATE}/"; clickhouse-client --query "BACKUP TABLE ${TABLE} TO S3(''${TARGET}'') SETTINGS compression_method=''zstd'', compression_level=3"; else LAST_FULL=$(aws s3 ls "${S3_BASE}/full/" | awk ''{print $2}'' | sed ''s|/$||'' | sort | tail -n 1); if [ -z "${LAST_FULL}" ]; then echo "no full backup yet; running full instead"; TARGET="${S3_BASE}/full/${BACKUP_DATE}/"; clickhouse-client --query "BACKUP TABLE ${TABLE} TO S3(''${TARGET}'') SETTINGS compression_method=''zstd'', compression_level=3"; else TARGET="${S3_BASE}/incremental/${BACKUP_DATE}/"; BASE="${S3_BASE}/full/${LAST_FULL}/"; clickhouse-client --query "BACKUP TABLE ${TABLE} TO S3(''${TARGET}'') SETTINGS compression_method=''zstd'', compression_level=3, base_backup=S3(''${BASE}'')"; fi; fi'
```

- [ ] **Step 2：语法检查**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse
python3 -c "import yaml; yaml.safe_load(open('ssm-documents/run-backup.yml')); print('ok')"
```

Expected：`ok`

- [ ] **Step 3：模块中注册**

在 `terraform/modules/ssm-documents/main.tf` 末尾追加：

```hcl
resource "aws_ssm_document" "run_backup" {
  name            = "${var.name_prefix}-run-backup"
  document_type   = "Command"
  document_format = "YAML"
  content         = file("${path.module}/${var.document_dir}/run-backup.yml")

  tags = { Name = "${var.name_prefix}-run-backup" }
}
```

在 `terraform/modules/ssm-documents/outputs.tf` 追加：

```hcl
output "run_backup_doc_name" {
  value = aws_ssm_document.run_backup.name
}
```

- [ ] **Step 4：plan & apply**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform plan -out=tfplan
terraform apply tfplan
```

Expected：`Plan: 1 to add`。

- [ ] **Step 5：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/
git commit -m "feat(zeelool-ck): run-backup SSM Document"
```

---

## Task 19：backup-s3 模块（S3 bucket + EventBridge 调度）

**Files:**
- Create: `terraform/modules/backup-s3/main.tf`
- Create: `terraform/modules/backup-s3/variables.tf`
- Create: `terraform/modules/backup-s3/outputs.tf`
- Modify: `terraform/envs/prod/main.tf`
- Modify: `terraform/modules/iam/variables.tf`（再审 backup_bucket_arn 注入点）

- [ ] **Step 1：`modules/backup-s3/variables.tf`**

```hcl
variable "bucket_name" {
  type    = string
  default = "example-ck-backup-apne1"
}

variable "schedule_full_cron" {
  type        = string
  default     = "cron(0 17 ? * SUN *)"
  description = "UTC; Sunday 17:00 UTC == Monday 02:00 JST"
}

variable "schedule_incremental_cron" {
  type        = string
  default     = "cron(0 17 ? * MON-SAT *)"
}

variable "run_backup_doc_name" {
  type = string
}

variable "ck_primary_instance_id" {
  type        = string
  description = "ck-01 instance ID (single-node backup executor)"
}

variable "incremental_retention_days" {
  type    = number
  default = 14
}

variable "full_retention_days" {
  type    = number
  default = 28
}
```

- [ ] **Step 2：`modules/backup-s3/main.tf`**

```hcl
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "backup" {
  bucket = var.bucket_name

  tags = { Name = var.bucket_name }
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "incremental-expire"
    status = "Enabled"
    filter { prefix = "incremental/" }
    expiration { days = var.incremental_retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  rule {
    id     = "full-expire"
    status = "Enabled"
    filter { prefix = "full/" }
    # NOTE: no Glacier transition — full_retention_days default is 28, and AWS
    # requires expiration.days > transition.days. If you want cold archival,
    # bump full_retention_days to >= 90 then re-add a transition{ days=30 }.
    expiration { days = var.full_retention_days }
    noncurrent_version_expiration { noncurrent_days = 14 }
  }
}

# EventBridge IAM role to invoke SSM SendCommand
data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events" {
  name               = "zeelool-ck-backup-events"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

data "aws_iam_policy_document" "events" {
  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "events" {
  name   = "zeelool-ck-backup-events"
  role   = aws_iam_role.events.id
  policy = data.aws_iam_policy_document.events.json
}

resource "aws_cloudwatch_event_rule" "full" {
  name                = "zeelool-ck-backup-full"
  description         = "Weekly full backup"
  schedule_expression = var.schedule_full_cron
}

resource "aws_cloudwatch_event_rule" "incremental" {
  name                = "zeelool-ck-backup-incremental"
  description         = "Daily incremental backup"
  schedule_expression = var.schedule_incremental_cron
}

resource "aws_cloudwatch_event_target" "full" {
  rule     = aws_cloudwatch_event_rule.full.name
  arn      = "arn:aws:ssm:ap-northeast-1:${data.aws_caller_identity.current.account_id}:document/${var.run_backup_doc_name}"
  role_arn = aws_iam_role.events.arn

  run_command_targets {
    key    = "InstanceIds"
    values = [var.ck_primary_instance_id]
  }

  input = jsonencode({
    BucketName = [var.bucket_name]
    BackupType = ["full"]
    BackupDate = ["<aws.events.event.ingestion-time>"]
  })
}

resource "aws_cloudwatch_event_target" "incremental" {
  rule     = aws_cloudwatch_event_rule.incremental.name
  arn      = "arn:aws:ssm:ap-northeast-1:${data.aws_caller_identity.current.account_id}:document/${var.run_backup_doc_name}"
  role_arn = aws_iam_role.events.arn

  run_command_targets {
    key    = "InstanceIds"
    values = [var.ck_primary_instance_id]
  }

  input = jsonencode({
    BucketName = [var.bucket_name]
    BackupType = ["incremental"]
    BackupDate = ["<aws.events.event.ingestion-time>"]
  })
}
```

**SSM Document ARN 格式说明**：customer-owned SSM Document 的 ARN 形如 `arn:aws:ssm:<region>:<account>:document/<name>`，所以需要 `data "aws_caller_identity"` 查当前账号号码拼进去（上面 `main.tf` 顶部已声明 `data "aws_caller_identity" "current"`）。

- [ ] **Step 3：`modules/backup-s3/outputs.tf`**

```hcl
output "bucket_arn" {
  value = aws_s3_bucket.backup.arn
}

output "bucket_name" {
  value = aws_s3_bucket.backup.id
}
```

- [ ] **Step 4：在 `envs/prod/main.tf` 追加**

```hcl
module "backup_s3" {
  source = "../../modules/backup-s3"

  run_backup_doc_name     = module.ssm_documents.run_backup_doc_name
  ck_primary_instance_id  = module.clickhouse["ck-01"].instance_id
}
```

- [ ] **Step 5：把 backup bucket ARN 回注到 iam 模块**

修改 `envs/prod/main.tf` 中 `module "iam"` 调用：

```hcl
module "iam" {
  source = "../../modules/iam"

  backup_bucket_arn = module.backup_s3.bucket_arn
}
```

（Terraform 可解决循环：backup-s3 不依赖 iam 模块输出；iam 只是拿到 backup bucket ARN 来写 policy；两模块在 graph 里是 iam ← backup_s3 单向依赖。）

- [ ] **Step 6：plan & apply**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform plan -out=tfplan
terraform apply tfplan
```

Expected：约 10+ 资源 add（S3 + versioning + encryption + pab + lifecycle + 2 rule + 2 target + events role + events policy + iam policy for CK）。

- [ ] **Step 7：Commit**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/terraform/
git commit -m "feat(zeelool-ck): backup S3 bucket + EventBridge schedules"
```

---

## Task 20：首次手动跑一次全量备份并验证

**Files:** 仅脚本化操作。

- [ ] **Step 1：手动触发一次 full backup**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod

CK01_ID=$(terraform output -json clickhouse_instance_ids | jq -r '."ck-01"')
BUCKET=$(terraform output -json 2>/dev/null | jq -r '.backup_bucket_name.value // empty' 2>/dev/null)
# 若尚未输出 bucket_name，硬编码：
BUCKET=${BUCKET:-example-ck-backup-apne1}
TODAY=$(date -u +%Y-%m-%d)

CMD_ID=$(aws --profile default --region ap-northeast-1 ssm send-command \
  --document-name "zeelool-ck-run-backup" \
  --instance-ids "$CK01_ID" \
  --parameters "BucketName=${BUCKET},BackupType=full,BackupDate=${TODAY}" \
  --query 'Command.CommandId' --output text)

echo "CommandId=$CMD_ID"
aws --profile default --region ap-northeast-1 ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CK01_ID"

aws --profile default --region ap-northeast-1 ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$CK01_ID" \
  --query '{Status:Status,Out:StandardOutputContent,Err:StandardErrorContent}' --output json
```

Expected：`Status = Success`；`Out` 中包含 `table default.events_local not yet created (Phase 5 pending), skipping`——这是正确的占位行为，说明 backup Document 工作、只是业务表还没建（Phase 5 延后）。

- [ ] **Step 2：验证 S3 bucket 可写（对 events_local 之外的演练表）**

```bash
CMD_ID=$(aws --profile default --region ap-northeast-1 ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CK01_ID" \
  --parameters "commands=[\"clickhouse-client --query 'CREATE TABLE IF NOT EXISTS default.events_local (id UInt32) ENGINE = ReplicatedMergeTree(\\\"/clickhouse/tables/{shard}/events_local\\\", \\\"{replica}\\\") ORDER BY id'\",\"clickhouse-client --query \\\"BACKUP TABLE default.events_local TO S3('s3://${BUCKET}/full/${TODAY}-smoke/') SETTINGS compression_method='zstd'\\\"\"]" \
  --query 'Command.CommandId' --output text)

aws --profile default --region ap-northeast-1 ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CK01_ID"

aws --profile default --region ap-northeast-1 ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$CK01_ID" \
  --query '{Status:Status,Out:StandardOutputContent,Err:StandardErrorContent}' --output json

# 列出备份对象
aws --profile default --region ap-northeast-1 s3 ls "s3://${BUCKET}/full/${TODAY}-smoke/"
```

Expected：`s3 ls` 能列出若干 `.bin` / `metadata.json` 文件。验证 S3 权限、KMS、VPC Endpoint 全链路通。

- [ ] **Step 3：清理 smoke 备份（可选）**

```bash
aws --profile default --region ap-northeast-1 s3 rm "s3://${BUCKET}/full/${TODAY}-smoke/" --recursive
# 并删除演练表
CMD_ID=$(aws --profile default --region ap-northeast-1 ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CK01_ID" \
  --parameters 'commands=["clickhouse-client --query \"DROP TABLE IF EXISTS default.events_local ON CLUSTER zeelool_ck SYNC\""]' \
  --query 'Command.CommandId' --output text)
aws --profile default --region ap-northeast-1 ssm wait command-executed \
  --command-id "$CMD_ID" --instance-id "$CK01_ID"
```

- [ ] **Step 4：Commit 完结里程碑**

```bash
cd /root/keith-space
git commit --allow-empty -m "ops(zeelool-ck): first backup smoke test passed (Phase 6 done)"
```

---

## Task 21：交付物校验清单（总收官）

**Files:** 无；仅运行验收脚本。

- [ ] **Step 1：一键 smoke 检查所有核心组件**

把下面保存为 `scripts/smoke.sh`（先 `mkdir -p scripts`）：

```bash
#!/bin/bash
set -eo pipefail

cd "$(dirname "$0")/../terraform/envs/prod"

echo "=== 1. Terraform outputs ==="
terraform output

echo
echo "=== 2. SSM instances online ==="
INSTANCES=$(terraform output -json clickhouse_instance_ids | jq -r 'to_entries | map(.value) | join(",")'),$(terraform output -json keeper_instance_ids | jq -r 'to_entries | map(.value) | join(",")')
aws --profile default --region ap-northeast-1 ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${INSTANCES}" \
  --query 'InstanceInformationList[].{Id:InstanceId,Status:PingStatus,Name:ComputerName}' --output table

echo
echo "=== 3. Keeper quorum ==="
KEEPER01=$(terraform output -json keeper_instance_ids | jq -r '."keeper-01"')
CMD=$(aws --profile default --region ap-northeast-1 ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$KEEPER01" \
  --parameters 'commands=["echo mntr | nc -q 2 localhost 9181 | grep -E zk_server_state\\|zk_followers\\|zk_synced_followers"]' \
  --query 'Command.CommandId' --output text)
sleep 5
aws --profile default --region ap-northeast-1 ssm get-command-invocation \
  --command-id "$CMD" --instance-id "$KEEPER01" \
  --query 'StandardOutputContent' --output text

echo
echo "=== 4. CK replicas healthy ==="
CK01=$(terraform output -json clickhouse_instance_ids | jq -r '."ck-01"')
CMD=$(aws --profile default --region ap-northeast-1 ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$CK01" \
  --parameters 'commands=["clickhouse-client --query \"SELECT host_name, is_local FROM system.clusters WHERE cluster='"'"'zeelool_ck'"'"' FORMAT TSV\""]' \
  --query 'Command.CommandId' --output text)
sleep 5
aws --profile default --region ap-northeast-1 ssm get-command-invocation \
  --command-id "$CMD" --instance-id "$CK01" \
  --query 'StandardOutputContent' --output text

echo
echo "=== 5. NLB target health ==="
TG=$(aws --profile default --region ap-northeast-1 elbv2 describe-target-groups \
  --names zeelool-ck-nlb-9000 --query 'TargetGroups[0].TargetGroupArn' --output text)
aws --profile default --region ap-northeast-1 elbv2 describe-target-health \
  --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State}' --output table

echo
echo "=== 6. Backup S3 bucket ==="
aws --profile default --region ap-northeast-1 s3 ls s3://example-ck-backup-apne1/ || echo "(empty or first-run)"

echo
echo "=== 7. EventBridge rules ==="
aws --profile default --region ap-northeast-1 events list-rules \
  --name-prefix zeelool-ck \
  --query 'Rules[].{Name:Name,Schedule:ScheduleExpression,State:State}' --output table

echo
echo "All smoke checks done."
```

- [ ] **Step 2：运行 smoke 脚本**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse
chmod +x scripts/smoke.sh
./scripts/smoke.sh
```

Expected：
- SSM instances 全部 `Online`
- Keeper：`zk_server_state=leader` + `synced_followers=2`
- CK replicas：2 行，cluster=zeelool_ck
- NLB targets：`healthy × 2`
- S3 bucket 存在
- EventBridge：`zeelool-ck-backup-full` / `zeelool-ck-backup-incremental` 都是 `ENABLED`

- [ ] **Step 3：Commit smoke 脚本**

```bash
cd /root/keith-space
git add 2026-project/zeelool-clickhouse/scripts/
git commit -m "chore(zeelool-ck): smoke verification script"
```

- [ ] **Step 4：打 tag**

```bash
cd /root/keith-space
git tag -a zeelool-ck-mvp -m "Zeelool ClickHouse MVP cluster ready (spec v0.3, plan 2026-05-05)"
```

---

## 收尾

到此 **Phase 0 → 1 → 2 → 3 → 4 → 6** 全部落地，MVP 可用。**未做（明确延后）**：

| 延后章节 | 内容 | 触发条件 |
|---|---|---|
| Phase 5 | 业务表结构 DDL（`events_local` 等）| 埋点字段清单冻结后，作为独立 plan |
| Phase 5 | MSK Connect Connector 详细配置 | 同上 |
| Phase 7 | AMP + AMG 监控栈 + 8 条告警 + 5 篇 runbook | 上线流量前必须完成；作为独立 plan |
| SSM State Manager Associations（持续配置管理） | 把 `install-*` / `render-*` Document 升级为 State Manager Association，实现 drift 自动修复 | MVP 稳定运行后作为 post-MVP 补强 |

**关于 Provisioning 手段**：本 plan 用 **SSM Run Command（ad-hoc send-command）** 做首次部署——直接、可观察、幂等（所有 Document 都设计成重复执行安全）。Spec 里规划的 **SSM State Manager Associations** 是在此之上的增量：把同样的 Document 绑定到 Association，让 SSM 按计划/事件自动执行并检测 drift。MVP 落地阶段不急着加；集群稳态后再把 Association 接上，CloudFront/CloudTrail 审计全留痕。

下一步建议：在开始 Phase 5 或 Phase 7 之前，先让 MVP 集群运行 3-7 天，观察 Keeper 稳定性、副本同步延迟、EBS 使用增长，再进入业务表阶段。

---

## 附录 A：回滚与销毁

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform destroy
# 备份 bucket 含 object 时 destroy 失败，手工清空：
aws --profile default --region ap-northeast-1 s3 rm s3://example-ck-backup-apne1/ --recursive
aws --profile default --region ap-northeast-1 s3api delete-objects \
  --bucket example-ck-backup-apne1 \
  --delete "$(aws --profile default --region ap-northeast-1 s3api list-object-versions \
    --bucket example-ck-backup-apne1 \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)" 2>/dev/null || true
terraform destroy  # 再试一次
# 最后（可选）：手动删 tfstate bucket 与 DynamoDB lock 表
```

## 附录 B：常见故障快查

| 症状 | 排查 |
|---|---|
| SSM Document 一直 `InProgress` 不结束 | 查 `/var/log/amazon/ssm/amazon-ssm-agent.log`；NAT Gateway 是否通？ |
| Keeper `connection refused` | 三台 Keeper 私网 IP 是否都成功拿到静态 IP；SG 9234 是否放行 VPC CIDR |
| CK `ZooKeeper session expired` | `system.zookeeper_connection`；Keeper 多数派是否在线；时钟偏差 |
| NLB target 不 healthy | CK 8123 是否监听 0.0.0.0；`curl -s http://<ip>:8123/ping` 返回 `Ok.` |
| BACKUP SQL 超时 | 检查 VPC Gateway Endpoint for S3 的 Route Table 关联；IAM instance profile S3 权限 |

---

## 附录 C：EBS 数据盘在线扩容 runbook

gp3 卷的 size / IOPS / throughput 三项都可以在线修改（EC2 `ModifyVolume`），不需要 stop 实例或重启 CK。变量位置：
`terraform/modules/clickhouse-node/variables.tf` → `data_volume_gb` / `data_volume_iops` / `data_volume_throughput_mbps`。

默认是 gp3 baseline：3000 IOPS + 125 MB/s。对 5000万/日埋点写入 + 少量 BI 查询足够；如果 merge storm 时 I/O 等待变高（`iostat -x` 看 `%util > 80%`），再往上调 throughput。

gp3 限制（AWS 官方）：
- **Size**：1 GB - 16 TiB。只能扩，不能缩。
- **IOPS**：3000 - 16000。超过 32000 起另收费。
- **Throughput**：125 - 1000 MB/s。
- **冷却期**：每次 `ModifyVolume` 之后 6 小时内不能再改同一个卷的同一属性（AWS 硬限制）。

**扩容步骤（以 size 从 1500 → 2000 GB 为例）：**

- [ ] **Step 1：改 Terraform 变量**

```hcl
# terraform/modules/clickhouse-node/variables.tf
variable "data_volume_gb" {
  default = 2000   # was 1500
}
```

或者更干净：在 `terraform/envs/prod/main.tf` 的 `module "clickhouse"` 里显式传参，不改默认值：

```hcl
module "clickhouse" {
  # ...既有参数...
  data_volume_gb              = 2000
  data_volume_throughput_mbps = 250  # 如需同时提吞吐
}
```

- [ ] **Step 2：Terraform apply**

```bash
cd /root/keith-space/2026-project/zeelool-clickhouse/terraform/envs/prod
terraform plan -out=ebs-resize.tfplan
# plan 应该只显示 aws_ebs_volume.data 的 size/iops/throughput 属性变化，in-place update
terraform apply ebs-resize.tfplan
```

apply 完成只是触发了 `ModifyVolume` API。volume 进入 `optimizing` 状态，可以继续用，但新容量还没落到 OS。

- [ ] **Step 3：等 ModifyVolume 完成（一般 1-10 分钟，大卷最多几小时）**

```bash
for name in ck-01 ck-02; do
  vid=$(terraform output -json | jq -r ".clickhouse_instance_ids.value.\"${name}\"" \
    | xargs -I{} aws --region ap-northeast-1 ec2 describe-instances --instance-ids {} \
    --query 'Reservations[].Instances[].BlockDeviceMappings[?DeviceName==`/dev/sdf`].Ebs.VolumeId' --output text)
  echo "$name volume=$vid"
  aws --region ap-northeast-1 ec2 describe-volumes-modifications --volume-ids "$vid" \
    --query 'VolumesModifications[].{State:ModificationState,Progress:Progress}' --output table
done
```

`ModificationState` 到 `optimizing` 或 `completed` 就可以进下一步（`optimizing` 时新容量已对 OS 可见）。

- [ ] **Step 4：对每个 CK 节点跑 resize2fs（SSM Document）**

```bash
for name in ck-01 ck-02; do
  iid=$(terraform output -json clickhouse_instance_ids | jq -r --arg n "$name" '.[$n]')
  cmd=$(aws --region ap-northeast-1 ssm send-command \
    --document-name "zeelool-ck-resize-data-volume" \
    --instance-ids "$iid" \
    --query 'Command.CommandId' --output text)
  aws --region ap-northeast-1 ssm wait command-executed --command-id "$cmd" --instance-id "$iid"
  aws --region ap-northeast-1 ssm get-command-invocation \
    --command-id "$cmd" --instance-id "$iid" --query 'StandardOutputContent' --output text
done
```

Expected：输出里 `After: df -h` 显示新容量。CK 自己通过 `statfs()` 感知磁盘大小，不需要重启 `clickhouse-server`。

- [ ] **Step 5：可选 —— 更新 smoke test 或 dashboard 的容量基线。**

**缩容不支持。** 如果真要缩（业务下线/数据归档），只能新建小卷 → `attach` 到新的挂载点 → rsync 数据 → 切换 fstab → detach 大卷。 不在此 runbook 范围。
