#!/usr/bin/env python3
"""
setup_infra.py - AWS infrastructure provisioner for BMI Health Tracker
Architecture: Private Subnet + ALB + ACM + SSM Session Manager

Creates:
  - VPC (10.0.0.0/16) with DNS hostnames/support enabled
  - Internet Gateway attached to VPC
  - 2 public subnets  (AZ-a: 10.0.1.0/24, AZ-b: 10.0.2.0/24)
  - 2 private subnets (AZ-a: 10.0.11.0/24, AZ-b: 10.0.12.0/24)
  - Public route table  (0.0.0.0/0 -> IGW)   associated to public subnets
  - 1 regional NAT Gateway (public, in public-subnet-1) + EIP
  - Private route table (0.0.0.0/0 -> NAT GW) associated to private subnets
  - Security group for VPC endpoints (HTTPS 443 from VPC CIDR)
  - 3 SSM Interface VPC Endpoints (ssm, ssmmessages, ec2messages)
  - EC2 security group (port 80 from ALB SG - added by deploy.sh)
  - IAM role bmi-ec2-role with AmazonSSMManagedInstanceCore + instance profile
  - EC2 t3.medium in private-subnet-1 (Ubuntu 26.04 LTS, IMDSv2, 20 GiB gp3 encrypted)

Usage:
  python setup_infra.py --action create
  python setup_infra.py --action teardown
  python setup_infra.py --action status

State:
  infra_state.json  - tracks all created resource IDs for teardown
  setup_infra.log   - persistent log file

AWS profile: sarowar-ostad
Region:      ap-south-1
"""

import argparse
import json
import logging
import sys
import time
from botocore.exceptions import ClientError
from datetime import datetime, timezone
from pathlib import Path

import boto3

# ── Configuration ──────────────────────────────────────────────────────────────
AWS_PROFILE           = "sarowar-ostad"
REGION                = "ap-south-1"
STATE_FILE            = Path(__file__).parent / "infra_state.json"
LOG_FILE              = Path(__file__).parent / "setup_infra.log"

VPC_CIDR              = "10.0.0.0/16"
PUBLIC_SUBNET_1_CIDR  = "10.0.1.0/24"
PUBLIC_SUBNET_2_CIDR  = "10.0.2.0/24"
PRIVATE_SUBNET_1_CIDR = "10.0.11.0/24"
PRIVATE_SUBNET_2_CIDR = "10.0.12.0/24"

INSTANCE_TYPE         = "t3.medium"
AMI_ID                = "ami-01a00762f46d584a1"   # Ubuntu 26.04 LTS ap-south-1
IAM_ROLE_NAME         = "bmi-ec2-role"
# Resource names shared with deploy.sh — must stay in sync
ALB_NAME              = "bmi-health-tracker-alb"
TG_NAME               = "bmi-health-tracker-tg"
ALB_SG_NAME           = "bmi-alb-sg"
PROJECT               = "bmi-health-tracker"


# ── Logging ────────────────────────────────────────────────────────────────────
def setup_logging() -> logging.Logger:
    fmt = logging.Formatter(
        "%(asctime)s  %(levelname)-8s  %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    root = logging.getLogger()
    root.setLevel(logging.INFO)

    sh = logging.StreamHandler(sys.stdout)
    # Reconfigure stdout to UTF-8 on Windows (cp1252 cannot encode arrows/dashes)
    if hasattr(sh.stream, 'reconfigure'):
        sh.stream.reconfigure(encoding='utf-8', errors='replace')
    sh.setFormatter(fmt)
    root.addHandler(sh)

    fh = logging.FileHandler(LOG_FILE)
    fh.setFormatter(fmt)
    root.addHandler(fh)

    return logging.getLogger("infra")


# ── State helpers ──────────────────────────────────────────────────────────────
def load_state() -> dict:
    if STATE_FILE.exists():
        with open(STATE_FILE) as f:
            return json.load(f)
    return {}


def save_state(state: dict) -> None:
    state["last_updated"] = datetime.now(timezone.utc).isoformat()
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2, default=str)


def patch_state(key: str, value) -> dict:
    """Load, update one key, save, return updated state."""
    state = load_state()
    state[key] = value
    save_state(state)
    return state


# ── AWS session ────────────────────────────────────────────────────────────────
def get_session() -> boto3.Session:
    return boto3.Session(profile_name=AWS_PROFILE, region_name=REGION)


# ── Tag helper ─────────────────────────────────────────────────────────────────
def make_tags(name: str) -> list:
    return [
        {"Key": "Name",      "Value": name},
        {"Key": "Project",   "Value": PROJECT},
        {"Key": "ManagedBy", "Value": "setup_infra.py"},
    ]


def tagspec(resource_type: str, name: str) -> list:
    return [{"ResourceType": resource_type, "Tags": make_tags(name)}]


