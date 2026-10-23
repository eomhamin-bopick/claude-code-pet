#!/bin/bash
# 다른 캐릭터를 펫으로 추가한다.
#   ./add-pet.sh 그림.png --id my-pet [--name "내 펫"] [--scale 1.0] [--no-blink]
#       그림 한 장으로 모션 11줄짜리 시트를 만들어서 설치한다 (Pillow 필요)
#   ./add-pet.sh --from 폴더 [--id my-pet]
#       pet.json + spritesheet.png 가 들어 있는 폴더(Codex 펫 규격, 8x11 칸)를 그대로 설치한다
# 설치하면 바로 그 펫으로 바뀝니다 (--no-switch 면 설치만).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tools/common.sh"

IMAGE=""
FROM=""
ID=""
NAME=""
SCALE="1.0"
TOLERANCE=""
NOBLINK=0
NOSWITCH=0
NO_RELOAD=0

usage() { sed -n '2,7p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from) [ $# -ge 2 ] || die "--from 뒤에 폴더가 필요합니다"; FROM="$2"; shift 2 ;;
    --id) [ $# -ge 2 ] || die "--id 뒤에 이름이 필요합니다"; ID="$2"; shift 2 ;;
    --name) [ $# -ge 2 ] || die "--name 뒤에 이름이 필요합니다"; NAME="$2"; shift 2 ;;
    --scale) [ $# -ge 2 ] || die "--scale 뒤에 숫자가 필요합니다"; SCALE="$2"; shift 2 ;;
    --tolerance) [ $# -ge 2 ] || die "--tolerance 뒤에 숫자가 필요합니다"; TOLERANCE="$2"; shift 2 ;;
    --no-blink) NOBLINK=1; shift ;;
    --no-switch) NOSWITCH=1; shift ;;
    --no-reload) NO_RELOAD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "알 수 없는 옵션: $1" ;;
    *) [ -z "$IMAGE" ] || die "이미지는 하나만 지정할 수 있습니다"; IMAGE="$1"; shift ;;
  esac
done

refuse_root
need_python

# 경로로 쓰이는 값은 어떤 폴더 생성/복사보다 먼저 검사한다 (인터넷에서 받은 pet.json 의 id 도 같다)
[ -z "$ID" ] || require_pet_id "$ID"
case "$SCALE" in
  ''|*[!0-9.]*|.*|*.|*.*.*) die "--scale 은 숫자여야 합니다 (예: 0.9): $SCALE" ;;
esac

case "$TOLERANCE" in
  *[!0-9]*) die "--tolerance 는 0 이상의 정수여야 합니다 (예: 4): $TOLERANCE" ;;
esac

mkdir -p "$PET_HOME/pets"

if [ -n "$FROM" ]; then
  [ -f "$FROM/pet.json" ] && [ -f "$FROM/spritesheet.png" ] || die "$FROM 안에 pet.json 과 spritesheet.png 가 있어야 합니다"
  if [ -z "$ID" ]; then
    ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$FROM/pet.json")"
  fi
  [ -n "$ID" ] || die "--id 로 펫 id 를 지정해 주세요"
  require_pet_id "$ID"
  width="$(sips -g pixelWidth "$FROM/spritesheet.png" 2>/dev/null | awk '/pixelWidth/{print $2}')"
  [ "$width" = "1536" ] || warn "시트 폭이 1536 이 아닙니다 (현재 ${width:-알 수 없음}). 칸 크기가 192x208, 8열 x 11줄이어야 모션이 맞습니다."
  mkdir -p "$PET_HOME/pets/$ID"
  cp "$FROM/pet.json" "$FROM/spritesheet.png" "$PET_HOME/pets/$ID/"
else
  [ -n "$IMAGE" ] || { usage; exit 1; }
  [ -f "$IMAGE" ] || die "이미지를 찾을 수 없습니다: $IMAGE"
  [ -n "$ID" ] || die "--id 로 펫 id 를 지정해 주세요 (영문 소문자·숫자·하이픈)"
  python3 -c 'import PIL' 2>/dev/null || die "Pillow 가 필요합니다:  python3 -m pip install pillow"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  # 값마다 따옴표로 묶어 넘긴다 (공백이 든 값이 옵션으로 쪼개지지 않게)
  set -- "$IMAGE" --id "$ID" --scale "$SCALE" --out "$tmp/$ID" --no-preview
  [ -z "$TOLERANCE" ] || set -- "$@" --tolerance "$TOLERANCE"
  [ "$NOBLINK" = 1 ] && set -- "$@" --no-blink
  [ -z "$NAME" ] || set -- "$@" --name "$NAME"
  python3 "$REPO_DIR/tools/make_pet.py" "$@"
  mkdir -p "$PET_HOME/pets/$ID"
  cp "$tmp/$ID/pet.json" "$tmp/$ID/spritesheet.png" "$PET_HOME/pets/$ID/"
fi
say "펫 설치: $PET_HOME/pets/$ID"

if [ "$NOSWITCH" = 0 ]; then
  python3 "$SETUP_PY" set-pet --home "$PET_HOME" --pet "$ID"
  reload_hammerspoon
else
  say "지금 펫은 그대로입니다. 바꾸려면 $PET_HOME/config.json 의 \"pet\" 을 \"$ID\" 로 고치고 Hammerspoon 을 다시 불러오세요."
fi
