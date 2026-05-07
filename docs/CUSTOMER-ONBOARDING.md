# 客户部署手册 — 从零到生产

这套 ClickHouse 集群可以部署到**任意 AWS Region / VPC / 子网**，不需要改模块代码。只改 `terraform/envs/prod/terraform.tfvars` 就够了。

本手册从**空账户**走到**可以写入查询的 CK 集群 + 自动备份**，一共 6 步，**命令可复制执行**。预计 30-40 分钟（大部分时间在等 Terraform 和 SSM）。

---

## 所需权限与工具

**机器上装好：**
- `terraform` ≥ 1.8
- `aws` CLI v2
- `jq`
- `openssl`, `ssh-keygen`（一般系统自带）

**AWS 凭据**：`aws sts get-caller-identity` 能跑通。需要至少 EC2 / IAM / SSM / S3 / EventBridge / ELBv2 / DynamoDB 的读写权限。（**不需要 Route53 权限** —— v2 拓扑已去掉 private hosted zone，客户端直连 NLB DNS。）

---

## Step 0：前置资源（AWS Console / CLI 手工）

只这一步有手工，之后全自动。

### 0.1 VPC + 私有子网

目标 Region 里要已有：

- [ ] 一个 VPC（**任意 CIDR**：10.0/8 / 172.16/12 / 192.168/16 都行）
- [ ] **最少 2 个私有子网**（默认 2-AZ 布局 —— 2+1 Keeper 分布在 az1a/az1c）
  - 想要"任意 AZ 可挂"对称容错？准备 **3 个不同 AZ 的子网**，并在 tfvars 里把 `keeper_placement` 改成 3 AZ 各 1 台
- [ ] 每个子网要能访问 SSM（二选一）：
  - **A.** 子网有 NAT Gateway 出网
  - **B.** VPC 里有 SSM interface endpoints（`com.amazonaws.<region>.ssm` / `ssmmessages` / `ec2messages`）—— 更安全，也省 NAT 费

确认命令：
```bash
aws --region <region> ec2 describe-subnets \
  --filters Name=vpc-id,Values=<vpc-id> \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```
记下 2（或 3）个子网 ID 和它们的 AZ。

> **2-AZ 故障容忍说明**：默认 `keeper_placement` 把 2 个 Keeper 放在字典序小的 AZ（比如 az1a），1 个放在另一个 AZ（az1c）。挂 az1c 业务无感；**挂 az1a 会让 Keeper quorum 破，集群变 read-only**。对客户明确这点，再让他们签名。

### 0.2 Terraform state backend（S3 + DynamoDB）

Terraform 状态文件要存远端。**只需建一次，后续所有部署复用**。

```bash
# 填你的值
export R=<region>                      # e.g. ap-southeast-1
export B=<customer>-ck-tfstate         # 全局唯一的 bucket 名
export D=<customer>-ck-tflock          # DynamoDB 锁表名

aws --region $R s3api create-bucket --bucket $B \
  --create-bucket-configuration LocationConstraint=$R
aws --region $R s3api put-bucket-versioning --bucket $B \
  --versioning-configuration Status=Enabled
aws --region $R s3api put-bucket-encryption --bucket $B \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws --region $R s3api put-public-access-block --bucket $B \
  --public-access-block-configuration \
  'BlockPublicAcls=true,BlockPublicPolicy=true,IgnorePublicAcls=true,RestrictPublicBuckets=true'

aws --region $R dynamodb create-table --table-name $D \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

然后**改一次** `terraform/envs/prod/provider.tf` 的 backend 块：

```hcl
backend "s3" {
  bucket         = "<customer>-ck-tfstate"   # ← 改
  key            = "envs/prod/terraform.tfstate"
  region         = "<region>"                # ← 改
  dynamodb_table = "<customer>-ck-tflock"    # ← 改
  encrypt        = true
}
```

> **为什么这一处不能变量化：** Terraform 不允许 backend 配置引用 `var.*`，AWS-wide 限制。

### 0.3 （可选）EC2 KeyPair

想 SSH 进节点调试就建一个：
```bash
aws --region $R ec2 create-key-pair --key-name <customer>-ck-keypair \
  --query 'KeyMaterial' --output text > ~/.ssh/<customer>-ck-keypair.pem
