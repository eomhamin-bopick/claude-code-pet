#!/bin/bash
# 한 줄 설치 (릴리스 태그로 고정):
#   curl -fsSL https://raw.githubusercontent.com/eomhamin-bopick/claude-code-pet/v0.1.0/bootstrap.sh | bash
# 옵션을 넘기려면:  ... | bash -s -- --pet jelly --dry-run
#
# 저장소를 임시 폴더에 내려받아 install.sh 를 실행하고, 끝나면 임시 폴더를 지웁니다.
# 이 스크립트는 내려받은 파일의 서명이나 체크섬을 검증하지 않습니다. 받은 압축 파일의 SHA-256 만 보여 줍니다.
# 내용을 먼저 확인하고 싶으면 git clone 후 ./install.sh --dry-run 을 쓰세요.
#
# 환경변수: CLAUDE_PET_REPO (소유자/이름), CLAUDE_PET_REF (태그, 브랜치, 커밋 SHA)
#
# 전체를 함수로 감싸 둔 이유: 파이프로 받다가 중간에 끊겨도 반쪽짜리 스크립트가 실행되지 않게 하려는 것.
set -euo pipefail

main() {
  local repo="${CLAUDE_PET_REPO:-eomhamin-bopick/claude-code-pet}"
  local ref="${CLAUDE_PET_REF:-v0.1.0}"

  # URL 에 그대로 들어가므로 안전한 글자만 허용한다 ('..' 로 다른 경로를 가리키는 것도 막는다)
  if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || [[ "$repo" == *..* ]]; then
    echo "오류: CLAUDE_PET_REPO 는 '소유자/이름' 형식이어야 합니다: $repo" >&2; return 1
  fi
  if ! [[ "$ref" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || [[ "$ref" == *..* ]]; then
    echo "오류: CLAUDE_PET_REF 형식이 올바르지 않습니다: $ref" >&2; return 1
  fi

  # trap 은 함수가 끝난 뒤에 실행되므로 지역 변수가 아니라 전역 변수를 쓴다
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  echo "내려받는 중: https://github.com/$repo ($ref)"
  curl -fsSL "https://github.com/$repo/archive/$ref.tar.gz" -o "$TMP_DIR/src.tar.gz"
  echo "SHA-256: $(shasum -a 256 "$TMP_DIR/src.tar.gz" | awk '{print $1}')"
  echo "(공식 체크섬이 없어서 이 값을 대조할 곳은 없습니다. 고정하려면 태그나 커밋 SHA 를 쓰세요.)"

  mkdir "$TMP_DIR/src"
  tar -xzf "$TMP_DIR/src.tar.gz" -C "$TMP_DIR/src" --strip-components=1
  [ -f "$TMP_DIR/src/install.sh" ] || { echo "오류: 내려받은 파일에 install.sh 가 없습니다" >&2; return 1; }
  bash "$TMP_DIR/src/install.sh" "$@"
}

main "$@"
