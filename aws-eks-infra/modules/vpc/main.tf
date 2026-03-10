resource "aws_vpc" "vpc_cidr_emart" {
  cidr_block       = var.cidr_block
  instance_tenancy = "default"

  tags = {
    Name = "${var.name}-${var.environment}-${var.project}-vpc"
    environment = var.environment
    project = var.project
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "public_emart_subnet" {
  count = var.availability_zones != null ? length(var.availability_zones) : 0
  vpc_id = aws_vpc.vpc_cidr_emart.id
  cidr_block = var.public_subnets[count.index]
  availability_zone = var.availability_zones[count.index]
  map_public_ip_on_launch = true
 
  tags = {
    Name = "${var.name}-${var.environment}-${var.project}-public-subnet[${count.index + 1}]"
    environment = var.environment
    project = var.project
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_internet_gateway" "emart_igw" {
  vpc_id = aws_vpc.vpc_cidr_emart.id

  tags = {
    Name = "${var.name}-${var.environment}-${var.project}-igw"
    environment = var.environment
    project = var.project
  } 
}

resource "aws_route_table" "emart_public_rt" {
  count = length(var.availability_zones)
  vpc_id = aws_vpc.vpc_cidr_emart.id
  

   tags = {
    Name = "${var.name}-${var.environment}-${var.project}-public-rt[${count.index + 1}]"
    environment = var.environment
    project = var.project
  } 
}

resource "aws_route" "emart-public-route" {
  count = length(var.availability_zones)
  route_table_id = aws_route_table.emart_public_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.emart_igw.id
}

resource "aws_route_table_association" "emart_public_rt_assoc" {
  count = length(var.availability_zones) 
  subnet_id = aws_subnet.public_emart_subnet[count.index].id
  route_table_id = aws_route_table.emart_public_rt[count.index].id
}


resource "aws_subnet" "private_emart_subnet" {
  count = var.availability_zones != null ? length(var.availability_zones) : 0
  vpc_id = aws_vpc.vpc_cidr_emart.id
  cidr_block = var.private_subnets[count.index]
  availability_zone = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name}-${var.environment}-${var.project}-private-subnet[${count.index + 1}]"
    environment = var.environment
    project = var.project
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb" = "1"
}
}

resource "aws_route_table" "private_emart_rt" {
  count = length(var.availability_zones)
  vpc_id = aws_vpc.vpc_cidr_emart.id
  
  tags = {
    Name = "${var.name}-${var.environment}-${var.project}-private-emart-rt[${count.index + 1}]"
    environment = var.environment
    project = var.project
} 
}

resource "aws_eip" "emart_nat_eip" {
  count = length(var.availability_zones)
  domain = "vpc"

  tags = {
    Name = "${var.name}-${var.environment}-${var.project}-emart-nat-eip[${count.index + 1}]"
    environment = var.environment
    project = var.project
  }
}

resource "aws_nat_gateway" "emart_nat_gw" {
  count = length(var.availability_zones)
  allocation_id = aws_eip.emart_nat_eip[count.index].id
  subnet_id = aws_subnet.public_emart_subnet[count.index].id

   tags = {
    Name = "${var.name}-${var.environment}-${var.project}-emart-nat-gw[${count.index + 1}]"
    environment = var.environment
    project = var.project
  }
}

resource "aws_route" "private_eamrt_route" {
  count = length(var.availability_zones)
  route_table_id = aws_route_table.private_emart_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.emart_nat_gw[count.index].id
}

resource "aws_route_table_association" "emart_private_rt_assoc" {
  count = length(var.availability_zones)
  subnet_id = aws_subnet.private_emart_subnet[count.index].id
  route_table_id = aws_route_table.private_emart_rt[count.index].id  
}

resource "aws_subnet" "db_private_subnet" {
  count = var.availability_zones != null ? length(var.availability_zones) : 0
  vpc_id = aws_vpc.vpc_cidr_emart.id
  cidr_block = var.db_private_subnet[count.index]
  availability_zone = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name}-${var.environment}-${var.project}-db-private-subnet[${count.index + 1}]"
    environment = var.environment
    project = var.project
  }
}

resource "aws_route_table" "db_private_rt" {
  count = length(var.availability_zones)
  vpc_id = aws_vpc.vpc_cidr_emart.id

  tags = {
    Name = "${var.name}-${var.environment}-${var.project}-db-private-rt[${count.index + 1}]"
    environment = var.environment
    project = var.project 
}

}

resource "aws_route" "db_private_route" {
  count                  = length(var.availability_zones)
  route_table_id         = aws_route_table.db_private_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.emart_nat_gw[count.index].id
}

resource "aws_route_table_association" "db_private_rt_assoc" {
  count = length(var.availability_zones)
  route_table_id = aws_route_table.db_private_rt[count.index].id
  subnet_id = aws_subnet.db_private_subnet[count.index].id
}