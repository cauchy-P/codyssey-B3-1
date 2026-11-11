#!/usr/bin/env bash
# common.sh 의 evaluate_sg_rules 단위 테스트. AWS 호출 없이 실행된다.
#   bash scripts/test-sg-rules.sh
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
source scripts/common.sh

failed=0

case_() { # case_ <설명> <기대: "http ssh wide"> <규칙 텍스트>
  local got
  got=$(evaluate_sg_rules "$3")
  if [[ $got == "$2" ]]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s → %s (기대 %s)\n' "$1" "$got" "$2"
    failed=$((failed + 1))
  fi
}

case_ '정상 구성: 80 공개 + 22 는 내 IP' 'yes no no' \
"tcp	80	80	0.0.0.0/0
tcp	22	22	203.0.113.10/32"

case_ '위반: 22 를 전체 공개' 'yes yes no' \
"tcp	80	80	0.0.0.0/0
tcp	22	22	0.0.0.0/0"

case_ '위반: 0-65535 전체 포트 개방' 'no yes yes' \
"tcp	0	65535	0.0.0.0/0"

case_ '위반: 모든 프로토콜 개방' 'no no yes' \
"-1	None	None	0.0.0.0/0"

case_ '미완: 80 규칙 누락' 'no no no' \
"tcp	22	22	203.0.113.10/32"

case_ '여러 CIDR 중 하나가 전체 공개' 'yes no no' \
"tcp	80	80	10.0.0.0/8,0.0.0.0/0"

printf '\n%s\n' "$([[ $failed -eq 0 ]] && echo '전체 통과' || echo "${failed}건 실패")"
exit $(( failed > 0 ))
