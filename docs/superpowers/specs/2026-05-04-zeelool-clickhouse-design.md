# Zeelool ClickHouse 集群设计方案

- 文档版本：v0.1
- 创建日期：2026-05-04
- 作者：Keith（AWS SA）
- 状态：Draft — 待实施计划

---

## 1. 背景与目标

Zeelool 需要一套生产级 ClickHouse 集群承载埋点数据的写入与业务查询。当前阶段以**成本优先**为第一约束，同时满足跨 AZ 高可用、基于 AWS Graviton 8g 的存算一体集群部署要求。

### 1.1 业务输入

| 维度 | 值 |
|---|---|
| 写入规模 | 每日 5000 万行（均值 ~580 行/秒，峰值估 5k-10k 行/秒） |
| 保留周期 | 90 天 |
| 查询模式 | 中后台报表 / BI，QPS < 10，P95 允许 3-10s |
| 高可用粒度 | 跨 2 AZ 副本（抗单 AZ 故障） |
| 写入链路 | MSK + MSK Connect（clickhouse-kafka-connect） |
| 平台 | AWS ap-northeast-1（东京），EC2 自建，Graviton 8g 系列 |
| 首要优先级 | **成本优先** |

### 1.2 非目标（本期不做）

- 跨 Region 灾备（RPO/RTO 仅在单 Region 内保证）
- C 端实时对外查询（P95 < 200ms 的高并发场景）
- 数据模型与埋点 schema 细化（§ 6 TODO）
- 监控告警栈落地（§ 9 TODO）
- 数据湖/数仓与 CK 的联邦查询

---

## 2. 架构总览

### 2.1 物理拓扑

```
                ap-northeast-1（东京）
                VPC: vpc-XXXXXXXXXXXXXXXXX

  ┌────────────────┬────────────────┬────────────────┐
  │    AZ 1a       │    AZ 1c       │    AZ 1d       │
  │  private1      │  private2      │  private3      │
  │  10.0.11.0/24  │  10.0.12.0/24  │  10.0.13.0/24  │
  │                │                │                │
  │  ck-01         │  ck-02         │  (无 CK)       │
  │  r8g.xlarge    │  r8g.xlarge    │                │
  │  shard1/rep1   │  shard1/rep2   │                │
  │                │                │                │
  │  keeper-01     │  keeper-02     │  keeper-03     │
  │  t4g.small     │  t4g.small     │  t4g.small     │
  └────┬───────────┴────┬───────────┴────┬───────────┘
       │                │                │
       └─ Raft 仲裁 ────┴────────────────┘

  客户端 → NLB（internal，跨 3 AZ private 子网）→ ck-01 / ck-02
  MSK    → MSK Connect（clickhouse-kafka-connect）→ NLB → CK
```

### 2.2 节点清单（prod）

| 角色 | 实例 | 数量 | 规格 | AZ / 子网 | 存储 |
|---|---|---|---|---|---|
| CK 数据节点 ck-01 | `r8g.xlarge` | 1 | 4 vCPU / 32 GB | 1a / `subnet-XXXXXXXXXXXXXXXXX` | gp3 50 GB 根 + gp3 **1500 GB** 数据 |
| CK 数据节点 ck-02 | `r8g.xlarge` | 1 | 4 vCPU / 32 GB | 1c / `subnet-YYYYYYYYYYYYYYYYY` | gp3 50 GB 根 + gp3 **1500 GB** 数据 |
| Keeper-01 | `t4g.small` | 1 | 2 vCPU / 2 GB | 1a / `subnet-XXXXXXXXXXXXXXXXX` | gp3 50 GB |
| Keeper-02 | `t4g.small` | 1 | 2 vCPU / 2 GB | 1c / `subnet-YYYYYYYYYYYYYYYYY` | gp3 50 GB |
| Keeper-03 | `t4g.small` | 1 | 2 vCPU / 2 GB | 1d / `subnet-ZZZZZZZZZZZZZZZZZ` | gp3 50 GB |
| NLB（internal） | — | 1 | — | 跨 3 私有子网 | — |

本期仅部署 prod 环境，不建独立 dev。

---

## 3. 关键技术决策与取舍

