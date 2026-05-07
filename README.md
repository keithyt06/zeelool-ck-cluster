# ClickHouse Cluster on AWS (Graviton4)

Terraform + SSM 打造的自管 ClickHouse 集群：**1 shard × 2 replica CK + 3 Keeper（默认 2 AZ、2+1 Keeper 分布）+ 内部 NLB + S3 备份（EventBridge 调度）**。基于 AWS Graviton 8g，支持一键切换 region / VPC / 子网 / 机型。无 Route53 依赖 —— 客户端直连 NLB DNS。

> **2-AZ 故障语义（重要）**：放 2 个 Keeper 的那个 AZ（默认 az1a）挂了，quorum 破（1/3），集群变 read-only 直到 AZ 恢复；放 1 个 Keeper 的 AZ 挂了业务无感。要"任意 AZ 可挂"的对称容错，tfvars 里改 3 AZ 分布。

## 文档入口

| 看这份 | 做什么 |
|---|---|
| [docs/CUSTOMER-ONBOARDING.md](docs/CUSTOMER-ONBOARDING.md) | **客户部署必读**。从空账户到生产集群的 6 步 runbook |
| [docs/superpowers/specs/2026-05-04-zeelool-clickhouse-design.md](docs/superpowers/specs/2026-05-04-zeelool-clickhouse-design.md) | 架构设计：拓扑、HA 策略、容量估算、成本建模 |
| [docs/superpowers/plans/2026-05-05-zeelool-clickhouse-mvp.md](docs/superpowers/plans/2026-05-05-zeelool-clickhouse-mvp.md) | 详细实施计划 + 运维红线（顶部）+ **附录 C EBS 扩容 runbook** |

## 从零部署（完整流程见 CUSTOMER-ONBOARDING.md）

**前置（一次性手工）**：在目标 region 建好 VPC + **最少 2 个私有子网**（默认 2-AZ 布局；要 3-AZ 对称容错就建 3 个）。**不再需要手工建 state bucket / 锁表** —— 下一步 `terraform/bootstrap/` 自动创。

```bash
export AWS_PROFILE=default

# 1. Bootstrap state backend（S3 + DynamoDB，首次唯一一次）
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars    # 默认值 OK，不改也行
terraform init
terraform apply
terraform output -raw backend_hcl > ../envs/prod/backend.hcl   # 喂给主栈

# 2. 主栈 tfvars
cd ../envs/prod
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars                                      # 填 vpc_id / private_subnet_ids

# 3. 部署基础设施（~5 分钟）
terraform init -backend-config=backend.hcl
terraform plan -out=p.plan
terraform apply p.plan

# 4. 一条命令装完 Keeper + CK 二进制、渲染配置、生成密码、跑 smoke
cd ../..
./scripts/bootstrap-post-apply.sh
```

`bootstrap-post-apply.sh` 7 步全程幂等，中断可重跑。完成后集群即可接受 `clickhouse-client` 连接（VPC 内）。

## 目录结构