# ── Lookup helpers (check for existing resources before creating) ──────────────
def _find_vpc(ec2, name: str) -> str | None:
    r = ec2.describe_vpcs(Filters=[
        {"Name": "tag:Name", "Values": [name]},
        {"Name": "state",    "Values": ["available", "pending"]},
    ])
    return r["Vpcs"][0]["VpcId"] if r["Vpcs"] else None


def _find_igw(ec2, name: str) -> str | None:
    r = ec2.describe_internet_gateways(Filters=[{"Name": "tag:Name", "Values": [name]}])
    return r["InternetGateways"][0]["InternetGatewayId"] if r["InternetGateways"] else None


def _find_subnet(ec2, name: str) -> str | None:
    r = ec2.describe_subnets(Filters=[
        {"Name": "tag:Name", "Values": [name]},
        {"Name": "state",    "Values": ["available", "pending"]},
    ])
    return r["Subnets"][0]["SubnetId"] if r["Subnets"] else None


def _find_rt(ec2, name: str) -> str | None:
    r = ec2.describe_route_tables(Filters=[{"Name": "tag:Name", "Values": [name]}])
    return r["RouteTables"][0]["RouteTableId"] if r["RouteTables"] else None


def _find_sg(ec2, name: str, vpc_id: str) -> str | None:
    r = ec2.describe_security_groups(Filters=[
        {"Name": "tag:Name", "Values": [name]},
        {"Name": "vpc-id",   "Values": [vpc_id]},
    ])
    return r["SecurityGroups"][0]["GroupId"] if r["SecurityGroups"] else None


def _find_nat_gw(ec2, name: str) -> str | None:
    r = ec2.describe_nat_gateways(Filter=[
        {"Name": "tag:Name", "Values": [name]},
        {"Name": "state",    "Values": ["available", "pending"]},
    ])
    return r["NatGateways"][0]["NatGatewayId"] if r["NatGateways"] else None


def _find_eip(ec2, name: str) -> dict | None:
    r = ec2.describe_addresses(Filters=[{"Name": "tag:Name", "Values": [name]}])
    return r["Addresses"][0] if r["Addresses"] else None


def _find_endpoint(ec2, vpc_id: str, service_name: str) -> str | None:
    r = ec2.describe_vpc_endpoints(Filters=[
        {"Name": "vpc-id",            "Values": [vpc_id]},
        {"Name": "service-name",      "Values": [service_name]},
        {"Name": "vpc-endpoint-state","Values": ["available", "pending"]},
    ])
    return r["VpcEndpoints"][0]["VpcEndpointId"] if r["VpcEndpoints"] else None


# ═══════════════════════════════════════════════════════════════════════════════
# CREATE STEPS
# ═══════════════════════════════════════════════════════════════════════════════

def step_vpc(ec2, log: logging.Logger) -> str:
    name = f"{PROJECT}-vpc"
    existing = _find_vpc(ec2, name)
    if existing:
        log.info(f"VPC already exists: {existing} - skipping")
        patch_state("vpc_id", existing)
        return existing

    log.info(f"Creating VPC ({VPC_CIDR})...")
    r = ec2.create_vpc(CidrBlock=VPC_CIDR, TagSpecifications=tagspec("vpc", name))
    vpc_id = r["Vpc"]["VpcId"]

    ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsHostnames={"Value": True})
    ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsSupport={"Value": True})

    patch_state("vpc_id", vpc_id)
    log.info(f"VPC created: {vpc_id}")
    return vpc_id


def step_igw(ec2, vpc_id: str, log: logging.Logger) -> str:
    name = f"{PROJECT}-igw"
    existing = _find_igw(ec2, name)
    if existing:
        log.info(f"IGW already exists: {existing} - skipping")
        patch_state("igw_id", existing)
        return existing

    log.info("Creating Internet Gateway...")
    r = ec2.create_internet_gateway(TagSpecifications=tagspec("internet-gateway", name))
    igw_id = r["InternetGateway"]["InternetGatewayId"]

    try:
        ec2.attach_internet_gateway(InternetGatewayId=igw_id, VpcId=vpc_id)
        log.info(f"IGW {igw_id} attached to VPC {vpc_id}")
    except ClientError as e:
        if e.response["Error"]["Code"] == "Resource.AlreadyAssociated":
            log.info("IGW already attached")
        else:
            raise

    patch_state("igw_id", igw_id)
    log.info(f"IGW created: {igw_id}")
    return igw_id