| 决策 | 选择 | 取舍理由 |
|---|---|---|
| 集群拓扑 | 1 shard × 2 replica | 5000 万行/日对 CK 很小，单分片够用；成本最低；未来加分片平滑 |
| 副本位置 | CK 跨 AZ 1a / 1c | 抗 AZ 故障的最小布局；2 AZ 即可 |
| Keeper 数量 | 3 节点独立部署 | Raft 多数派；混部会让 CK 合并抢占 Keeper IO |
| Keeper 位置 | 跨 3 AZ（1a / 1c / 1d） | 2 AZ 无法保证 AZ 故障时仲裁存活；这是 Keeper 必须 3 AZ 的根因 |
| 实例族 | CK 用 `r8g.xlarge`，Keeper 用 `t4g.small` | CK 大 scan 对内存敏感（8:1 内存/CPU）；Keeper 负载极低 |
| 存储 | gp3（根 50GB + 数据 1500GB） | IOPS/吞吐基线足够；无需 io2；1.5 TB 预留 3-5 年容量增长 |
| 文件系统 | ext4，挂载参数 `defaults,noatime,nodiratime` | CK 官方推荐；关 atime 减写放大 |
| 数据分层 | 全本地 SSD，不接 S3 冷分层 | 用户要求存算一体；90 天数据量小，本地够 |
| CK 版本 | 25.3 LTS | 最近 LTS、完整 ARM64 优化、Keeper 原生 |
| 协调组件 | ClickHouse Keeper（非 ZooKeeper） | 更省资源、一致性更好、CK 原生推荐 |
| OS | Amazon Linux 2023 ARM64 | 与 g8g 平台匹配 |
| 表引擎 | `ReplicatedMergeTree` | 埋点 append-only，不需要 Replacing/Collapsing；Replicated 借 Keeper 自动同步 |
| 写入链路 | MSK → MSK Connect (`clickhouse-kafka-connect`) | 精确一次、独立伸缩、与生态一致（由用户指定） |
| 接入层 | NLB internal | CK native protocol 是 TCP 二进制，ALB 不支持；NLB 跨 AZ 开箱即用 |
| DNS | Route53 私有 Hosted Zone 别名 `clickhouse.internal.zeelool` | 屏蔽 NLB 变更 |
| IaC | Terraform（基础设施）+ SSM State Manager / SSM Documents（OS/CK 配置） | 100% AWS 原生；无需额外配置管理工具；无 SSH；有 IAM 审计 |

---

## 4. 高可用与故障恢复

### 4.1 故障域矩阵

| 故障场景 | 影响 | 自动恢复 | RPO | RTO |
|---|---|---|---|---|
| 单个 CK 节点宕机 | 该 AZ 失去本地读；NLB 把流量切走 | ✅ | 0 | < 30s |
| 单个 AZ 故障（1 CK + 1 Keeper） | 另一 AZ CK 副本 + 第三 AZ Keeper 维持仲裁 | ✅ | 0 | < 60s |
| 2 个 Keeper 同时挂 | 集群降级为**只读**；查询仍可用 | ❌ 需人工 | 0 | 10-30 min |
| EBS 数据卷损坏 | 该副本数据丢失 | `SYSTEM RESTORE REPLICA` | 0 | 30-60 min |
| Keeper 元数据损坏 | 集群不可写 | 从 S3 快照恢复 | 取决于快照频率 | 1-4 h |
| Region 故障 | 全挂（不在本期 HA 范围） | — | — | — |

### 4.2 Keeper 配置要点

- `operation_timeout_ms = 10000`
- `session_timeout_ms = 30000`
- `snapshot_distance = 10000`（每 1 万操作一个快照）
- `reserved_log_items = 1000`（Raft log 保留数）
- 3 节点 Raft，跨 3 AZ 分布

### 4.3 客户端访问 HA

```
App / BI / MSK Connect
     ↓
Network Load Balancer (internal, 跨 3 AZ)
  - TCP 9000 (native) + 8123 (HTTP)
  - Target: ck-01, ck-02
  - Health check: HTTP GET /ping → 200
  - Sticky session: 关闭
     ↓
  ck-01 (AZ-1a)  ck-02 (AZ-1c)
```

