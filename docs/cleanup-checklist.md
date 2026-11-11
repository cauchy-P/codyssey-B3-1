# AWS 리소스 정리 체크리스트

- 정리 일시: 2026-09-20
- 리전: `ap-northeast-2`
- 프로젝트 태그: `Project=codyssey-b6-1`
- 정리 방식: AWS CLI를 이용한 수동 삭제

---

## 1. 정리 목적

AWS 실습이 끝난 후 생성한 리소스를 그대로 두면 불필요한 비용이 발생할 수 있으므로,
실습에서 생성한 AWS 리소스를 의존 관계에 맞는 순서로 삭제했다.

삭제 전 다음 자료가 저장되어 있는지 확인했다.

- 외부 접속 성공 스크린샷
- 아키텍처 다이어그램
- README 외부 접속 검증 내용
- 트러블슈팅 기록

---

## 2. 삭제 순서

리소스 간 의존 관계를 고려해 다음 순서로 정리했다.

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

---

## 3. 정리 결과

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

---

## 4. 수동 검증 명령어

아래 명령은 리소스의 의존 관계를 고려한 실제 삭제 순서이다. 현재 시드니 실습을 정리할 때는 아래 리전과 프로젝트 태그를 설정한다. 위의 정리 기록은 원본 서울 리전 실행 기록이다.

```bash
export AWS_DEFAULT_REGION=ap-southeast-2
PROJECT_TAG=codyssey-b6-1
```

### 4-1. EC2 인스턴스 종료

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

조회 결과가 `terminated`이면 종료가 완료된 것이다.

### 4-2. EBS 볼륨 삭제 확인

루트 EBS는 `DeleteOnTermination=true`이므로 EC2와 함께 자동 삭제된다. 남은 볼륨을 먼저 조회한다.

```bash
VOLUME_ID=$(aws ec2 describe-volumes \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
            "Name=status,Values=available" \
  --query 'Volumes[0].VolumeId' --output text)

aws ec2 describe-volumes \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Volumes[].VolumeId' --output json
```

결과가 `[]`가 아니고 `available` 상태의 볼륨이 남아 있다면 각 볼륨을 삭제한다.

```bash
aws ec2 delete-volume --volume-id "$VOLUME_ID"
```

### 4-3. Elastic IP 확인 및 릴리스

이번 실습에서는 Elastic IP를 생성하지 않았으므로 조회 결과가 `[]`인지 확인했다.

```bash
ALLOCATION_ID=$(aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Addresses[0].AllocationId' --output text)

aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Addresses[].AllocationId' --output json
```

만약 Allocation ID가 출력되면 다음과 같이 릴리스한다.

```bash
aws ec2 release-address --allocation-id "$ALLOCATION_ID"
```

### 4-4. Route Table 연결 해제 및 삭제

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

### 4-5. Internet Gateway 분리 및 삭제

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

### 4-6. Public Subnet 삭제

```bash
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Subnets[0].SubnetId' --output text)

aws ec2 delete-subnet --subnet-id "$SUBNET_ID"

aws ec2 describe-subnets \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Subnets[].SubnetId' --output json
```

### 4-7. Security Group 삭제

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

### 4-8. VPC 삭제

```bash
aws ec2 delete-vpc --vpc-id "$VPC_ID"

aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' --output json
```

### 4-9. AWS Key Pair 삭제

```bash
aws ec2 delete-key-pair --key-name codyssey-key

aws ec2 describe-key-pairs \
  --filters "Name=key-name,Values=codyssey-key" \
  --query 'KeyPairs[].KeyName' --output json
```

조회 결과가 `[]`이면 AWS Key Pair가 삭제된 것이다.

### 4-10. 로컬 Private Key 삭제

```bash
rm -f -- "$HOME/.ssh/codyssey-key.pem"
test ! -e ~/.ssh/codyssey-key.pem && echo "로컬 Private Key 삭제 완료"
```

각 AWS 리소스의 최종 조회 결과가 빈 배열 `[]`이면 정리가 완료된 것이다. `terminated` EC2 기록은 약 1시간 동안 조회될 수 있지만 더 이상 과금되지 않는다.

---

## 5. EBS 정리

EC2의 루트 EBS 볼륨은 생성 시 다음과 같이 설정했다.

```text
DeleteOnTermination=true
```

따라서 EC2를 종료하면서 루트 EBS도 함께 삭제되었다.

삭제 후 프로젝트 태그로 EBS를 조회했으며 남은 볼륨이 없음을 확인했다.

---

## 6. Elastic IP

이번 실습에서는 별도의 Elastic IP를 생성하지 않았다.

Public Subnet에서 EC2에 자동으로 할당된 Public IPv4 주소를 사용했기 때문에
별도로 Release할 Elastic IP는 없었다.

---

## 7. Key Pair 정리

EC2 SSH 접속에 사용한 AWS Key Pair:

```text
codyssey-key
```

를 AWS에서 삭제했다.

AWS Key Pair 삭제와 별개로 로컬 WSL에 저장되어 있던 Private Key:

```text
~/.ssh/codyssey-key.pem
```

도 더 이상 필요하지 않아 직접 삭제했다.

---

## 8. 최종 체크리스트

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
