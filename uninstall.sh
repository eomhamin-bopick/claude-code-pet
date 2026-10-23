#!/bin/bash
# claude-code-pet 제거
#   ./uninstall.sh            펫 훅·위젯 블록·위젯 모듈을 뺀다 (펫 그림과 설정은 ~/.claude-pet 에 남김)
#   ./uninstall.sh --purge    ~/.claude-pet 까지 전부 지운다
# 다른 훅·다른 Hammerspoon 설정은 건드리지 않습니다. 바꾸기 전에 백업을 만듭니다.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tools/common.sh"

PURGE=0
NO_RELOAD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --no-reload) NO_RELOAD=1; shift ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) die "알 수 없는 옵션: $1" ;;
  esac
done

refuse_root
need_python

# --purge 는 시작하기 전에 지울 수 있는 폴더인지부터 확인한다 (중간에 멈춰서 반쯤 지워진 상태가 되지 않게)
if [ "$PURGE" = 1 ]; then
  case "$PET_HOME" in
    /*) ;;
    *) die "안전을 위해 $PET_HOME 는 지우지 않습니다 (절대 경로가 아님)." ;;
  esac
  case "/$PET_HOME/" in
    */../*|*/./*) die "안전을 위해 $PET_HOME 는 지우지 않습니다 ('.' 또는 '..' 가 들어 있음)." ;;
  esac
  [ -e "$PET_HOME/$MARKER" ] || die "안전을 위해 $PET_HOME 는 지우지 않습니다 (이 프로젝트가 만든 폴더라는 표시가 없음). 직접 지워 주세요."
fi

say "== claude-code-pet 제거 =="
python3 "$SETUP_PY" settings-uninstall --settings "$CLAUDE_SETTINGS" --hooks-dir "$PET_HOME/hooks" --home "$PET_HOME"
python3 "$SETUP_PY" lua-uninstall --init "$HS_DIR/init.lua"

module="$HS_DIR/claude-pet"
if [ ! -e "$module" ]; then
  say "위젯 모듈: 없음"
elif [ -e "$module/$MARKER" ]; then
  rm -rf "$module"
  say "위젯 모듈 삭제: $module"
else
  warn "$module 은 이 프로젝트가 만든 폴더가 아니라서 지우지 않았습니다"
fi

if [ "$PURGE" = 1 ]; then
  # 폴더 통째로가 아니라 우리가 만든 항목만 지우고, 사용자가 넣어 둔 다른 파일이 있으면 폴더는 남긴다
  # hooks/ 는 스크립트만 지운다 (내가 고쳐 쓰던 훅의 *.bak-claude-pet-* 백업은 남긴다)
  for f in "$PET_HOME"/hooks/*.sh; do
    if [ -f "$f" ]; then rm -f "$f"; fi
  done
  rmdir "$PET_HOME/hooks" 2>/dev/null || true
  for item in pets state app config.json statusline.orig.json .mute "$MARKER"; do
    rm -rf "${PET_HOME:?}/$item"
  done
  if rmdir "$PET_HOME" 2>/dev/null; then
    say "삭제: $PET_HOME"
  else
    say "삭제: $PET_HOME 안의 펫 파일들 (다른 파일이 있어서 폴더는 남겼습니다)"
  fi
else
  say "남겨 둔 것: $PET_HOME (펫 그림과 설정). 완전히 지우려면 ./uninstall.sh --purge"
fi

reload_hammerspoon
