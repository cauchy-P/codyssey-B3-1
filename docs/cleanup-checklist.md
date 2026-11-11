# AWS 리소스 정리 기록과 확인 절차

이 문서는 실습 리소스의 삭제 결과와, 프로젝트 태그를 기준으로 다시 확인할 때 사용할 AWS CLI 명령을 함께 담는다. 실제 기록과 재사용 절차를 구분해 읽을 수 있도록 먼저 실행 당시의 정보를 밝힌다.

## 실행 기록의 범위

- 정리 일시: 2026-09-20
- 기록된 리전: `ap-northeast-2`
- 프로젝트 태그: `Project=codyssey-b6-1`
- 수행 방식: AWS CLI를 이용한 수동 삭제

이 기록은 원본 서울 리전 실행의 결과다. 현재 저장소 사본의 배포 설정은 시드니 `ap-southeast-2`로 조정되어 있다. 아래 재확인 명령은 시드니에서 실행할 수 있도록 설정하지만, 그 자체가 시드니 배포나 삭제가 실제로 이루어졌다는 증거는 아니다.

삭제에 앞서 외부 접속 성공 화면, 아키텍처 다이어그램, README의 접속 확인 내용, 트러블슈팅 기록을 보관했는지 확인했다.

## 삭제 순서와 결과

삭제는 의존 관계를 고려해 진행했다.

```text
EC2 종료
→ EBS 삭제 확인
→ Elastic IP 확인
→ Route Table 연결 해제 및 삭제
→ Internet Gateway Detach 및 삭제
→ Public Subnet 삭제
→ Security Group 삭제
→ VPC 삭제
→ AWS Key Pair 삭제
→ 로컬 Private Key 삭제
```

아래 표는 당시 기록에 남은 결과다.

| 항목 | 결과 | 비고 |
|---|---|---|
| EC2 인스턴스 | ✅ 종료 | 상태 `terminated` 확인 |
| EBS 볼륨 | ✅ 삭제 | `DeleteOnTermination=true`로 EC2 종료 시 자동 삭제 |
| Elastic IP | ✅ 없음 | 이번 실습에서는 생성하지 않음 |
| Route Table | ✅ 삭제 | Subnet 연결 해제 후 삭제 |
| Internet Gateway | ✅ 삭제 | VPC에서 Detach 후 삭제 |
| Public Subnet | ✅ 삭제 | 프로젝트 Subnet 삭제 |
| Security Group | ✅ 삭제 | `codyssey-web-sg` 삭제 |
| VPC | ✅ 삭제 | 프로젝트 VPC 삭제 |
| AWS Key Pair | ✅ 삭제 | `codyssey-key` 삭제 |
| 로컬 Private Key | ✅ 삭제 | `~/.ssh/codyssey-key.pem` 삭제 |
| NAT Gateway | 해당 없음 | 생성하지 않음 |
| ELB / ALB | 해당 없음 | 생성하지 않음 |
| RDS | 해당 없음 | 생성하지 않음 |

## 재확인용 CLI 절차

아래 명령들은 지정한 리전에서 같은 프로젝트 태그를 가진 리소스를 찾고, 필요할 때 정리하는 절차다. 여기서 리전을 시드니로 설정하는 것은 현재 프로젝트 구성에 맞추기 위한 것이며, 위의 2026-09-20 기록을 시드니 기록으로 바꾸지는 않는다.

```bash
export AWS_DEFAULT_REGION=ap-southeast-2
PROJECT_TAG=codyssey-b6-1
```

### 1. EC2 종료 상태 확인

실행 중이거나 전환 중인 프로젝트 인스턴스를 조회해 종료하고, `terminated` 상태가 반환되는지 확인한다.

```bash
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"

aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text
```

조회 결과가 `terminated`이면 EC2 종료가 완료된 것이다.

### 2. EBS 잔여 볼륨 확인

루트 볼륨은 `DeleteOnTermination=true` 설정에 따라 EC2 종료 때 자동 삭제된다. 프로젝트 태그로 볼륨을 조회한다. `available` 볼륨이 남아 있다면 해당 볼륨을 삭제한다.

```bash
VOLUME_ID=$(aws ec2 describe-volumes \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
            "Name=status,Values=available" \
  --query 'Volumes[0].VolumeId' --output text)

aws ec2 describe-volumes \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Volumes[].VolumeId' --output json
```

```bash
aws ec2 delete-volume --volume-id "$VOLUME_ID"
```

### 3. Elastic IP 확인

이번 실습에서는 Elastic IP를 만들지 않았다. 조회 결과가 빈 배열인지 확인하고, Allocation ID가 있다면 릴리스한다.

```bash
ALLOCATION_ID=$(aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Addresses[0].AllocationId' --output text)

aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Addresses[].AllocationId' --output json
```

```bash
aws ec2 release-address --allocation-id "$ALLOCATION_ID"
```

### 4. Route Table 연결 해제와 삭제

