module "dev_vpc" {
  source = "git::https://github.com/sripadalabs/terraform-aws-vpc.git?ref=main"
  vpc_cidr = "10.32.0.0/24"
  create_vpc = true
}

module "dev_vpc_networking" {
  source = "git::https://github.com/sripadalabs/terraform-aws-vpc-networking.git?ref=main"
  vpc_id = module.dev_vpc.vpc_id
  internet_ingress = true
  public_subnets = [
    {
      key = "public subnet 1"
      cidr = cidrsubnet(module.dev_vpc.cidr_block, 2, 0)
      az = "use1-az1"
      subnet_type = "public"
    },
    {
      key = "public subnet 2"
      cidr = cidrsubnet(module.dev_vpc.cidr_block, 2, 1)
      az = "use1-az2"
      subnet_type = "public"
    }
  ]

  private_subnets = [
    {
      key = "private subnet 1"
      cidr = cidrsubnet(module.dev_vpc.cidr_block, 3, 4)
      az = "use1-az1"
      subnet_type = "private"
      egress = "public_nat"
    },
    {
      key = "private subnet 2"
      cidr = cidrsubnet(module.dev_vpc.cidr_block, 3, 5)
      az = "use1-az2"
      subnet_type = "private"
      egress = "public_nat"
    }
  ]
}