### 4.4 故障演练清单（按季度）

1. Kill ck-01 进程 → 验证查询自动 failover、Kafka 消费续消
2. NACL 阻断 AZ-1a 入/出流量 → 验证 NLB 切流、Keeper 仲裁维持
3. 停 2 个 Keeper → 验证 CK 进入只读降级
4. 删除一个副本 `/var/lib/clickhouse/data/...` → 走 `SYSTEM RESTORE REPLICA`

---

## 5. 写入链路（MSK → MSK Connect → CK）

**决策：MSK + MSK Connect（`clickhouse-kafka-connect`）。本期仅记录决策，详细设计延后。**

要点：
- Connector 目标地址指向 NLB（不是单节点），节点故障自动漂移
- 幂等：MSK offset 提交 + CK `*MergeTree` block dedup 保证精确一次
- MSK Connect Worker 跨 2 AZ 托管 HA
- Topic 分区数建议 6 或 12（2 节点的整数倍，未来加分片无痛）

> **TODO**：MSK Connect 资源规格（MCU 数）、Connector 配置、序列化格式（JSONEachRow / Avro）、DLQ 策略，待后续单独设计。

---

## 6. 数据模型

**决策：延后设计。** 需要客户确认的输入：

- 当前埋点字段清单（列名、类型、是否枚举）
- 最常见查询形态（按用户轨迹 / 按事件名时间聚合 / 漏斗分析等）
- 是否需要 dynamic fields（`Map(String, String)` vs 固定列）
- 是否需要物化视图加速（默认先不加，按数据说话）

> **TODO**：表结构 DDL、partition/order by、TTL、CODEC、MV 方案，待后续单独设计；暂时预留 `schema/events_local.sql` 占位。

---

## 7. 备份策略

### 7.1 目标

| 类型 | 恢复场景 | 频率 | 保留 |
|---|---|---|---|
| CK 数据全量 | 双副本同时损坏 / 误删表 | 每周 1 次 | 4 周 |
| CK 数据增量 | 同上（更细粒度） | 每日 1 次 | 14 天 |
| CK 元数据（schema / users / config） | 集群重建 | 每次变更 + 每日 | 永久（Git） |
| Keeper 快照 | Keeper 元数据损坏 | Keeper 自动每 10k 操作，每日镜像到 S3 | 14 天 |

### 7.2 S3 桶配置

- 命名：`example-ck-backup-apne1`（区域后缀）
- Storage class：Standard-IA（30 天后 Glacier Instant Retrieval）
- Versioning：开启
- Object Lock：合规锁 30 天（防勒索/误删）
- 加密：SSE-KMS（AWS 托管密钥起步）
- 生命周期：14 天增量 / 4 周全量到期自动删
- 跨 Region 复制：**暂不启用**（本期不含跨 Region DR）

### 7.3 备份方式

使用 CK 原生 `BACKUP TO S3(...)` 命令：

```sql
-- 每周日 02:00 JST 全量
BACKUP TABLE events_local
TO S3('s3://example-ck-backup-apne1/full/YYYY-MM-DD/')
SETTINGS compression_method='zstd', compression_level=3;

-- 每日 02:00 JST 增量（基于上次全量）
BACKUP TABLE events_local
TO S3('s3://example-ck-backup-apne1/incremental/YYYY-MM-DD/')
SETTINGS base_backup = S3('s3://example-ck-backup-apne1/full/<last_full_date>/');
```

执行侧要点：
- **只在 ck-01 执行**，避免重复传输
- 通过 VPC Gateway Endpoint for S3（免 NAT / 免流量费）
- IAM 用 EC2 Instance Profile（`s3:PutObject`、`s3:GetObject`），**不硬编码 AK/SK**

### 7.4 元数据归 Git

仓库中的 `schema/`、`config/clickhouse/`、`config/keeper/` 是事实源；有 review、有历史、有 PR 流程。备份 S3 只备数据不备配置。

### 7.5 恢复演练要求

- **每季度一次**完整 RESTORE 演练；未演练过的备份视为不可靠
- Runbook：`docs/runbooks/backup-restore.md`（§ 9 TODO）

