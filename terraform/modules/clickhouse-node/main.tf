resource "aws_instance" "clickhouse" {
  ami           = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  private_ip    = var.private_ip
  key_name      = var.key_name

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
    # key_name is a force-new attribute. Protect already-running instances so
    # setting the var later doesn't wipe the CK data — use scripts/install-ssh-public-key.sh
    # to retrofit SSH access via SSM instead.
    ignore_changes = [ami, key_name]
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  type              = "gp3"
  size              = var.data_volume_gb
  # Only set iops/throughput when the caller overrides the gp3 baseline
  # (3000 IOPS / 125 MB/s). Sending null keeps Terraform from trying to
  # "set" the baseline explicitly, which would force unnecessary ModifyVolume calls.
  iops       = var.data_volume_iops
  throughput = var.data_volume_throughput_mbps
  encrypted  = true

  tags = { Name = "${var.name}-data" }

  # Guard 1.5 TB of CK data from accidental `terraform destroy`.
  # To tear down for real: temporarily remove this block, apply, destroy.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.clickhouse.id
  stop_instance_before_detaching = true
}
