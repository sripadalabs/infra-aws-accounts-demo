module "dev_vpc" {
  source = "git::https://github.com/sripadalabs/terraform-aws-vpc.git?ref=main"
  vpc_cidr = "10.32.0.0/24"
  create_vpc = true
}