---

## 8. 部署方式（IaC）

### 8.1 技术栈

| 层 | 工具 |
|---|---|
| 基础设施（VPC 复用、EC2、EBS、NLB、S3、IAM） | Terraform |
| 实例 Provisioning（OS 调优、CK/Keeper 安装） | cloud-init (user_data) — 仅首次最小 bootstrap |
| 持续配置管理（配置变更、版本升级、drift 检测） | **SSM State Manager + SSM Documents** |
| 集群引导（建表、创建用户、权限） | SQL 脚本，通过 SSM Run Command 下发 |
| 临时运维登录 | SSM Session Manager（无 SSH） |

**选型理由**：100% AWS 原生，无需第三方配置管理工具；SSM Agent 在 AL2023 预装免安装；IAM 统一鉴权 + CloudTrail 审计；State Manager 支持按计划/事件触发、自动 drift 修复。

**升级路径**：若未来需要更强的不可变基础设施，可平滑升级到 Packer 预烤 AMI + 简化 user_data。

### 8.2 AWS 账号与区域配置

- Profile：`default`
- Region：`ap-northeast-1`
- VPC：**复用** `vpc-XXXXXXXXXXXXXXXXX`（当前 EC2 所在 VPC）
- 子网：使用已有 private1/2/3（见第 2 节）
- 不新建 VPC / 子网 / IGW / NAT

### 8.3 目录结构

```
2026-project/zeelool-clickhouse/
├── terraform/
│   ├── envs/
│   │   └── prod/                 # 本期仅 prod
│   ├── modules/
│   │   ├── clickhouse-node/      # EC2 + EBS + IAM profile + user_data
│   │   ├── keeper-node/          # EC2 + EBS + IAM profile + user_data
│   │   ├── nlb/                  # NLB + target group + Route53
│   │   ├── backup-s3/            # S3 bucket + lifecycle + KMS
│   │   └── ssm/                  # SSM Documents + Associations
│   └── backend.tf                # S3 state + DynamoDB lock
├── ssm-documents/                # SSM Document 定义（YAML）
│   ├── install-clickhouse.yml    # CK 安装 / 升级
│   ├── install-keeper.yml        # Keeper 安装 / 升级
│   ├── render-clickhouse-config.yml  # 渲染 config.d/users.d
│   ├── render-keeper-config.yml      # 渲染 keeper_config.xml
│   ├── bootstrap-schema.yml      # 建库建表建用户
│   └── run-backup.yml            # 触发 BACKUP TO S3
├── user-data/                    # cloud-init 最小 bootstrap
│   ├── clickhouse-bootstrap.sh   # 格式化挂载数据盘、装 SSM Agent（预装）、打 tag
│   └── keeper-bootstrap.sh
├── schema/                       # § 6 TODO
├── config/
│   ├── clickhouse/
│   │   ├── config.d/             # 模板，SSM Document 渲染并下发
│   │   └── users.d/
│   └── keeper/
│       └── keeper_config.xml.tpl
├── docs/
│   ├── superpowers/
│   │   ├── specs/                # 本文件
│   │   └── plans/                # writing-plans 产出
│   └── runbooks/                 # § 9 TODO
├── .github/workflows/
│   └── terraform-plan.yml
└── README.md
```

### 8.4 阶段化交付

| Phase | 内容 | 产出 | 估时 |
|---|---|---|---|
| 0 | 网络打底：SG、S3 Gateway Endpoint（免费）、IAM Instance Profile（含 SSM 权限）<br/>注：现有 VPC 已有 NAT Gateway，SSM Agent 走 NAT 出网即可，无需建 SSM Interface Endpoint | Terraform: `modules/network`、`modules/iam` | ~30 min |
| 1 | SSM Documents 上架：安装/配置/引导 CK 与 Keeper 的 Document 本身先跑通 | `aws ssm describe-document` 可见 | ~30 min |
| 2 | Keeper 集群：3 × t4g.small + user_data bootstrap + SSM Association 触发 `install-keeper` + `render-keeper-config` → Raft 成环 | `echo mntr \| nc keeper-01 9181` 显示 1 leader + 2 follower | ~45 min |
| 3 | CK 数据节点：2 × r8g.xlarge + 数据盘 + user_data bootstrap + SSM Association 触发 `install-clickhouse` + `render-clickhouse-config` | `system.replicas` 两节点互见 | ~1 h |
| 4 | 接入层：NLB + target group + Route53 别名 | `clickhouse.internal.zeelool` 连通 | ~30 min |
| 5 | 表结构 + 写入（§ 5、§ 6） | **TODO** | — |
| 6 | 备份：S3 桶 + IAM 策略 + EventBridge 计划 + `run-backup` Document；跑一次全量备份 | 全量备份落 S3 | ~1 h |
| 7 | 监控（§ 9） | **TODO** | — |