def step_subnets(ec2, vpc_id: str, log: logging.Logger) -> tuple[list, list]:
    azs = [
        az["ZoneName"]
        for az in ec2.describe_availability_zones(
            Filters=[{"Name": "state", "Values": ["available"]}]
        )["AvailabilityZones"]
    ]
    if len(azs) < 2:
        raise RuntimeError(f"Need >= 2 AZs in {REGION}, found: {azs}")
    az1, az2 = azs[0], azs[1]
    log.info(f"Using AZs: {az1}, {az2}")

    defs = [
        (f"{PROJECT}-public-subnet-1",  PUBLIC_SUBNET_1_CIDR,  az1, True),
        (f"{PROJECT}-public-subnet-2",  PUBLIC_SUBNET_2_CIDR,  az2, True),
        (f"{PROJECT}-private-subnet-1", PRIVATE_SUBNET_1_CIDR, az1, False),
        (f"{PROJECT}-private-subnet-2", PRIVATE_SUBNET_2_CIDR, az2, False),
    ]

    state = load_state()
    state.setdefault("public_subnet_ids",  [])
    state.setdefault("private_subnet_ids", [])

    for name, cidr, az, is_public in defs:
        bucket = "public_subnet_ids" if is_public else "private_subnet_ids"
        existing = _find_subnet(ec2, name)
        if existing:
            log.info(f"Subnet {name} already exists: {existing}")
            if existing not in state[bucket]:
                state[bucket].append(existing)
            continue

        log.info(f"Creating subnet {name} ({cidr}) in {az}...")
        r = ec2.create_subnet(
            VpcId=vpc_id, CidrBlock=cidr, AvailabilityZone=az,
            TagSpecifications=tagspec("subnet", name),
        )
        sid = r["Subnet"]["SubnetId"]

        if is_public:
            ec2.modify_subnet_attribute(SubnetId=sid, MapPublicIpOnLaunch={"Value": True})

        state[bucket].append(sid)
        log.info(f"Subnet created: {sid} ({name})")

    save_state(state)
    return state["public_subnet_ids"], state["private_subnet_ids"]


def _ensure_rt_association(ec2, rt_id: str, subnet_id: str, log: logging.Logger) -> None:
    r = ec2.describe_route_tables(RouteTableIds=[rt_id])
    existing = {a.get("SubnetId") for a in r["RouteTables"][0].get("Associations", [])}
    if subnet_id in existing:
        log.info(f"  Subnet {subnet_id} already associated with {rt_id}")
        return
    ec2.associate_route_table(RouteTableId=rt_id, SubnetId=subnet_id)
    log.info(f"  Associated subnet {subnet_id} -> RT {rt_id}")


def step_public_rt(ec2, vpc_id: str, igw_id: str, public_subnets: list, log: logging.Logger) -> str:
    name = f"{PROJECT}-public-rt"
    existing = _find_rt(ec2, name)
    if existing:
        log.info(f"Public RT already exists: {existing}")
        rt_id = existing
    else:
        log.info("Creating public route table...")
        r = ec2.create_route_table(VpcId=vpc_id, TagSpecifications=tagspec("route-table", name))
        rt_id = r["RouteTable"]["RouteTableId"]
        try:
            ec2.create_route(RouteTableId=rt_id, DestinationCidrBlock="0.0.0.0/0", GatewayId=igw_id)
            log.info(f"Route 0.0.0.0/0 -> IGW added to {rt_id}")
        except ClientError as e:
            if e.response["Error"]["Code"] != "RouteAlreadyExists":
                raise
        log.info(f"Public RT created: {rt_id}")

    for subnet_id in public_subnets:
        _ensure_rt_association(ec2, rt_id, subnet_id, log)

    patch_state("public_rt_id", rt_id)
    return rt_id


def step_nat_gw(ec2, public_subnet_id: str, log: logging.Logger) -> str:
    nat_name = f"{PROJECT}-nat-gw"
    existing = _find_nat_gw(ec2, nat_name)
    if existing:
        log.info(f"NAT Gateway already exists: {existing}")
        patch_state("nat_gw_id", existing)
        return existing

    # Allocate or reuse EIP
    eip_name = f"{PROJECT}-nat-eip"
    existing_eip = _find_eip(ec2, eip_name)
    if existing_eip:
        eip_alloc_id = existing_eip["AllocationId"]
        log.info(f"EIP already exists: {eip_alloc_id}")
    else:
        log.info("Allocating Elastic IP for NAT Gateway...")
        r = ec2.allocate_address(Domain="vpc", TagSpecifications=tagspec("elastic-ip", eip_name))
        eip_alloc_id = r["AllocationId"]
        log.info(f"EIP allocated: {eip_alloc_id}")

    state = load_state()
    state["eip_allocation_id"] = eip_alloc_id
    save_state(state)

    log.info(f"Creating NAT Gateway in {public_subnet_id}...")
    r = ec2.create_nat_gateway(
        SubnetId=public_subnet_id,
        AllocationId=eip_alloc_id,
        ConnectivityType="public",
        TagSpecifications=tagspec("natgateway", nat_name),
    )
    nat_gw_id = r["NatGateway"]["NatGatewayId"]

    log.info(f"Waiting for NAT Gateway {nat_gw_id} to become available (~60s)...")
    waiter = ec2.get_waiter("nat_gateway_available")
    waiter.wait(NatGatewayIds=[nat_gw_id], WaiterConfig={"Delay": 15, "MaxAttempts": 20})

    patch_state("nat_gw_id", nat_gw_id)
    log.info(f"NAT Gateway ready: {nat_gw_id}")
    return nat_gw_id


