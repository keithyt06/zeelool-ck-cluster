resource "aws_instance" "keeper" {
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
    Name     = var.name
    Role     = "keeper"
    ServerId = tostring(var.server_id)
  }

  lifecycle {
    # key_name is a force-new attribute. Protect already-running instances so
    # setting the var later doesn't wipe data — use scripts/install-ssh-public-key.sh
    # to retrofit SSH access via SSM instead.
    ignore_changes = [ami, key_name]
  }
}