```
terraform/
├── backend.tf                # 顶层 terraform block（provider version pin，legacy）
├── bootstrap/                # 一次性创 state S3 bucket + DynamoDB lock 表（local state）
│   ├── main.tf               # S3 + DDB 资源
│   ├── variables.tf          # 可覆盖 bucket/table 名
│   ├── outputs.tf            # backend_hcl output 直接喂给 envs/prod
│   ├── provider.tf           # 无 backend 块（local state）
│   ├── terraform.tfvars      # gitignored
│   └── terraform.tfvars.example
├── envs/prod/
│   ├── main.tf               # 顶层 composition（数据源发现 + 模块编排）
│   ├── variables.tf          # 客户可覆盖变量，每个都有说明
│   ├── outputs.tf            # cluster_info 聚合输出，脚本由此拿拓扑
│   ├── provider.tf           # AWS provider + partial S3 backend（看 backend.hcl）
│   ├── backend.hcl           # 实际 backend 参数（git ignored）
│   ├── backend.hcl.example   # 模板
│   ├── terraform.tfvars      # 实际部署的值（git ignored）
│   └── terraform.tfvars.example  # 给客户的模板
└── modules/
    ├── network/              # VPC 发现 + 3 个 SG（SG 引用，非 CIDR）+ S3 gateway endpoint
    ├── iam/                  # 拆开的 keeper + 数据节点 role（Keeper 没 S3 写权）
    ├── ssm-documents/        # 注册 7 个 SSM Documents
    ├── keeper-node/          # Keeper EC2 + root EBS
    ├── clickhouse-node/      # CK EC2 + root EBS + 数据 EBS（带 prevent_destroy）
    ├── nlb/                  # 内网 NLB + 9000/8123 TG（无 Route53，直连 NLB DNS）
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
- AZ 数（**最少 2 AZ**） + AZ 名（从 subnet 数据源反查）
- Keeper / CK 节点分布（哪个 AZ 放几台，通过 `keeper_placement` / `clickhouse_placement` 决定）
- 节点数 / 实例类型 / 私网 IP（自动 `cidrhost` 推或显式覆盖；同子网多节点会自动按索引偏移，不撞 IP）
- 命名前缀 / Owner / Environment / 标签
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
4. **`AWS_PROFILE` 环境变量优先级** —— backend 没硬编码 profile，`AWS_PROFILE=cc` 等环境变量会压过意图。deploy 前务必 `export AWS_PROFILE=default`（或直接 `AWS_PROFILE=default terraform apply`），否则 403 Forbidden 访问 state bucket。
5. **2-AZ Keeper 分布是 asymmetric FT** —— 默认配置里 2 个 Keeper 放在同一个 AZ（省 AZ 数量），这个 AZ 挂了 quorum 直接破。对外说集群 SLA 时按"主 AZ 为单点"算。真要"任意 AZ 可挂"，tfvars 里把 keeper_placement 改成 3 AZ 各 1 台，同时 `private_subnet_ids` 也补成 3 个。

## 部署快速通道（profile=default，东京）

```bash
# 环境变量先于 terraform/scripts 生效 —— 不 export 的话，shell 里其他 profile 会抢
export AWS_PROFILE=default

# 首次唯一：创 state backend（S3 bucket + DynamoDB lock 表）
cd terraform/bootstrap
terraform init
terraform apply -auto-approve
terraform output -raw backend_hcl > ../envs/prod/backend.hcl

# 主栈
cd ../envs/prod
terraform init -backend-config=backend.hcl    # 首次需要 -backend-config，之后 plain terraform
terraform plan -out=p.plan
terraform apply p.plan

cd ../..
ACK_PASSWORD_SAVED=1 ./scripts/bootstrap-post-apply.sh  # 非交互跳过 press-Enter
./scripts/smoke.sh
```

bootstrap 第一次会生成 32 字符密码并存 SSM Parameter Store `/<name_prefix>/default-user-password`。脚本会把密码 echo 到 stdout —— **此时必须从终端或日志里抓走存进密码库**，否则以后要用 `aws ssm get-parameter --with-decryption` 才拿得回。

## 客户端连接

集群没 Route53 private zone，客户端直连 NLB DNS：

```bash
# region 和 name_prefix 都从 terraform 输出读，不硬编码 —— 换 region 也 work
REGION=$(terraform -chdir=terraform/envs/prod output -raw region)
NAME_PREFIX=$(terraform -chdir=terraform/envs/prod output -raw name_prefix)
NLB=$(terraform -chdir=terraform/envs/prod output -raw clickhouse_nlb_dns)
PASS=$(aws --region "$REGION" ssm get-parameter \
  --name "/${NAME_PREFIX}/default-user-password" --with-decryption \
  --query Parameter.Value --output text)

# Native TCP 9000（VPC 内）
clickhouse-client --host "$NLB" --user default --password "$PASS" --query 'SELECT 1'

# HTTP 8123
curl -u "default:$PASS" "http://${NLB}:8123/?query=SELECT+1"
```

要漂亮别名（比如 `ck.acme.com`）？在你自己的 DNS 系统里加 CNAME 指到 `$NLB` 即可 —— 模块输出 `nlb_zone_id` 方便你在本地 Route53 建 alias record。