def step_private_rt(ec2, vpc_id: str, nat_gw_id: str, private_subnets: list, log: logging.Logger) -> str:
    name = f"{PROJECT}-private-rt"
    existing = _find_rt(ec2, name)
    if existing:
        log.info(f"Private RT already exists: {existing}")
        rt_id = existing
    else:
        log.info("Creating private route table...")
        r = ec2.create_route_table(VpcId=vpc_id, TagSpecifications=tagspec("route-table", name))
        rt_id = r["RouteTable"]["RouteTableId"]
        try:
            ec2.create_route(RouteTableId=rt_id, DestinationCidrBlock="0.0.0.0/0", NatGatewayId=nat_gw_id)
            log.info(f"Route 0.0.0.0/0 -> NAT GW added to {rt_id}")
        except ClientError as e:
            if e.response["Error"]["Code"] != "RouteAlreadyExists":
                raise
        log.info(f"Private RT created: {rt_id}")

    for subnet_id in private_subnets:
        _ensure_rt_association(ec2, rt_id, subnet_id, log)

    patch_state("private_rt_id", rt_id)
    return rt_id


def step_endpoint_sg(ec2, vpc_id: str, log: logging.Logger) -> str:
    name = f"{PROJECT}-vpce-sg"
    existing = _find_sg(ec2, name, vpc_id)
    if existing:
        log.info(f"VPC endpoint SG already exists: {existing}")
        patch_state("endpoint_sg_id", existing)
        return existing

    log.info("Creating VPC endpoint security group...")
    r = ec2.create_security_group(
        GroupName=name,
        Description="BMI Health Tracker - HTTPS from VPC for SSM endpoints",
        VpcId=vpc_id,
        TagSpecifications=tagspec("security-group", name),
    )
    sg_id = r["GroupId"]
    ec2.authorize_security_group_ingress(
        GroupId=sg_id,
        IpPermissions=[{
            "IpProtocol": "tcp",
            "FromPort": 443, "ToPort": 443,
            "IpRanges": [{"CidrIp": VPC_CIDR, "Description": "SSM HTTPS from VPC"}],
        }],
    )
    patch_state("endpoint_sg_id", sg_id)
    log.info(f"VPCE SG created: {sg_id}")
    return sg_id


def step_vpc_endpoints(
    ec2, vpc_id: str, private_subnets: list, endpoint_sg_id: str, log: logging.Logger
) -> None:
    state = load_state()
    state.setdefault("endpoint_ids", {})

    for svc in ("ssm", "ssmmessages", "ec2messages"):
        service_name = f"com.amazonaws.{REGION}.{svc}"
        existing = _find_endpoint(ec2, vpc_id, service_name)
        if existing:
            log.info(f"VPC endpoint {svc} already exists: {existing}")
            state["endpoint_ids"][svc] = existing
            continue

        log.info(f"Creating Interface VPC endpoint: {service_name}...")
        r = ec2.create_vpc_endpoint(
            VpcId=vpc_id,
            VpcEndpointType="Interface",
            ServiceName=service_name,
            SubnetIds=private_subnets,
            SecurityGroupIds=[endpoint_sg_id],
            PrivateDnsEnabled=True,
            TagSpecifications=tagspec("vpc-endpoint", f"{PROJECT}-vpce-{svc}"),
        )
        ep_id = r["VpcEndpoint"]["VpcEndpointId"]
        state["endpoint_ids"][svc] = ep_id
        log.info(f"VPC endpoint created: {ep_id} ({svc})")

    save_state(state)


def step_ec2_sg(ec2, vpc_id: str, log: logging.Logger) -> str:
    name = f"{PROJECT}-ec2-sg"
    existing = _find_sg(ec2, name, vpc_id)
    if existing:
        log.info(f"EC2 SG already exists: {existing}")
        patch_state("ec2_sg_id", existing)
        return existing

    log.info("Creating EC2 security group...")
    r = ec2.create_security_group(
        GroupName=name,
        Description="BMI Health Tracker EC2 - port 80 from ALB SG only (added by deploy.sh)",
        VpcId=vpc_id,
        TagSpecifications=tagspec("security-group", name),
    )
    sg_id = r["GroupId"]
    patch_state("ec2_sg_id", sg_id)
    log.info(f"EC2 SG created: {sg_id}  (port 80 rule added by deploy.sh after ALB is created)")
    return sg_id