**MVP 可用 = Phase 0 + 1 + 2 + 3 + 4 + 6 ≈ 半天内上线**（Phase 5 / 7 延后）。

### 8.5 安全基线

| 项 | 策略 |
|---|---|
| 网络 | 全私有子网；无公网 IP；通过 SSM Session Manager 运维 |
| 安全组 | CK `9000/8123/9009`、Keeper `9181/9234` 只对 VPC CIDR 放行 |
| IAM | CK Instance Profile 只给备份 S3 桶 `PutObject/GetObject`；Keeper 无 AWS 权限 |
| EBS | AWS 托管密钥加密（KMS-CMK 可选升级） |
| TLS | 本期 VPC 内部不启（5-10% 性能损耗）；后续按需 |

---

## 9. 延后项（TODO）

| 章节 | 延后内容 | 触发条件 |
|---|---|---|
| § 5 | MSK Connect Connector 详细设计 | 字段清单明确、业务线接入时 |
| § 6 | 数据模型（表结构、分区、TTL、MV） | 埋点字段冻结后 |
| § 9 | 监控告警（AMP + AMG + 8 条核心告警 + 5 篇 runbook） | 上线前必须完成 |

---

## 10. 成本估算（ap-northeast-1，按需价格）

| 项 | 月成本 | 备注 |
|---|---|---|
| 2 × `r8g.xlarge` CK | ~$440 | 东京比 us-east-1 贵约 15-20% |
| 3 × `t4g.small` Keeper | ~$52 | |
| EBS（CK: 50+1500 GB × 2；Keeper: 50 GB × 3，共 3250 GB）| ~$312 | gp3 基线配置；EBS 不享 RI/SP 折扣 |
| NLB（internal） | ~$20 | 含 LCU |
| S3 备份 | ~$85 | Standard-IA |
| VPC Gateway Endpoint for S3 | $0 | 免费 |
| SSM Agent 流量（走现有 NAT） | <$1 | 心跳 + 指令，流量极小 |
| **合计（按需）** | **~$910/月** | |
| **RI 1y（CK + Keeper 预留）** | **~$670/月** | EBS/S3/NLB 无折扣 |
| **SP 3y 折后** | **~$530/月** | 进一步优化空间 |

---

## 11. 参考与依赖

- 类似项目：`AWS/EC2-Workload/doris-cluster/`（POC 参考）
- TF 栈模板：`AWS/EKS-Workload/terraform-devlake/`
- 现有 VPC：`vpc-XXXXXXXXXXXXXXXXX`（Tokyo）
- ClickHouse 官方文档：https://clickhouse.com/docs
- Keeper 配置参考：https://clickhouse.com/docs/en/guides/sre/keeper/clickhouse-keeper

---

## 12. 变更记录

| 日期 | 版本 | 变更 | 作者 |
|---|---|---|---|
| 2026-05-04 | v0.1 | 初稿；锁定方案 A（1 shard × 2 replica）、Tokyo、复用 VPC | Keith |
| 2026-05-04 | v0.2 | 去掉 dev 环境；Ansible → SSM State Manager + SSM Documents；Phase 由 7 步调整为 8 步；确认 VPC 已有 NAT 不需 SSM Interface Endpoint | Keith |
| 2026-05-05 | v0.3 | CK 数据盘 800 GB → **1500 GB**（单节点）；EBS 月成本 \$165 → \$312；按需总价 \$763 → \$910 | Keith |