chmod 600 ~/.ssh/<customer>-ck-keypair.pem
```
把 `.pem` 存进客户自己的密码库。**不要**提交到 repo。

不建也行 —— 运维可以走 SSM Session Manager 进节点，更安全。

---

## Step 1：填 tfvars

```bash
cd terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

**必填项：**

```hcl
# 目标 region
region = "ap-southeast-1"

# VPC + 子网（Step 0.1 记下的）—— 默认 2 AZ 部署
vpc_id = "vpc-0xxxxxxxxxxxxxxxx"
private_subnet_ids = {
  "az1a" = "subnet-0xxxxxxxxxxxxxxxx"   # 字典序小的 AZ（默认放 2 Keepers + 1 CK）
  "az1c" = "subnet-0xxxxxxxxxxxxxxxx"   # 另一个 AZ（默认放 1 Keeper + 1 CK）
}

# 命名（IAM role / SG / S3 bucket 全局作用域，换成客户代号避免冲突）
name_prefix   = "acme-ck"
cluster_name  = "acme_ck"           # 不能含 '-' (ClickHouse 限制)
owner         = "data-platform"
environment   = "prod"
```

> **要 3-AZ 对称容错**，追加：
>
> ```hcl
> private_subnet_ids = {
>   "az1a" = "subnet-xxx"
>   "az1c" = "subnet-yyy"
>   "az1d" = "subnet-zzz"
> }
> keeper_placement = {
>   "keeper-01" = { subnet_key = "az1a", server_id = 1 }
>   "keeper-02" = { subnet_key = "az1c", server_id = 2 }
>   "keeper-03" = { subnet_key = "az1d", server_id = 3 }
> }
> ```

**强烈建议项：**

```hcl
# 机型（见 terraform.tfvars.example 详细注释）
clickhouse_instance_type = "r8g.large"    # MVP 成本优先；中规模用 r8g.xlarge

# 数据盘（后续可在线扩，不担心选小了）
clickhouse_data_volume_gb = 1500

# SSH 访问（Step 0.3 创建的 KeyPair 名字，不是 .pem 路径）
ssh_key_name = "acme-ck-keypair"
```

其他变量全都有合理默认值，可按需覆盖。完整清单见 `terraform/envs/prod/variables.tf`。

---

## Step 2：Terraform 部署

```bash
cd terraform/envs/prod
terraform init                # 连接 Step 0.2 的 state backend
terraform plan -out=p.plan
terraform apply p.plan
```

**预期 plan**：~50 个新资源，~5 分钟完成。

创建：
- 3 × IAM role（Keeper、CK 数据节点、EventBridge 各独立）+ instance profile
- 3 × Security Group + 10 多条 ingress/egress rule
- 1 × S3 Gateway Endpoint
- 3 × Keeper EC2 + root EBS
- 2 × CK EC2 + root EBS + **1500 GB 数据 EBS**（带 `prevent_destroy`）
- 1 × 内网 NLB + 2 × target group + listeners（**无 Route53**，客户端直连 NLB DNS）
- 1 × S3 备份 bucket（SSE-S3 / versioning / public-access-block / lifecycle）
- 2 × EventBridge rule（每日 incremental / 每周 full） + 2 × target
- 7 × SSM Document（install-keeper / install-clickhouse / render-keeper-config / render-clickhouse-config / bootstrap-schema / run-backup / resize-data-volume）

此时 5 台 EC2 在跑，但**还只是 AL2023 空壳**，CK/Keeper 二进制还没装。下一步装。

---

## Step 3：Bootstrap —— 一条命令装完所有东西

```bash
cd ..                         # 回到项目根
./scripts/bootstrap-post-apply.sh
```

这个脚本按顺序做 7 件事，**全程幂等**，中断再跑也没事：

| # | 动作 | 手段 |
|---|---|---|
| 1 | 装 Keeper 二进制 | SSM `<prefix>-install-keeper` 打到 3 台 keeper |
| 2 | 渲染 + 下发 keeper_config.xml | `scripts/render-and-push-keeper-config.sh` |
| 3 | 等 Keeper quorum 成形 | 循环 ping `zk_server_state`，leader/follower 都算通过 |
| 4 | 装 ClickHouse 二进制 | SSM `<prefix>-install-clickhouse` 打到 2 台 CK |
| 5 | 创建 default 用户密码（首次） | 存 SSM Parameter Store SecureString，脚本打印密码让你记进密码库 |
| 6 | 渲染 + 下发 CK 配置 | `scripts/render-and-push-ck-config.sh` |
| 7 | 最终 smoke test | `scripts/smoke.sh` |