def step_iam_role(session: boto3.Session, log: logging.Logger) -> str:
    iam = session.client("iam")

    # Create role if not exists
    try:
        iam.get_role(RoleName=IAM_ROLE_NAME)
        log.info(f"IAM role already exists: {IAM_ROLE_NAME}")
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchEntity":
            raise
        trust = json.dumps({
            "Version": "2012-10-17",
            "Statement": [{"Effect": "Allow",
                           "Principal": {"Service": "ec2.amazonaws.com"},
                           "Action": "sts:AssumeRole"}],
        })
        iam.create_role(
            RoleName=IAM_ROLE_NAME,
            AssumeRolePolicyDocument=trust,
            Description="BMI Health Tracker EC2 - SSM + Route53 + ACM + ALB",
            Tags=[{"Key": "Project", "Value": PROJECT}],
        )
        log.info(f"IAM role created: {IAM_ROLE_NAME}")

    # Attach SSM managed policy
    ssm_policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    try:
        iam.attach_role_policy(RoleName=IAM_ROLE_NAME, PolicyArn=ssm_policy_arn)
        log.info("Attached AmazonSSMManagedInstanceCore")
    except ClientError as e:
        if e.response["Error"]["Code"] not in ("EntityAlreadyExists", "DuplicateException"):
            log.warning(f"Policy attach warning: {e.response['Error']['Message']}")

    # Create instance profile if not exists
    try:
        iam.create_instance_profile(
            InstanceProfileName=IAM_ROLE_NAME,
            Tags=[{"Key": "Project", "Value": PROJECT}],
        )
        log.info(f"Instance profile created: {IAM_ROLE_NAME}")
    except ClientError as e:
        if e.response["Error"]["Code"] == "EntityAlreadyExists":
            log.info(f"Instance profile already exists: {IAM_ROLE_NAME}")
        else:
            raise

    # Add role to profile (max 1 role per profile - LimitExceeded = already added)
    profile = iam.get_instance_profile(InstanceProfileName=IAM_ROLE_NAME)
    role_in_profile = any(
        r["RoleName"] == IAM_ROLE_NAME
        for r in profile["InstanceProfile"].get("Roles", [])
    )
    if not role_in_profile:
        iam.add_role_to_instance_profile(
            InstanceProfileName=IAM_ROLE_NAME, RoleName=IAM_ROLE_NAME
        )
        log.info("Role added to instance profile")
    else:
        log.info("Role already in instance profile")

    arn = profile["InstanceProfile"]["Arn"]
    patch_state("iam_instance_profile_arn", arn)
    log.info(f"Instance profile ARN: {arn}")

    log.warning(
        "ACTION REQUIRED: add the inline ALB+ACM policy to this role manually - "
        "see single-server-private-subnet-alb-acm/README.md Step 2c"
    )
    return arn


def step_ec2_instance(
    ec2, private_subnet_id: str, ec2_sg_id: str, iam_profile_arn: str, log: logging.Logger
) -> str:
    state = load_state()

    # Check for existing non-terminated instance
    if "ec2_instance_id" in state:
        iid = state["ec2_instance_id"]
        try:
            r = ec2.describe_instances(InstanceIds=[iid])
            inst_state = r["Reservations"][0]["Instances"][0]["State"]["Name"]
            if inst_state not in ("terminated", "shutting-down"):
                log.info(f"EC2 instance already exists: {iid} (state: {inst_state})")
                return iid
        except (ClientError, IndexError, KeyError):
            log.info("Previous instance not found - creating new")

    log.info(f"Creating EC2 instance (AMI: {AMI_ID}, type: {INSTANCE_TYPE})...")
    log.info("Waiting 15s for IAM instance profile to propagate...")
    time.sleep(15)

    r = ec2.run_instances(
        ImageId=AMI_ID,
        InstanceType=INSTANCE_TYPE,
        MinCount=1,
        MaxCount=1,
        SubnetId=private_subnet_id,
        SecurityGroupIds=[ec2_sg_id],
        IamInstanceProfile={"Arn": iam_profile_arn},
        BlockDeviceMappings=[{
            "DeviceName": "/dev/sda1",
            "Ebs": {
                "VolumeSize": 20,
                "VolumeType": "gp3",
                "DeleteOnTermination": True,
                "Encrypted": True,
            },
        }],
        MetadataOptions={
            "HttpTokens": "required",    # IMDSv2 only - no IMDSv1
            "HttpEndpoint": "enabled",
        },
        TagSpecifications=tagspec("instance", f"{PROJECT}-server"),
    )

    instance_id = r["Instances"][0]["InstanceId"]
    log.info(f"Instance launched: {instance_id} - waiting for running state...")

    waiter = ec2.get_waiter("instance_running")
    waiter.wait(InstanceIds=[instance_id], WaiterConfig={"Delay": 10, "MaxAttempts": 30})

    patch_state("ec2_instance_id", instance_id)
    log.info(f"EC2 instance running: {instance_id}")
    return instance_id


