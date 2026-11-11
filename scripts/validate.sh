#!/usr/bin/env bash
# 과제 기능 요구사항을 그대로 검증한다. 결과는 docs/validation.log 에 남는다.
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/shared.sh
source scripts/shared.sh

LOG_FILE="${LOG_FILE:-docs/validation.log}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)

pass=0
fail=0

check() { # check <항목> <기대값> <실제값>
  if [[ "$3" == "$2" ]]; then
    printf '  PASS  %-40s %s\n' "$1" "$3"
    pass=$((pass + 1))
  else
    printf '  FAIL  %-40s %s   (기대: %s)\n' "$1" "$3" "$2"
    fail=$((fail + 1))
  fi
}

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1"; }

main() {
  require_aws
  printf '검증 시각: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

  local instance ip subnet rtb sg
  instance=$(query_ids describe-instances \
    "Reservations[].Instances[?State.Name=='running'].InstanceId" | head -n1)
  [[ -n $instance ]] || die "running 상태의 $PROJECT_TAG 인스턴스가 없습니다."
  ip=$(aws ec2 describe-instances --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  subnet=$(query_ids describe-subnets 'Subnets[].SubnetId' | head -n1)
  rtb=$(query_ids describe-route-tables 'RouteTables[].RouteTableId' | head -n1)
  sg=$(query_ids describe-security-groups 'SecurityGroups[].GroupId' | head -n1)
  printf '대상: %s  /  %s  /  퍼블릭 IPv4 %s\n' "$instance" "$subnet" "$ip"

  step '1. 네트워크 구성'
  check '라우트 0.0.0.0/0 대상' 'igw' "$(aws ec2 describe-route-tables \
    --route-table-ids "$rtb" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" \
    --output text | cut -d- -f1)"
  check '서브넷 퍼블릭 IPv4 자동 할당' 'True' "$(aws ec2 describe-subnets \
    --subnet-ids "$subnet" --query 'Subnets[0].MapPublicIpOnLaunch' --output text)"

  step '2. 접근 제어 (보안 그룹 인바운드)'
  local rules http_public ssh_public wide_open
  rules=$(aws ec2 describe-security-groups --group-ids "$sg" \
    --query "SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,join(',',IpRanges[].CidrIp)]" \
    --output text)
  read -r http_public ssh_public wide_open <<< "$(evaluate_sg_rules "$rules")"
  check 'HTTP 80 ← 0.0.0.0/0 허용' 'yes' "$http_public"
  check 'SSH 22 ← 0.0.0.0/0 노출' 'no' "$ssh_public"
  check '0.0.0.0/0 전체 포트 허용 규칙' 'no' "$wide_open"

  step '3. 외부 접속 검증'
  check "GET http://$ip/" '200' "$(http_code "http://$ip/")"
  check "GET http://$ip/health" '200' "$(http_code "http://$ip/health")"
  check '/health 응답 본문' 'OK' "$(curl -s --max-time 10 "http://$ip/health" | tr -d '\r\n')"

  step '4. 인스턴스 내부 상태 (SSH)'
  local remote
  if [[ -f $KEY_FILE ]]; then
    remote=$(ssh -i "$KEY_FILE" "${SSH_OPTS[@]}" "ubuntu@$ip" '
      systemctl is-active nginx
      curl -s -o /dev/null -w "%{http_code}\n" http://localhost
      curl -s -o /dev/null -w "%{http_code}\n" https://example.com
    ' 2>/dev/null)
  else
    remote=''
    log "키 파일 없음: $KEY_FILE"
  fi
  # macOS 기본 Bash 3.2에는 mapfile이 없으므로 read 루프로 줄을 수집한다.
  local line
  local -a r=()
  while IFS= read -r line; do
    r[${#r[@]}]="$line"
  done <<< "$remote"
  check 'nginx 서비스 상태' 'active' "${r[0]:-unreachable}"
  check 'curl http://localhost' '200' "${r[1]:-unreachable}"
  check 'curl https://example.com (아웃바운드)' '200' "${r[2]:-unreachable}"

  printf '\n결과: %d개 통과 / %d개 실패\n' "$pass" "$fail"
  [[ $fail -eq 0 ]] || log '실패 항목은 docs/issues.md 의 진단 절차를 따른다.'
  return $((fail > 0))
}

mkdir -p "$(dirname "$LOG_FILE")"
main 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