**首次运行时**脚本会在第 5 步停下，打印生成的密码并让你按 Enter 确认已存到密码库。**这是整个流程里唯一需要人眼介入的地方。**

密码之后也能随时读回：
```bash
aws --region <region> ssm get-parameter \
  --name "/<name_prefix>/default-user-password" \
  --with-decryption --query 'Parameter.Value' --output text
```

---

## Step 4：验证

```bash
./scripts/smoke.sh
```

过 7 项检查：
1. SSM 看到所有 5 台节点 `Online`
2. Keeper quorum（leader + followers）
3. CK 两节点互见（`system.clusters` 查询）
4. NLB target health（9000 + 8123 都 `healthy`）
5. 备份 bucket 存在
6. EventBridge rules `ENABLED`
7. SQL 基础连通（通过 SSM 跑 `SELECT 1`）

VPC 内可直接连 CK（通过 NLB DNS）：
```bash
# 从 VPC 内的任意 EC2 / Lambda
NLB=$(terraform -chdir=terraform/envs/prod output -raw clickhouse_nlb_dns)
PASS=$(aws --region <region> ssm get-parameter \
  --name "/<name_prefix>/default-user-password" \
  --with-decryption --query 'Parameter.Value' --output text)

clickhouse-client --host "$NLB" --user default --password "$PASS" \
  --query 'SELECT version(), uptime()'

# HTTP 亦可：
# curl -u "default:$PASS" "http://${NLB}:8123/?query=SELECT+1"
```

> 想要漂亮别名（`ck.acme.com`）？在你自己的 DNS 系统里加一条 CNAME 指向 `$NLB`。需要 Route53 alias record 可用 `terraform output nlb_zone_id` 拿 canonical zone id。

---

## Step 5：首次备份（可选，EventBridge 到点会自动跑）

如果不想等到第一次 cron 触发，手动跑一次验证备份链路：

```bash
cd terraform/envs/prod
INFO=$(terraform output -no-color -json cluster_info 2>/dev/null \
  | awk '/^{/{p=1} p{print} /^}$/{exit}')

REGION=$(jq -r '.region' <<<"$INFO")
DOC=$(jq -r '.ssm_docs.run_backup' <<<"$INFO")
CK01=$(jq -r '.clickhouses | to_entries | sort_by(.key) | .[0].value.instance_id' <<<"$INFO")
BUCKET=$(jq -r '.backup' <<<"$INFO")

aws --region "$REGION" ssm send-command \
  --document-name "$DOC" \
  --instance-ids "$CK01" \
  --parameters "BucketName=$BUCKET,BackupType=full,BackupDate=$(date -u +%Y-%m-%d)"
```

几分钟后 `aws s3 ls s3://$BUCKET/full/ --recursive` 应该看到备份文件。

（没有数据也会成功，因为我们 BACKUP 的目标 table 默认 `default.events_local`，表不存在时 SSM doc 会跳过。有表以后自动生效）

---

## 之后的运维

| 场景 | 命令 / 文档 |
|---|---|
| 加索引 / 建表 | 用 `<prefix>-bootstrap-schema` SSM doc 传 `DdlSqlB64` |
| 扩容数据盘（size / IOPS / throughput） | 见 `docs/superpowers/plans/2026-05-05-zeelool-clickhouse-mvp.md` **附录 C** |
| 给已部署节点补 SSH 公钥（没在 Step 0.3 建 KeyPair 或想加别人的 key） | `./scripts/install-ssh-public-key.sh /path/to/your.pem` |
| 升 ClickHouse 版本 | 改 SSM doc 里的 `ClickHouseVersion` 参数，重跑 `<prefix>-install-clickhouse` |
| 改 default 用户密码 | 更新 SSM Parameter Store，重跑 `./scripts/render-and-push-ck-config.sh` |
| 轮转 / 加新的运维 SSH key | 重跑 `install-ssh-public-key.sh /path/to/new.pem` |
| 销毁整套 | `./scripts/teardown.sh`（**不要**直接 `terraform destroy`，会被 `prevent_destroy` 挡） |