# ═══════════════════════════════════════════════════════════════════════════════
# CREATE ORCHESTRATOR
# ═══════════════════════════════════════════════════════════════════════════════

def create(log: logging.Logger) -> None:
    session = get_session()
    ec2     = session.client("ec2")

    log.info("=" * 64)
    log.info("Starting infrastructure creation")
    log.info(f"Profile: {AWS_PROFILE}  |  Region: {REGION}")
    log.info("=" * 64)

    vpc_id          = step_vpc(ec2, log)
    igw_id          = step_igw(ec2, vpc_id, log)
    pub_subnets, priv_subnets = step_subnets(ec2, vpc_id, log)

    step_public_rt(ec2, vpc_id, igw_id, pub_subnets, log)
    nat_gw_id       = step_nat_gw(ec2, pub_subnets[0], log)
    step_private_rt(ec2, vpc_id, nat_gw_id, priv_subnets, log)

    endpoint_sg_id  = step_endpoint_sg(ec2, vpc_id, log)
    step_vpc_endpoints(ec2, vpc_id, priv_subnets, endpoint_sg_id, log)

    ec2_sg_id       = step_ec2_sg(ec2, vpc_id, log)
    iam_profile_arn = step_iam_role(session, log)
    instance_id     = step_ec2_instance(ec2, priv_subnets[0], ec2_sg_id, iam_profile_arn, log)

    state = load_state()
    log.info("=" * 64)
    log.info("Infrastructure created successfully!")
    log.info(f"  VPC             : {state.get('vpc_id')}")
    log.info(f"  Public subnets  : {state.get('public_subnet_ids')}")
    log.info(f"  Private subnets : {state.get('private_subnet_ids')}")
    log.info(f"  NAT Gateway     : {state.get('nat_gw_id')}")
    log.info(f"  SSM Endpoints   : {list(state.get('endpoint_ids', {}).values())}")
    log.info(f"  EC2 instance    : {instance_id}")
    log.info(f"  State file      : {STATE_FILE}")
    log.info("")
    log.info("  Next steps:")
    log.info("  1. Add ALB+ACM inline policy to IAM role (README Step 2c)")
    log.info("  2. Connect via SSM Session Manager:")
    log.info(f"       aws ssm start-session --target {instance_id} --profile {AWS_PROFILE}")
    log.info("  3. Clone repo on the instance, then run deploy.sh:")
    log.info("       git clone https://github.com/sarowar-alam/bmi-health-tracker-ec2-server.git")
    log.info("       cd bmi-health-tracker-ec2-server")
    log.info(f"       ./single-server-private-subnet-alb-acm/deploy.sh bmi.ostaddevops.click \\")
    log.info(f"         {pub_subnets[0]} {pub_subnets[1]}")
    log.info("=" * 64)


# ═══════════════════════════════════════════════════════════════════════════════
# TEARDOWN (reverse order, safe even on partial state)
# ═══════════════════════════════════════════════════════════════════════════════

def _safe_delete(fn, label: str, log: logging.Logger) -> None:
    """Run fn(); log success or warning on error without aborting teardown."""
    try:
        fn()
        log.info(f"Deleted: {label}")
    except ClientError as e:
        log.warning(f"Could not delete {label}: {e.response['Error']['Code']} - {e.response['Error']['Message']}")