전용 Route Table을 찾아 Main이 아닌 association을 해제한 다음 Route Table을 삭제하고, 태그 조회 결과를 확인한다.

```bash
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'RouteTables[0].RouteTableId' --output text)

ASSOCIATION_ID=$(aws ec2 describe-route-tables \
  --route-table-ids "$ROUTE_TABLE_ID" \
  --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId | [0]' \
  --output text)

aws ec2 disassociate-route-table --association-id "$ASSOCIATION_ID"
aws ec2 delete-route-table --route-table-id "$ROUTE_TABLE_ID"

aws ec2 describe-route-tables \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'RouteTables[].RouteTableId' --output json
```

### 5. Internet Gateway 분리와 삭제

태그로 VPC와 IGW를 찾는다. 먼저 VPC에서 IGW를 분리한 뒤 삭제하고, 남은 IGW가 없는지 조회한다.

```bash
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[0].VpcId' --output text)

IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'InternetGateways[0].InternetGatewayId' --output text)

aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"

aws ec2 describe-internet-gateways \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'InternetGateways[].InternetGatewayId' --output json
```

### 6. Subnet과 Security Group 삭제

Route Table 연결과 EC2 사용이 끝난 뒤 Public Subnet을 삭제한다. 이어 프로젝트용 `codyssey-web-sg`를 찾아 삭제하고 잔여 Security Group을 확인한다.

```bash
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Subnets[0].SubnetId' --output text)

aws ec2 delete-subnet --subnet-id "$SUBNET_ID"

aws ec2 describe-subnets \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Subnets[].SubnetId' --output json
```

```bash
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
            "Name=group-name,Values=codyssey-web-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

aws ec2 delete-security-group --group-id "$SECURITY_GROUP_ID"

aws ec2 describe-security-groups \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'SecurityGroups[].GroupId' --output json
```

### 7. VPC와 AWS Key Pair 삭제

의존 리소스를 정리한 뒤 VPC를 삭제한다. AWS에 등록된 Key Pair도 제거하고 조회 결과가 비었는지 확인한다.

```bash
aws ec2 delete-vpc --vpc-id "$VPC_ID"

aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' --output json
```

조회 결과가 `[]`이면 AWS Key Pair가 삭제된 것이다.

```bash
aws ec2 delete-key-pair --key-name codyssey-key

aws ec2 describe-key-pairs \
  --filters "Name=key-name,Values=codyssey-key" \
  --query 'KeyPairs[].KeyName' --output json
```

### 8. 로컬 개인키 삭제

AWS Key Pair를 지워도 로컬에 내려받은 개인키 파일은 별도로 남는다. 필요가 끝난 로컬 WSL 키 파일도 삭제하고 존재하지 않는지 확인한다.

```bash
rm -f -- "$HOME/.ssh/codyssey-key.pem"
test ! -e ~/.ssh/codyssey-key.pem && echo "로컬 Private Key 삭제 완료"
```

각 AWS 리소스 조회 결과가 빈 배열 `[]`이면 해당 리소스의 정리가 확인된 것이다. `terminated` 상태의 EC2 기록은 약 1시간 동안 조회될 수 있지만 더 이상 과금되지 않는다.

## 리소스별 기록 보충

### EBS

EC2 루트 볼륨은 다음 옵션으로 생성했다.

```text
DeleteOnTermination=true
```

따라서 인스턴스를 종료하면서 루트 EBS도 함께 삭제되었다. 프로젝트 태그로 추가 조회한 결과 남은 볼륨이 없었다고 기록되어 있다.

### Elastic IP

별도 Elastic IP는 만들지 않았다. Public Subnet에서 자동 할당되는 Public IPv4를 사용했으므로 릴리스할 Elastic IP는 없었다.

### 키페어

SSH에 사용한 AWS Key Pair의 이름은 `codyssey-key`다. AWS 측 키페어를 삭제한 뒤, 로컬 WSL에 보관하던 `~/.ssh/codyssey-key.pem`도 직접 지웠다.

## 최종 체크리스트

아래 항목은 원문에 완료 표시로 기록되어 있다.

- [x] 외부 접속 성공 스크린샷 저장
- [x] 아키텍처 다이어그램 저장
- [x] 트러블슈팅 기록 저장
- [x] README 검증 내용 작성
- [x] EC2 종료
- [x] EBS 삭제 확인
- [x] Elastic IP 미사용 확인
- [x] Route Table 삭제
- [x] Internet Gateway Detach 및 삭제
- [x] Public Subnet 삭제
- [x] Security Group 삭제
- [x] VPC 삭제
- [x] AWS Key Pair 삭제
- [x] 로컬 Private Key 삭제
- [x] Billing Dashboard 최종 확인

프로젝트 개요와 `cleanup.sh` 자동화 설명은 [README](../README.md)에, 네트워크 범위 해석은 [IPv4와 CIDR 안내](addressing.md)에 정리되어 있다.


## 추가 원문 명령 블록

```text
codyssey-key
```

```text
~/.ssh/codyssey-key.pem
```
