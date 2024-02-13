locals {
    name = "${var.project_name}-${var.environment}"
    current_time=formatdate("YYYY-MM-DD-hh-mm",timestamp())
    #database_subnet_id = element(split(",", data.aws_ssm_parameter.database_subnet_ids.value),0)
  
}