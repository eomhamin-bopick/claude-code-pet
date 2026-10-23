#!/bin/bash
# claude-code-pet 설치
#   ./install.sh                  기본 펫(jelly)으로 설치
#   ./install.sh --pet <id>       pets/ 안의 다른 펫으로 설치
#   ./install.sh --dry-run        아무것도 바꾸지 않고 무엇을 할지만 보여 줌
# 여러 번 실행해도 같은 결과입니다 (이미 있는 설정은 그대로, 바꾸기 전에 백업을 만듭니다).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tools/common.sh"

PET="jelly"
PET_GIVEN=0   # --pet 을 직접 줬을 때만 쓰던 펫을 바꾼다 (다시 설치해도 내가 고른 펫이 유지되게)
STATUSLINE=0
NO_HOOKS=0
NO_RELOAD=0
DRY=0

usage() {
  cat <<'EOF'
사용법: ./install.sh [옵션]

  --pet <id>      쓸 펫 (기본 jelly). pets/ 폴더 이름이거나 add-pet.sh 로 추가한 펫
  --statusline    상태줄을 사용량 기록 래퍼로 감싼다 (Pro/Max 에서 머리 위에 5h/7d 표시)
  --no-hooks      ~/.claude/settings.json 은 건드리지 않는다 (위젯만 설치)
  --no-reload     Hammerspoon 을 다시 불러오지 않는다
  --dry-run       아무것도 바꾸지 않고 할 일만 보여 준다
  -h, --help      이 도움말

환경변수(테스트용): CLAUDE_PET_HOME, HAMMERSPOON_DIR, CLAUDE_SETTINGS
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pet) [ $# -ge 2 ] || die "--pet 뒤에 펫 id 가 필요합니다"; PET="$2"; PET_GIVEN=1; shift 2 ;;
    --statusline) STATUSLINE=1; shift ;;
    --no-hooks) NO_HOOKS=1; shift ;;
    --no-reload) NO_RELOAD=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "알 수 없는 옵션: $1  (./install.sh --help)" ;;
  esac
done

[ "$(uname)" = "Darwin" ] || die "macOS 에서만 동작합니다 (Hammerspoon 이 macOS 용입니다)"
refuse_root
need_python
require_pet_id "$PET"
if ! has_hammerspoon; then
  say "Hammerspoon 이 없습니다. 먼저 설치해 주세요:"
  say "  brew install --cask hammerspoon"
  [ "$DRY" = 1 ] || exit 1
fi
if [ ! -f "$REPO_DIR/pets/$PET/pet.json" ] && [ ! -f "$PET_HOME/pets/$PET/pet.json" ]; then
  die "없는 펫입니다: $PET  (pets/ 안의 폴더 이름을 쓰거나, 먼저 ./add-pet.sh 로 추가하세요)"
fi

EXTRA=""
[ "$STATUSLINE" = 1 ] && EXTRA="--statusline"

if [ "$DRY" = 1 ]; then
  say "== 설치 미리보기 (아무것도 바꾸지 않습니다) =="
  say "복사: 훅 -> $PET_HOME/hooks   펫 -> $PET_HOME/pets   위젯 -> $HS_DIR/claude-pet"
  say "사용할 펫: $PET"
  if [ "$NO_HOOKS" = 0 ]; then
    python3 "$SETUP_PY" settings-install --settings "$CLAUDE_SETTINGS" --hooks-dir "$PET_HOME/hooks" --home "$PET_HOME" --dry-run $EXTRA
  fi
  python3 "$SETUP_PY" lua-install --init "$HS_DIR/init.lua" --dry-run
  exit 0
fi

say "== claude-code-pet 설치 =="
mkdir -p "$PET_HOME/hooks" "$PET_HOME/pets" "$PET_HOME/state" "$PET_HOME/app/tools" "$HS_DIR"
: > "$PET_HOME/$MARKER"

for f in "$REPO_DIR"/hooks/*.sh; do copy_with_backup "$f" "$PET_HOME/hooks/$(basename "$f")"; done
chmod +x "$PET_HOME"/hooks/*.sh
say "훅 스크립트: $PET_HOME/hooks"

# 한 줄 설치(bootstrap)는 끝나면 내려받은 저장소를 지우므로, 제거/펫 추가에 필요한 스크립트는 여기에 남긴다
cp "$REPO_DIR/uninstall.sh" "$REPO_DIR/add-pet.sh" "$PET_HOME/app/"
for f in "$REPO_DIR"/tools/*; do
  if [ -f "$f" ]; then cp "$f" "$PET_HOME/app/tools/"; fi
done
chmod +x "$PET_HOME/app/uninstall.sh" "$PET_HOME/app/add-pet.sh"
say "제거/펫 추가 스크립트: $PET_HOME/app"

# 같은 이름의 남의 폴더는 지우지 않고 옆으로 옮겨 둔다 (우리가 만든 폴더에는 표시 파일이 있다)
module="$HS_DIR/claude-pet"
if [ -e "$module" ] && [ ! -e "$module/$MARKER" ]; then
  moved="$module.bak-claude-pet-$(date +%Y%m%d-%H%M%S)"
  mv "$module" "$moved"
  warn "기존 $module 은 이 프로젝트가 만든 폴더가 아니라서 $moved 로 옮겼습니다"
fi
rm -rf "$module"
cp -R "$REPO_DIR/hammerspoon/claude-pet" "$module"
: > "$module/$MARKER"
say "위젯 모듈: $module"

for dir in "$REPO_DIR"/pets/*/; do
  id="$(basename "$dir")"
  [ -f "$dir/pet.json" ] || continue
  valid_pet_id "$id" || { warn "펫 폴더 이름이 규칙에 맞지 않아 건너뜀: $id"; continue; }
  mkdir -p "$PET_HOME/pets/$id"
  cp "$dir/pet.json" "$dir/spritesheet.png" "$PET_HOME/pets/$id/"
  say "펫: $id"
done

if [ "$PET_GIVEN" = 1 ]; then
  python3 "$SETUP_PY" set-pet --home "$PET_HOME" --pet "$PET"
else
  python3 "$SETUP_PY" set-pet --home "$PET_HOME" --pet "$PET" --if-unset
fi

if [ "$NO_HOOKS" = 0 ]; then
  [ -d "$(dirname "$CLAUDE_SETTINGS")" ] || warn "$(dirname "$CLAUDE_SETTINGS") 가 없습니다. Claude Code 를 아직 안 쓰셨다면 쓰기 시작한 뒤 ./install.sh 를 다시 실행하세요."
  python3 "$SETUP_PY" settings-install --settings "$CLAUDE_SETTINGS" --hooks-dir "$PET_HOME/hooks" --home "$PET_HOME" $EXTRA
else
  say "settings.json: 건드리지 않음 (--no-hooks)"
fi

python3 "$SETUP_PY" lua-install --init "$HS_DIR/init.lua"
reload_hammerspoon

cat <<EOF

설치가 끝났습니다.
  - 새 Claude Code 세션을 시작하면 펫이 반응합니다 (이미 열려 있던 세션은 새로 열어 주세요).
  - 펫을 끌어서 원하는 곳에 두세요. 마우스를 올리면 새 채팅/새 세션 아이콘이 나옵니다.
  - 다른 캐릭터로 바꾸기: $PET_HOME/app/add-pet.sh 그림.png --id 이름
  - 제거: $PET_HOME/app/uninstall.sh
EOF
