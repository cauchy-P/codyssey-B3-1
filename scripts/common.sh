# shellcheck shell=bash
# provision / verify / cleanup 이 공유하는 설정과 헬퍼.
# 환경변수로 덮어쓸 수 있다: REGION, PREFIX, PROJECT_TAG, KEY_NAME, KEY_FILE

REGION="${REGION:-ap-southeast-2}"
PREFIX="${PREFIX:-codyssey}"
PROJECT_TAG="${PROJECT_TAG:-codyssey-b6-1}"
KEY_NAME="${KEY_NAME:-$PREFIX-key}"
KEY_FILE="${KEY_FILE:-$HOME/.ssh/$KEY_NAME.pem}"

export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""

# 이 프로젝트가 만든 리소스만 골라내는 필터. 모든 리소스에 Project 태그를 붙인다.
TAG_FILTER=(--filters "Name=tag:Project,Values=$PROJECT_TAG")

log() { printf '  %s\n' "$*"; }
step() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# tagspec <resource-type> <name> → --tag-specifications 인자 문자열
tagspec() {
  printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=Project,Value=%s}]' \
    "$1" "$2" "$PROJECT_TAG"
}

# 태그가 붙은 리소스 ID 조회. 없으면 빈 문자열.
#   query_ids <describe-subcommand> <jmespath>
query_ids() {
  local out
  out=$(aws ec2 "$1" "${TAG_FILTER[@]}" --query "$2" --output text 2>/dev/null) || return 0
  printf '%s' "$out" | tr '\t' '\n' | grep -vx 'None' | grep -v '^$' || true
}

# 보안 그룹 인바운드 규칙을 판정해 "<http_public> <ssh_public> <wide_open>" 을 출력한다.
# 입력: 한 줄에 "<프로토콜> <시작포트> <끝포트> <CIDR 목록(쉼표 구분)>"
#   http_public  80/tcp 이 0.0.0.0/0 에 열려 있는가            (열려 있어야 정상)
#   ssh_public   22/tcp 이 0.0.0.0/0 에 노출되었는가            (노출되면 위반)
#   wide_open    0.0.0.0/0 에 전체 포트를 허용하는 규칙이 있는가 (있으면 위반)
evaluate_sg_rules() {
  local http_public=no ssh_public=no wide_open=no
  local proto from to cidrs
  while read -r proto from to cidrs; do
    [[ -n ${proto:-} ]] || continue
    case ",${cidrs:-}," in
      *,0.0.0.0/0,*) ;;
      *) continue ;;                                # 전체 공개 규칙만 검사 대상
    esac
    if [[ $proto == tcp && $from =~ ^[0-9]+$ && $to =~ ^[0-9]+$ ]]; then
      (( from == 80 && to == 80 )) && http_public=yes
      (( from <= 22 && to >= 22 )) && ssh_public=yes
      (( from == 0 && to == 65535 )) && wide_open=yes
    fi
    [[ $proto == '-1' ]] && wide_open=yes            # 모든 프로토콜/포트 허용
  done <<< "$1"
  printf '%s %s %s\n' "$http_public" "$ssh_public" "$wide_open"
}

require_aws() {
  command -v aws >/dev/null 2>&1 || die "AWS CLI가 필요합니다. https://aws.amazon.com/cli/"
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "AWS 자격 증명이 설정되지 않았습니다. aws configure 를 먼저 실행하세요."
}