---

## 常见失败速查

| 症状 | 原因 | 解法 |
|---|---|---|
| `terraform init`/`apply` 访问 state bucket 403 Forbidden | shell 里 `AWS_PROFILE=xxx` 压过意图（backend 不硬编码 profile） | `export AWS_PROFILE=default` 或每条命令前缀 `AWS_PROFILE=default ...` |
| `terraform apply` 报 **InvalidPermission.Duplicate** 5 条 CIDR SG rule | 旧 inline rules 在 AWS 里但不在新 state（refactor 遗留） | `terraform import` 5 条到新资源 `aws_vpc_security_group_*_rule.*` 后 re-apply；已被新 SG-ref rules 覆盖的旧 CIDR rules 可 `aws ec2 revoke-security-group-ingress` 清理 |
| `terraform plan` 报 `unsupported attribute "region"` on 现有 state | provider pin 低于 v6（state 由 v6 写入） | `provider.tf` `version = "~> 6.0"` + `terraform init -upgrade` |
| `terraform apply` 报 `InvalidSubnet` / `AvailabilityZoneMismatch` | `subnet_key` 拼错或 VPC 不匹配 | 对齐 `private_subnet_ids` 的 key 和 `keeper_placement.subnet_key` |
| `terraform apply` 报 bucket 名冲突 | `name_prefix` 撞到同账号其他项目 | 换 `name_prefix` 或显式指定 `backup_bucket_name` |
| EC2 `Pending` 几分钟不进 `Running` | 子网无出网 | NAT 或 SSM interface endpoints 二选一（Step 0.1） |
| bootstrap 脚本报 `jq: parse error` | `terraform output -json` 后跟 deprecation warning 被脚本读入 | 已修：所有脚本用 `sed '/^$/,$d'` 替代 awk。本仓库已更新，fork 老版需同步 |
| bootstrap 第 1/4 步失败（install SSM） | SSM Agent 还没上线 / VPC 不通 | 等 60-90 秒重跑；检查 `/var/log/amazon/ssm/*.log` |
| bootstrap 第 3 步 "quorum did not form" 但 keeper 日志健康 | Keeper `mntr` 输出用 TAB 分隔，旧脚本匹配 `=` | 已修：case 模式 `*zk_server_state*leader*\|*zk_server_state*follower*` |
| bootstrap 第 3 步 "quorum did not form" 且 keeper 真的没起 | Keeper SG 没放行自引用 9234 | 查 `<prefix>-keeper` SG 的 ingress 规则 |
| bootstrap 第 6 步 render-clickhouse-config 失败，journalctl 显示 `CANNOT_LOAD_CONFIG parseUser`+`More than one field of 'password'...` | `users.d/default-user` 缺 `replace="1"` → 基础 users.xml 的空 `<password>` + 新加 `<password_sha256_hex>` 同时被识别为 auth 字段 | 已修：模板加 `<default replace="1">` |
| bootstrap 第 6 步 render stderr `AUTHENTICATION_FAILED` | SSM Document 最后一步 `clickhouse-client SELECT 1` 不带密码 | 已修：改为 `curl http://127.0.0.1:8123/ping`（无需 auth） |
| smoke.sh §4 "CK replicas healthy" 输出空 | smoke 用 unauth 的 `clickhouse-client` | 已修：从 SSM Parameter Store 拉密码注入 |
| NLB target `unhealthy` | CK 配置没下发（卡在 bootstrap 第 6 步前） | 把 bootstrap 跑完再看 |
| BACKUP 报 `AccessDenied` | S3 gateway endpoint 没关联 CK 子网的路由表 | 模块自动处理；手动检查 `aws ec2 describe-vpc-endpoints` |
| `ModifyVolume` 报 `VolumeModificationRateExceeded` | 撞到 6 小时冷却期 | 等，或拼一次把 size/IOPS/throughput 一次提交 |

---

## 变量完整索引

`terraform/envs/prod/variables.tf` 里每个变量都有 `description`。快速查看：

```bash
cd terraform/envs/prod
grep -E '^variable |^  description' variables.tf | sed 'N;s/\n/ —/'
```

或 `terraform console` 里 `var.<name>` 看默认值。
