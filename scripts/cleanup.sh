#!/usr/bin/env bash
# provision.sh 가 만든 리소스를 의존 관계 역순으로 삭제한다.
# 옵션: --keep-key  (키페어 유지)
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
source scripts/common.sh

keep_key=no
[[ ${1:-} == --keep-key ]] && keep_key=yes

require_aws

step '1. EC2 인스턴스 종료'
instances=$(query_ids describe-instances \
  "Reservations[].Instances[?State.Name!='terminated'].InstanceId")
if [[ -n $instances ]]; then
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --instance-ids $instances >/dev/null
  log "terminate 요청: $(echo "$instances" | tr '\n' ' ')— terminated 대기"
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --instance-ids $instances
  log '종료 완료'
else
  log '대상 없음'
fi

step '2. Elastic IP 릴리스'
allocs=$(query_ids describe-addresses 'Addresses[].AllocationId')
if [[ -n $allocs ]]; then
  while read -r id; do
    aws ec2 release-address --allocation-id "$id" && log "released $id"
  done <<< "$allocs"
else
  log '할당된 Elastic IP 없음'
fi

step '3. 잔여 EBS 볼륨 삭제'
volumes=$(query_ids describe-volumes "Volumes[?State=='available'].VolumeId")
if [[ -n $volumes ]]; then
  while read -r id; do
    aws ec2 delete-volume --volume-id "$id" && log "deleted $id"
  done <<< "$volumes"
else
  log '미사용 볼륨 없음 (DeleteOnTermination 으로 함께 삭제됨)'
fi

step '4. 라우트 테이블 연결 해제 및 삭제'
rtbs=$(query_ids describe-route-tables 'RouteTables[].RouteTableId')
for rtb in $rtbs; do
  assocs=$(aws ec2 describe-route-tables --route-table-ids "$rtb" \
    --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text)
  for assoc in $assocs; do
    [[ $assoc == None ]] && continue
    aws ec2 disassociate-route-table --association-id "$assoc" && log "disassociated $assoc"
  done
  aws ec2 delete-route-table --route-table-id "$rtb" && log "deleted $rtb"
done
[[ -n $rtbs ]] || log '대상 없음'

step '5. 인터넷 게이트웨이 detach 및 삭제'
igws=$(query_ids describe-internet-gateways 'InternetGateways[].InternetGatewayId')
for igw in $igws; do
  vpc=$(aws ec2 describe-internet-gateways --internet-gateway-ids "$igw" \
    --query 'InternetGateways[0].Attachments[0].VpcId' --output text)
  [[ $vpc != None ]] && aws ec2 detach-internet-gateway \
    --internet-gateway-id "$igw" --vpc-id "$vpc" && log "detached $igw ← $vpc"
  aws ec2 delete-internet-gateway --internet-gateway-id "$igw" && log "deleted $igw"
done
[[ -n $igws ]] || log '대상 없음'

step '6. 서브넷 삭제'
subnets=$(query_ids describe-subnets 'Subnets[].SubnetId')
for subnet in $subnets; do
  aws ec2 delete-subnet --subnet-id "$subnet" && log "deleted $subnet"
done
[[ -n $subnets ]] || log '대상 없음'

step '7. 보안 그룹 삭제'
sgs=$(query_ids describe-security-groups "SecurityGroups[?GroupName!='default'].GroupId")
for sg in $sgs; do
  aws ec2 delete-security-group --group-id "$sg" && log "deleted $sg"
done
[[ -n $sgs ]] || log '대상 없음'

step '8. VPC 삭제'
vpcs=$(query_ids describe-vpcs 'Vpcs[].VpcId')
for vpc in $vpcs; do
  aws ec2 delete-vpc --vpc-id "$vpc" && log "deleted $vpc"
done
[[ -n $vpcs ]] || log '대상 없음'

step '9. 키페어'
if [[ $keep_key == yes ]]; then
  log "유지 (--keep-key): $KEY_NAME"
elif aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  aws ec2 delete-key-pair --key-name "$KEY_NAME" && log "deleted $KEY_NAME"
  log "로컬 개인키는 직접 삭제: $KEY_FILE"
else
  log '대상 없음'
fi

step '남은 리소스 확인'
for pair in \
  'describe-instances|Reservations[].Instances[].[InstanceId,State.Name]' \
  'describe-volumes|Volumes[].VolumeId' \
  'describe-addresses|Addresses[].PublicIp' \
  'describe-internet-gateways|InternetGateways[].InternetGatewayId' \
  'describe-subnets|Subnets[].SubnetId' \
  'describe-route-tables|RouteTables[].RouteTableId' \
  'describe-security-groups|SecurityGroups[].GroupId' \
  'describe-vpcs|Vpcs[].VpcId'; do
  cmd=${pair%%|*}; q=${pair#*|}
  printf '  %-32s %s\n' "${cmd#describe-}" "$(query_ids "$cmd" "$q" | tr '\n' ' ')"
done

cat <<'EOF'

instances 항목이 terminated 이고 나머지가 비어 있으면 정리 완료다.
terminated 인스턴스 기록은 약 1시간 후 목록에서 사라지며 과금되지 않는다.
마지막으로 Billing and Cost Management 대시보드에서 당월 청구액을 확인한다.
EOF
