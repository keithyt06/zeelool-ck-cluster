data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Keeper role — SSM only, no S3 write.
resource "aws_iam_role" "keeper" {
  name               = "${var.name_prefix}-keeper-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "keeper_ssm" {
  role       = aws_iam_role.keeper.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "keeper" {
  name = "${var.name_prefix}-keeper"
  role = aws_iam_role.keeper.name
}

# Data-node role — SSM + S3 backup.
resource "aws_iam_role" "ck_node" {
  name               = "${var.name_prefix}-node-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ck_node_ssm" {
  role       = aws_iam_role.ck_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "backup" {
  count = var.enable_backup_policy ? 1 : 0

  statement {
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
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
  count  = var.enable_backup_policy ? 1 : 0
  name   = "${var.name_prefix}-backup"
  role   = aws_iam_role.ck_node.id
  policy = data.aws_iam_policy_document.backup[0].json
}

resource "aws_iam_instance_profile" "ck_node" {
  name = "${var.name_prefix}-node"
  role = aws_iam_role.ck_node.name
}