def teardown(log: logging.Logger) -> None:
    state = load_state()
    if not state:
        log.warning("State file empty or missing - nothing to tear down")
        return

    session = get_session()
    ec2   = session.client("ec2")
    elbv2 = session.client("elbv2")
    iam   = session.client("iam")

    log.info("=" * 64)
    log.info("Starting teardown - all tracked resources will be DESTROYED")
    log.info("=" * 64)

    # 1. Terminate EC2 instance
    if iid := state.get("ec2_instance_id"):
        log.info(f"Terminating EC2 instance {iid}...")
        _safe_delete(lambda: ec2.terminate_instances(InstanceIds=[iid]), f"EC2 {iid}", log)
        try:
            ec2.get_waiter("instance_terminated").wait(
                InstanceIds=[iid], WaiterConfig={"Delay": 10, "MaxAttempts": 30}
            )
            log.info("Instance terminated")
        except Exception as e:
            log.warning(f"Waiter: {e}")
        state.pop("ec2_instance_id", None)
        save_state(state)

    # 2. Delete VPC endpoints (takes ~30s each)
    endpoint_ids = state.get("endpoint_ids", {})
    if endpoint_ids:
        ep_list = list(endpoint_ids.values())
        log.info(f"Deleting VPC endpoints: {ep_list}")
        _safe_delete(lambda: ec2.delete_vpc_endpoints(VpcEndpointIds=ep_list), "VPC endpoints", log)
        # Poll until all deleted
        for _ in range(24):
            r = ec2.describe_vpc_endpoints(VpcEndpointIds=ep_list)
            active = [e for e in r["VpcEndpoints"] if e["State"] != "deleted"]
            if not active:
                break
            log.info(f"  Waiting for endpoints to delete ({len(active)} remaining)...")
            time.sleep(5)
        state.pop("endpoint_ids", None)
        save_state(state)

    time.sleep(5)  # brief pause for SG dependency to clear

    # 3. Delete security groups
    for key in ("endpoint_sg_id", "ec2_sg_id"):
        if sg_id := state.get(key):
            _safe_delete(lambda sg=sg_id: ec2.delete_security_group(GroupId=sg), f"SG {sg_id}", log)
            state.pop(key, None)
            save_state(state)

    # 4. Delete NAT Gateway (can take 60-90s)
    if nat_id := state.get("nat_gw_id"):
        log.info(f"Deleting NAT Gateway {nat_id} (takes ~90s)...")
        _safe_delete(lambda: ec2.delete_nat_gateway(NatGatewayId=nat_id), f"NAT GW {nat_id}", log)
        for _ in range(30):
            r = ec2.describe_nat_gateways(NatGatewayIds=[nat_id])
            nat_state = r["NatGateways"][0]["State"]
            if nat_state == "deleted":
                break
            log.info(f"  NAT GW state: {nat_state}...")
            time.sleep(10)
        log.info("NAT Gateway deleted")
        state.pop("nat_gw_id", None)
        save_state(state)

    # 5. Release Elastic IP
    if alloc_id := state.get("eip_allocation_id"):
        _safe_delete(lambda: ec2.release_address(AllocationId=alloc_id), f"EIP {alloc_id}", log)
        state.pop("eip_allocation_id", None)
        save_state(state)

    # 6. Delete route tables (disassociate subnets first)
    for key in ("private_rt_id", "public_rt_id"):
        if rt_id := state.get(key):
            try:
                r = ec2.describe_route_tables(RouteTableIds=[rt_id])
                for assoc in r["RouteTables"][0].get("Associations", []):
                    if not assoc.get("Main", False):
                        ec2.disassociate_route_table(
                            AssociationId=assoc["RouteTableAssociationId"]
                        )
            except ClientError:
                pass
            _safe_delete(lambda rid=rt_id: ec2.delete_route_table(RouteTableId=rid), f"RT {rt_id}", log)
            state.pop(key, None)
            save_state(state)

    # 6b. Delete ALB resources created by deploy.sh (not tracked in state file).
    #     These live in the public subnets and block subnet/IGW/VPC deletion.
    log.info("Checking for ALB/TG resources created by deploy.sh...")

    # Delete ALB listeners, then ALB itself
    try:
        albs = elbv2.describe_load_balancers(Names=[ALB_NAME])["LoadBalancers"]
        if albs:
            alb_arn = albs[0]["LoadBalancerArn"]
            listeners = elbv2.describe_listeners(LoadBalancerArn=alb_arn).get("Listeners", [])
            for lst in listeners:
                _safe_delete(
                    lambda l=lst["ListenerArn"]: elbv2.delete_listener(ListenerArn=l),
                    f"ALB listener {lst['ListenerArn'][-12:]}", log,
                )
            _safe_delete(
                lambda: elbv2.delete_load_balancer(LoadBalancerArn=alb_arn),
                f"ALB {ALB_NAME}", log,
            )
            log.info(f"Waiting for ALB {ALB_NAME} to be fully deleted...")
            elbv2.get_waiter("load_balancers_deleted").wait(
                LoadBalancerArns=[alb_arn],
                WaiterConfig={"Delay": 15, "MaxAttempts": 20},
            )
            log.info("ALB deleted")
        else:
            log.info(f"ALB {ALB_NAME} not found - skipping")
    except ClientError as e:
        if e.response["Error"]["Code"] != "LoadBalancerNotFound":
            log.warning(f"ALB cleanup: {e.response['Error']['Message']}")

    # Delete target group
    try:
        tgs = elbv2.describe_target_groups(Names=[TG_NAME])["TargetGroups"]
        if tgs:
            _safe_delete(
                lambda: elbv2.delete_target_group(TargetGroupArn=tgs[0]["TargetGroupArn"]),
                f"Target group {TG_NAME}", log,
            )
    except ClientError as e:
        if e.response["Error"]["Code"] != "TargetGroupNotFound":
            log.warning(f"TG cleanup: {e.response['Error']['Message']}")

    # Delete ALB security group (created by deploy.sh, named ALB_SG_NAME)
    if vpc_id_for_sg := state.get("vpc_id"):
        alb_sg = _find_sg(ec2, ALB_SG_NAME, vpc_id_for_sg)
        if alb_sg:
            _safe_delete(
                lambda sg=alb_sg: ec2.delete_security_group(GroupId=sg),
                f"ALB SG {alb_sg} ({ALB_SG_NAME})", log,
            )

    # 7. Delete subnets
    all_subnets = state.get("public_subnet_ids", []) + state.get("private_subnet_ids", [])
    for sid in all_subnets:
        _safe_delete(lambda s=sid: ec2.delete_subnet(SubnetId=s), f"subnet {sid}", log)
    state.pop("public_subnet_ids", None)
    state.pop("private_subnet_ids", None)
    save_state(state)

    # 8. Detach + delete IGW
    if (igw_id := state.get("igw_id")) and (vpc_id := state.get("vpc_id")):
        try:
            ec2.detach_internet_gateway(InternetGatewayId=igw_id, VpcId=vpc_id)
        except ClientError:
            pass
        _safe_delete(lambda: ec2.delete_internet_gateway(InternetGatewayId=igw_id), f"IGW {igw_id}", log)
        state.pop("igw_id", None)
        save_state(state)

    # 9. Delete VPC
    if vpc_id := state.get("vpc_id"):
        _safe_delete(lambda: ec2.delete_vpc(VpcId=vpc_id), f"VPC {vpc_id}", log)
        state.pop("vpc_id", None)
        save_state(state)

    # 10. Clean up IAM (optional - warn but do not auto-delete shared roles)
    log.warning(
        f"IAM role '{IAM_ROLE_NAME}' and instance profile were NOT deleted. "
        "Remove manually if no longer needed: "
        f"aws iam remove-role-from-instance-profile && "
        f"aws iam delete-instance-profile && aws iam delete-role"
    )

    log.info("=" * 64)
    log.info("Teardown complete. Remaining state keys (if any):")
    remaining = {k: v for k, v in load_state().items() if k not in ("last_updated",)}
    if remaining:
        for k, v in remaining.items():
            log.info(f"  {k}: {v}")
    else:
        log.info("  (none - all resources destroyed)")
    log.info("=" * 64)


