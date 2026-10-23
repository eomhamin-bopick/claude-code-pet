#!/bin/bash
# 사용량(%)을 펫 위젯 머리 위 알약에 보여 주도록 기록한다.
# usage: pet-usage-set.sh <5시간 %> <7일 %>     (없는 창은 -1)
# 예: pet-usage-set.sh 13 20    ->    "5h 13% · 7d 20%"
#
# 값을 어디서 가져오느냐는 자유다. 예를 들어
#   - Claude 앱의 사용량 카드를 읽는 예약 작업이 이 스크립트를 부르거나 (docs/USAGE.md)
#   - Pro/Max 구독이면 상태줄 래퍼(pet-usage.sh)가 알아서 부른다.
PET_HOME="${CLAUDE_PET_HOME:-$HOME/.claude-pet}"
STATE_DIR="$PET_HOME/state"
USAGE_FILE="$STATE_DIR/.usage"
num='^-?[0-9]+(\.[0-9]+)?$'

if ! [[ "$1" =~ $num && "$2" =~ $num ]]; then
  echo "usage: $0 <5h%> <7d%>  (숫자만, 없으면 -1)" >&2
  exit 1
fi

five="$(printf '%.0f' "$1")"
week="$(printf '%.0f' "$2")"

mkdir -p "$STATE_DIR"
printf '%s|%s|%s\n' "$five" "$week" "$(date +%s)" > "$USAGE_FILE.tmp" && mv "$USAGE_FILE.tmp" "$USAGE_FILE"
echo "5h:${five}% 7d:${week}%"
