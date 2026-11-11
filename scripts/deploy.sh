#!/usr/bin/env bash
# VPC → 서브넷 → IGW → 라우트 테이블 → 보안 그룹 → EC2 순서로 인프라를 생성한다.
# 생성 순서는 의존 관계를 따르며, cleanup.sh 는 정확히 역순으로 삭제한다.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/shared.sh
source scripts/shared.sh

VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.0.1.0/24}"
AZ="${AZ:-${REGION}a}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"   # 계정·리전별 대상 유형을 확인하고 INSTANCE_TYPE으로 지정
VOLUME_SIZE="${VOLUME_SIZE:-8}"

require_aws
[[ -f infra/bootstrap.sh ]] || die "infra/bootstrap.sh 를 찾을 수 없습니다."

# SSH 인바운드는 실행 시점의 공인 IP 한 개(/32)만 허용한다.
SSH_CIDR="${SSH_CIDR:-$(curl -fsS https://checkip.amazonaws.com)/32}"
[[ $SSH_CIDR =~ ^[0-9.]+/32$ ]] || die "SSH_CIDR 형식이 올바르지 않습니다: $SSH_CIDR"

[[ -z "$(query_ids describe-vpcs 'Vpcs[].VpcId')" ]] \
  || die "이미 $PROJECT_TAG 태그의 VPC가 있습니다. scripts/cleanup.sh 로 먼저 정리하세요."

step "VPC 생성 ($VPC_CIDR)"
vpc=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
  --tag-specifications "$(tagspec vpc "$PREFIX-vpc")" \
  --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id "$vpc" --enable-dns-hostnames
log "$vpc"

step "퍼블릭 서브넷 생성 ($SUBNET_CIDR, $AZ)"
subnet=$(aws ec2 create-subnet --vpc-id "$vpc" --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications "$(tagspec subnet "$PREFIX-public-subnet-a")" \
  --query Subnet.SubnetId --output text)
# 퍼블릭 IP 자동 할당. 이 설정이 없으면 인스턴스에 공인 IP가 붙지 않는다.
aws ec2 modify-subnet-attribute --subnet-id "$subnet" --map-public-ip-on-launch
log "$subnet (퍼블릭 IPv4 자동 할당 ON)"

step "인터넷 게이트웨이 생성 및 VPC 연결"
igw=$(aws ec2 create-internet-gateway \
  --tag-specifications "$(tagspec internet-gateway "$PREFIX-igw")" \
  --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc"
log "$igw → $vpc"

step "라우트 테이블 생성 (0.0.0.0/0 → IGW)"
rtb=$(aws ec2 create-route-table --vpc-id "$vpc" \
  --tag-specifications "$(tagspec route-table "$PREFIX-public-rtb")" \
  --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id "$rtb" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw" >/dev/null
aws ec2 associate-route-table --route-table-id "$rtb" --subnet-id "$subnet" >/dev/null
log "$rtb ↔ $subnet"

step "보안 그룹 생성 (80 ← 0.0.0.0/0, 22 ← $SSH_CIDR)"
sg=$(aws ec2 create-security-group --vpc-id "$vpc" \
  --group-name "$PREFIX-web-sg" \
  --description "HTTP from anywhere, SSH from operator IP only" \
  --tag-specifications "$(tagspec security-group "$PREFIX-web-sg")" \
  --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$sg" --ip-permissions \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTP public}]" \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$SSH_CIDR,Description=SSH operator only}]" \
  >/dev/null
log "$sg"

step "키페어 확인"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  [[ -f $KEY_FILE ]] || die "AWS에 $KEY_NAME 키페어가 있으나 로컬 $KEY_FILE 이 없습니다. 개인키는 재발급되지 않으므로 키페어를 삭제하고 다시 실행하세요."
  log "기존 키페어 재사용: $KEY_NAME"
else
  mkdir -p "$(dirname "$KEY_FILE")"
  aws ec2 create-key-pair --key-name "$KEY_NAME" \
    --tag-specifications "$(tagspec key-pair "$KEY_NAME")" \
    --query KeyMaterial --output text > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  log "생성: $KEY_FILE (재발급 불가, 별도 보관 필요)"
fi

step "최신 Ubuntu 24.04 LTS AMI 조회"
ami=$(aws ec2 describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
[[ $ami == ami-* ]] || die "AMI 조회 실패"
log "$ami"

step "EC2 인스턴스 생성 ($INSTANCE_TYPE, gp3 ${VOLUME_SIZE}GiB)"
instance=$(aws ec2 run-instances \
  --image-id "$ami" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id "$subnet" \
  --security-group-ids "$sg" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --block-device-mappings \
    "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --user-data file://infra/bootstrap.sh \
  --tag-specifications "$(tagspec instance "$PREFIX-web")" \
                       "$(tagspec volume "$PREFIX-web-root")" \
  --query 'Instances[0].InstanceId' --output text)
log "$instance — running 대기"
aws ec2 wait instance-running --instance-ids "$instance"

public_ip=$(aws ec2 describe-instances --instance-ids "$instance" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

cat <<EOF

생성 완료
  VPC             $vpc
  Subnet          $subnet
  Internet GW     $igw
  Route Table     $rtb
  Security Group  $sg
  Instance        $instance
  Public IPv4     $public_ip

다음 단계
  1. user-data(Nginx 설치)가 끝날 때까지 1~2분 대기
  2. scripts/validate.sh          # 요구사항 검증 + docs/validation.log 기록
  3. ssh -i $KEY_FILE ubuntu@$public_ip
  4. 실습 종료 후 scripts/cleanup.sh   # 과금 방지
EOF
