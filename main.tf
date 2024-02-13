resource "aws_lb_target_group" "app-name" {
  name     = "${local.name}-${var.tags.component}"
  port     = 8080
  protocol = "HTTP"
  #vpc_id   = data.aws_ssm_parameter.vpc_id.value
  vpc_id   = var.vpc_id
  deregistration_delay = 120

   health_check {
    path                = "/health"
    port                = 8080
    interval            = 10
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200-299"
  }
}


module "app-name" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  name = "${local.name}-${var.tags.component}-ami"
  #ami = data.aws_ami.ami-id.id
  ami = var.ami_id
  #instance_type          = "t2.micro"
  instance_type          = var.instance_type 
  #vpc_security_group_ids = [data.aws_ssm_parameter.app-name_sg_id.value]
  vpc_security_group_ids = [var.app-name_sg_id]

  #subnet_id = element(split(",",data.aws_ssm_parameter.private_subnet_ids.value),0)
  subnet_id = element(var.private_subnet_ids,0)

   iam_instance_profile = "FullAdminAccess"
  tags = merge(var.common_tags,var.tags,
    {
        Name="${local.name}-${var.tags.component}-ami"
    }
  )
}

resource "null_resource" "app-name" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers = {
    instance_id = module.app-name.id
  }

  # Bootstrap script can run on any instance of the cluster
  # So we just choose the first in this case
  connection {
    host = module.app-name.private_ip
    type = "ssh"
    user = "centos"
    password = "DevOps321"
  }

  provisioner "file" {
    source      = "bootstrap.sh"
    destination = "/tmp/bootstrap.sh"
  }

  provisioner "remote-exec" {
    # Bootstrap script called with private_ip of each node in the cluster
    inline = [
       "chmod +x /tmp/bootstrap.sh" ,
       "sudo sh /tmp/bootstrap.sh ${var.tags.component} ${var.environment} ${var.app_version}"

    ]
  }
}

resource "aws_ec2_instance_state" "app-name" {
  instance_id = module.app-name.id
  state       = "stopped"
  depends_on = [ null_resource.app-name ]

}

resource "aws_ami_from_instance" "app-name" {
  name               = "${local.name}-${var.tags.component}-${local.current_time}"
  source_instance_id = module.app-name.id
  depends_on = [ aws_ec2_instance_state.app-name ]
}


resource "null_resource" "app-name_delete" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers = {
    instance_id = module.app-name.id
  }

  provisioner "local-exec" {
    # Bootstrap script called with private_ip of each node in the cluster
    command = "aws ec2 terminate-instances --instance-ids ${module.app-name.id}"
  }

  depends_on = [ aws_ami_from_instance.app-name]
}

resource "aws_launch_template" "app-name" {
  name = "${local.name}-${var.tags.component}"

 image_id = aws_ami_from_instance.app-name.id

  instance_initiated_shutdown_behavior = "terminate"

  instance_type = "t2.micro"
  update_default_version = true

  #vpc_security_group_ids = [data.aws_ssm_parameter.app-name_sg_id.value]
  vpc_security_group_ids = [var.app-name_sg_id]


  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${local.name}-${var.tags.component}"
    }
  }

}


resource "aws_autoscaling_group" "app-name" {
  name                      = "${local.name}-${var.tags.component}"
  max_size                  = 10
  min_size                  = 1
  health_check_grace_period = 60
  health_check_type         = "ELB"
  desired_capacity          = 2
  #vpc_zone_identifier       = split(",", data.aws_ssm_parameter.private_subnet_ids.value  )
   vpc_zone_identifier       = var.private_subnet_ids
  target_group_arns = [aws_lb_target_group.app-name.arn]
  launch_template {
    id      = aws_launch_template.app-name.id
    version = aws_launch_template.app-name.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["launch_template"]
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-${var.tags.component}"
    propagate_at_launch = true
  }

  timeouts {
    delete = "15m"
  }

}

resource "aws_lb_listener_rule" "app-name" {
  listener_arn = data.aws_ssm_parameter.app_alb_listener_arn.value
  priority     = var.rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app-name.arn
  }

  condition {
    host_header {
      values = ["${var.tags.component}.app-${var.environment}.${var.zone_name}"]
    }
  }
}

resource "aws_autoscaling_policy" "app-name" {
  autoscaling_group_name = aws_autoscaling_group.app-name.name
  name                   = "${local.name}-${var.tags.component}"
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 2.0
  }
}