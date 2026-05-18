# Create VPC
resource "aws_vpc" "monitoring_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.project_name}-vpc"
    Environment = var.environment
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "monitoring_igw" {
  vpc_id = aws_vpc.monitoring_vpc.id

  tags = {
    Name        = "${var.project_name}-igw"
    Environment = var.environment
  }
}

# Create Route Table for public access
resource "aws_route_table" "monitoring_rt" {
  vpc_id = aws_vpc.monitoring_vpc.id

  route {
    cidr_block      = "0.0.0.0/0"
    gateway_id      = aws_internet_gateway.monitoring_igw.id
  }

  tags = {
    Name        = "${var.project_name}-rt"
    Environment = var.environment
  }
}

# Create Monitoring Subnet
resource "aws_subnet" "monitoring_subnet" {
  vpc_id                  = aws_vpc.monitoring_vpc.id
  cidr_block              = var.monitoring_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.project_name}-monitoring-subnet"
    Environment = var.environment
  }
}

# Create App Subnet
resource "aws_subnet" "app_subnet" {
  vpc_id                  = aws_vpc.monitoring_vpc.id
  cidr_block              = var.app_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.project_name}-app-subnet"
    Environment = var.environment
  }
}

# Associate subnets with route table
resource "aws_route_table_association" "monitoring_rta" {
  subnet_id      = aws_subnet.monitoring_subnet.id
  route_table_id = aws_route_table.monitoring_rt.id
}

resource "aws_route_table_association" "app_rta" {
  subnet_id      = aws_subnet.app_subnet.id
  route_table_id = aws_route_table.monitoring_rt.id
}

# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}
