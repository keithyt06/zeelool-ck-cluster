# ClickHouse Cluster on AWS (Graviton4)

Terraform + SSM 打造的自管 ClickHouse 集群：**1 shard × 2 replica CK + 3 Keeper（跨 3 AZ）+ 内部 NLB + S3 备份（EventBridge 调度）**。基于 AWS Graviton 8g，支持一键切换 region / VPC / 子网 / 机型。

## 文档入口

| 看这份 | 做什么 |
|---|---|
| [docs/CUSTOMER-ONBOARDING.md](docs/CUSTOMER-ONBOARDING.md) | **客户部署必读**。从空账户到生产集群的 6 步 runbook |
| [docs/superpowers/specs/2026-05-04-zeelool-clickhouse-design.md](docs/superpowers/specs/2026-05-04-zeelool-clickhouse-design.md) | 架构设计：拓扑、HA 策略、容量估算、成本建模 |
| [docs/superpowers/plans/2026-05-05-zeelool-clickhouse-mvp.md](docs/superpowers/plans/2026-05-05-zeelool-clickhouse-mvp.md) | 详细实施计划 + 运维红线（顶部）+ **附录 C EBS 扩容 runbook** |

## 从零部署（完整流程见 CUSTOMER-ONBOARDING.md）

**前置（一次性）**：在目标 region 建好 VPC + 3 个私有子网 + Terraform state bucket + DynamoDB 锁表，改 `provider.tf` backend 块。

```bash
# 1. 填 tfvars（必填 vpc_id / private_subnet_ids / name_prefix 等）
cd terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. 部署基础设施（~5 分钟）
terraform init
terraform plan -out=p.plan
terraform apply p.plan

# 3. 一条命令装完 Keeper + CK 二进制、渲染配置、生成密码、跑 smoke
cd ..
./scripts/bootstrap-post-apply.sh
```

`bootstrap-post-apply.sh` 7 步全程幂等，中断可重跑。完成后集群即可接受 `clickhouse-client` 连接（VPC 内）。

## 目录结构

```
terraform/
├── backend.tf                # provider / terraform block（state 在 envs/prod/provider.tf）
├── envs/prod/
│   ├── main.tf               # 顶层 composition（数据源发现 + 模块编排）
│   ├── variables.tf          # 客户可覆盖变量，每个都有说明
│   ├── outputs.tf            # cluster_info 聚合输出，脚本由此拿拓扑
│   ├── provider.tf           # AWS provider + S3 state backend
│   ├── terraform.tfvars      # 实际部署的值（git ignored）
│   └── terraform.tfvars.example  # 给客户的模板
└── modules/
    ├── network/              # VPC 发现 + 3 个 SG（SG 引用，非 CIDR）+ S3 gateway endpoint
    ├── iam/                  # 拆开的 keeper + 数据节点 role（Keeper 没 S3 写权）
    ├── ssm-documents/        # 注册 7 个 SSM Documents
    ├── keeper-node/          # Keeper EC2 + root EBS
    ├── clickhouse-node/      # CK EC2 + root EBS + 数据 EBS（带 prevent_destroy）
    ├── nlb/                  # 内网 NLB + 9000/8123 TG + Route53 private zone A record
    └── backup-s3/            # S3 bucket + lifecycle + EventBridge schedule

ssm-documents/                # 实际 SSM Document YAML（被 modules/ssm-documents 读取注册）
├── install-keeper.yml
├── install-clickhouse.yml
├── render-keeper-config.yml
├── render-clickhouse-config.yml
├── bootstrap-schema.yml
├── run-backup.yml
└── resize-data-volume.yml

config/                       # ClickHouse / Keeper 配置的 Terraform 模板（.tftpl）
├── clickhouse/config.d/
├── clickhouse/users.d/
└── keeper/

scripts/
├── bootstrap-post-apply.sh         # 一条命令 install+render+smoke 全流程
├── render-and-push-keeper-config.sh  # 渲染 keeper_config.xml + SSM 下发
├── render-and-push-ck-config.sh    # 渲染 CK 配置 + SSM 下发
├── install-ssh-public-key.sh       # SSM 推公钥到节点（PEM 路径为 CLI 参数，不入库）
├── smoke.sh                        # 部署后验证
└── teardown.sh                     # 安全拆除（引导摘 prevent_destroy）
```

## 可移植性承诺

以下参数**全部 tfvars 里改，不改模块代码**：

- AWS region（包括 `provider.tf` backend 的 region，手改一次）
- VPC ID + VPC CIDR（CIDR 自动 `data.aws_vpc` 发现）
- 子网（只要 ID 对，CIDR 是什么都行 — 10.0 / 172.16 / 192.168）
- AZ 数 + AZ 名（从 subnet 数据源反查）
- 节点数 / 实例类型 / 私网 IP（自动 `cidrhost` 推或显式覆盖）
- 命名前缀 / Owner / Environment / 标签
- 私有 Hosted Zone 名
- SSH KeyPair 名（PEM 文件永远在 repo 外）
- 备份 bucket 名（默认 `<prefix>-backup-<account>-<region>` 避免全局冲突）
- 备份调度 cron / 保留天数
- 数据盘 size / IOPS / throughput

**硬编码只剩 3 处**（技术限制无解）：
1. `provider.tf` 里 backend S3 bucket 名 —— Terraform 不允许 backend 用变量
2. `install-keeper.yml` / `install-clickhouse.yml` 里 `clickhouse-lts` 仓库版本号 —— 改版本时手工 SSM 参数覆盖
3. Instance AMI：通过 AWS 维护的 SSM Public Parameter 自动解析 AL2023 ARM64，**region-agnostic**

## 运维红线

1. **EBS ModifyVolume 6h 冷却** —— size/IOPS/throughput 要一起改的**同一次 apply** 提交
2. **`default` 用户禁空密码** —— 部署流程由 `bootstrap-post-apply.sh` 强制生成并存 SSM SecureString
3. **销毁走 `scripts/teardown.sh`**，别直接 `terraform destroy`（`prevent_destroy` 会挡）
