# -------- Discovery --------
#
# VPC CIDR and region are discovered from the supplied vpc_id rather than
# being passed as variables — less to get wrong when deploying into a
# pre-existing VPC.

data "aws_vpc" "this" {
  id = var.vpc_id
}

data "aws_region" "current" {}

# -------- Security groups --------
#
# Rule model:
#   - clickhouse SG : ingress from NLB SG (9000/8123) + self (9000 distributed, 9009 interserver)
#   - keeper SG     : ingress from CK SG (9181) + self (9181 + 9234 raft)
#   - nlb SG        : ingress from VPC CIDR (client entry point)
#
# SGs are created first, rules follow — breaks the CK<->NLB circular ref.

resource "aws_security_group" "clickhouse" {
  name        = "${var.name_prefix}-clickhouse"
  description = "ClickHouse data nodes"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-clickhouse" }
}

resource "aws_security_group" "keeper" {
  name        = "${var.name_prefix}-keeper"
  description = "ClickHouse Keeper nodes"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-keeper" }
}

resource "aws_security_group" "nlb" {
  name        = "${var.name_prefix}-nlb"
  description = "Internal NLB for ClickHouse"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-nlb" }
}

# -------- NLB SG rules (entry point, open to VPC CIDR) --------

resource "aws_vpc_security_group_ingress_rule" "nlb_native" {
  security_group_id = aws_security_group.nlb.id
  description       = "CK native TCP via NLB"
  ip_protocol       = "tcp"
  from_port         = 9000
  to_port           = 9000
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

resource "aws_vpc_security_group_ingress_rule" "nlb_http" {
  security_group_id = aws_security_group.nlb.id
  description       = "CK HTTP via NLB"
  ip_protocol       = "tcp"
  from_port         = 8123
  to_port           = 8123
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

resource "aws_vpc_security_group_egress_rule" "nlb_all" {
  security_group_id = aws_security_group.nlb.id
  description       = "NLB to targets in VPC"
  ip_protocol       = "-1"
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

# -------- ClickHouse SG rules --------

resource "aws_vpc_security_group_ingress_rule" "ck_native_from_nlb" {
  security_group_id            = aws_security_group.clickhouse.id
  description                  = "CK native 9000 from NLB"
  ip_protocol                  = "tcp"
  from_port                    = 9000
  to_port                      = 9000
  referenced_security_group_id = aws_security_group.nlb.id
}

resource "aws_vpc_security_group_ingress_rule" "ck_http_from_nlb" {
  security_group_id            = aws_security_group.clickhouse.id
  description                  = "CK HTTP 8123 from NLB (incl. health check)"
  ip_protocol                  = "tcp"
  from_port                    = 8123
  to_port                      = 8123
  referenced_security_group_id = aws_security_group.nlb.id
}

resource "aws_vpc_security_group_ingress_rule" "ck_interserver_self" {
  security_group_id            = aws_security_group.clickhouse.id
  description                  = "CK interserver replication (9009) between replicas"
  ip_protocol                  = "tcp"
  from_port                    = 9009
  to_port                      = 9009
  referenced_security_group_id = aws_security_group.clickhouse.id
}

resource "aws_vpc_security_group_ingress_rule" "ck_native_self" {
  security_group_id            = aws_security_group.clickhouse.id
  description                  = "CK distributed queries between replicas (9000)"
  ip_protocol                  = "tcp"
  from_port                    = 9000
  to_port                      = 9000
  referenced_security_group_id = aws_security_group.clickhouse.id
}

resource "aws_vpc_security_group_egress_rule" "ck_all" {
  security_group_id = aws_security_group.clickhouse.id
  description       = "All egress (SSM, S3 gw, Keeper, peers)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# -------- Keeper SG rules --------

resource "aws_vpc_security_group_ingress_rule" "keeper_client_from_ck" {
  security_group_id            = aws_security_group.keeper.id
  description                  = "Keeper client port 9181 from CK"
  ip_protocol                  = "tcp"
  from_port                    = 9181
  to_port                      = 9181
  referenced_security_group_id = aws_security_group.clickhouse.id
}

resource "aws_vpc_security_group_ingress_rule" "keeper_client_self" {
  security_group_id            = aws_security_group.keeper.id
  description                  = "Keeper client port 9181 between Keepers (for inter-node check)"
  ip_protocol                  = "tcp"
  from_port                    = 9181
  to_port                      = 9181
  referenced_security_group_id = aws_security_group.keeper.id
}

resource "aws_vpc_security_group_ingress_rule" "keeper_raft_self" {
  security_group_id            = aws_security_group.keeper.id
  description                  = "Keeper Raft peer 9234 between Keepers"
  ip_protocol                  = "tcp"
  from_port                    = 9234
  to_port                      = 9234
  referenced_security_group_id = aws_security_group.keeper.id
}

resource "aws_vpc_security_group_egress_rule" "keeper_all" {
  security_group_id = aws_security_group.keeper.id
  description       = "All egress (SSM, peers)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# -------- S3 Gateway Endpoint (region-agnostic) --------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids

  tags = { Name = "${var.name_prefix}-s3-gw" }
}