# ═══════════════════════════════════════════════════════════════════════════════
# STATUS
# ═══════════════════════════════════════════════════════════════════════════════

def show_status(log: logging.Logger) -> None:
    state = load_state()
    if not state:
        log.info("No state file found. Run: python setup_infra.py --action create")
        return

    log.info("=" * 64)
    log.info("Tracked resource state:")
    log.info("=" * 64)
    for k, v in state.items():
        log.info(f"  {k:<30}: {v}")

    # Live EC2 check
    if iid := state.get("ec2_instance_id"):
        try:
            ec2 = get_session().client("ec2")
            r = ec2.describe_instances(InstanceIds=[iid])
            inst = r["Reservations"][0]["Instances"][0]
            log.info("")
            log.info(f"  EC2 live state   : {inst['State']['Name']}")
            log.info(f"  Private IP       : {inst.get('PrivateIpAddress', 'N/A')}")
            log.info(f"  AZ               : {inst.get('Placement', {}).get('AvailabilityZone', 'N/A')}")
            log.info("")
            log.info(f"  SSM connect: aws ssm start-session --target {iid} --profile {AWS_PROFILE}")
        except Exception as e:
            log.warning(f"Live EC2 lookup failed: {e}")
    log.info("=" * 64)


# ═══════════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

def main() -> None:
    parser = argparse.ArgumentParser(
        description="BMI Health Tracker - AWS infrastructure provisioner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Actions:
  create    Provision VPC, subnets, NAT GW, SSM endpoints, IAM role, EC2
  teardown  Destroy all resources tracked in infra_state.json
  status    Print current state and live EC2 info

Example:
  python setup_infra.py --action create
  python setup_infra.py --action status
  python setup_infra.py --action teardown
        """,
    )
    parser.add_argument(
        "--action",
        choices=["create", "teardown", "status"],
        required=True,
    )
    args = parser.parse_args()
    log  = setup_logging()

    try:
        if args.action == "create":
            create(log)
        elif args.action == "teardown":
            teardown(log)
        elif args.action == "status":
            show_status(log)
    except ClientError as e:
        log.error(
            f"AWS error: {e.response['Error']['Code']} - {e.response['Error']['Message']}"
        )
        sys.exit(1)
    except KeyboardInterrupt:
        log.warning("Interrupted by user. State file preserved for partial teardown.")
        sys.exit(1)
    except Exception as e:
        log.exception(f"Unexpected error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
