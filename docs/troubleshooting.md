# 트러블슈팅 보고서

## macOS 기본 Bash에서 검증 스크립트의 mapfile 실행 실패

### 증상

시드니 리전(`ap-southeast-2`)에 인프라를 생성한 뒤 다음 명령으로 검증했다.

```bash
bash scripts/verify.sh
```

네트워크 구성, 보안 그룹, 외부 HTTP 접속 검증은 통과했지만 인스턴스 내부 상태를 확인하는 단계에서 다음 오류가 발생했다.

```text
[17:51:11] 4. 인스턴스 내부 상태 (SSH)
scripts/verify.sh: line 76: mapfile: command not found
  FAIL  nginx 서비스 상태                   unreachable   (기대: active)
  FAIL  curl http://localhost                    unreachable   (기대: 200)
  FAIL  curl https://example.com (아웃바운드) unreachable   (기대: 200)

결과: 8개 통과 / 3개 실패
```

### 원인

macOS 기본 Bash는 3.2 버전이며, 기존 스크립트에서 사용한 `mapfile`은 Bash 4 이상에서 지원한다.

검증 스크립트는 SSH로 받은 여러 줄의 응답을 `mapfile`로 배열에 저장하고 각 항목을 비교하도록 작성되어 있었다. 이 명령이 로컬에서 실행되지 않아 응답을 배열에 저장하지 못했고, 마지막 세 항목이 기본값인 `unreachable`로 표시됐다.

따라서 이 결과만으로 Nginx, SSH 또는 아웃바운드 통신이 실제로 실패했다고 판단할 수는 없다. 앞선 외부 접속 검증에서는 `/`와 `/health`가 HTTP 200을 반환하고 `/health` 본문이 `OK`인 것을 확인했다.

### 해결 방법

`scripts/verify.sh`에서 `mapfile`을 Bash 3.2에서도 동작하는 `while`과 `read` 반복문으로 교체했다.

수정 전:

```bash
mapfile -t r <<< "$remote"
```

수정 후:

```bash
# macOS 기본 Bash 3.2에는 mapfile이 없으므로 read 루프로 줄을 수집한다.
local line
local -a r=()
while IFS= read -r line; do
  r[${#r[@]}]="$line"
done <<< "$remote"
```

`IFS=`와 `read -r`로 각 줄의 공백과 역슬래시를 보존하고, 현재 셸에서 배열을 채워 이후 검증에 사용하도록 했다. 인프라를 다시 생성하거나 Bash를 별도로 설치할 필요는 없다.

### 수정 확인

- `/bin/bash -n scripts/verify.sh`로 셸 문법 검사를 통과했다.
- Bash `3.2.57(1)-release`에서 수정한 응답 파싱 구문을 검사했다.
- 정상 응답(`active`, `200`, `200`), 빈 응답, 실패 응답(`inactive`, `500`, `000`)을 각각 예상대로 처리하는 것을 확인했다.

위 검사는 로컬 문법과 응답 처리에 대한 확인이다. 수정 후 실제 AWS 인스턴스를 대상으로 한 전체 검증 결과는 아직 확인하지 않았다.

### 재검증

프로젝트 디렉터리에서 다음 명령을 다시 실행한다.

```bash
bash scripts/verify.sh
```

실행 결과는 `docs/verification.log`에 기록된다. 마지막 세 항목이 계속 실패하면 해당 결과를 기준으로 SSH 접속, Nginx 서비스 및 아웃바운드 통신을 추가로 점검한다.
