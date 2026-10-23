#!/bin/bash
# statusLine 래퍼: 5시간/7일 사용량을 펫 위젯용으로 기록하고, 원래 상태줄은 그대로 통과시킨다.
# usage: pet-usage.sh <원래 상태줄 명령...>   (입력 JSON은 stdin)
#   명령 없이 부르면 "5h:23% 7d:41%" 만 출력한다.
#
# Claude Code 가 상태줄 입력 JSON 에 rate_limits 를 넣어 주는 계정(Pro/Max 구독)에서만 값이 들어온다.
# 값이 없으면 아무것도 쓰지 않는다 (위젯의 사용량 알약은 저절로 숨겨진다).
PET_HOME="${CLAUDE_PET_HOME:-$HOME/.claude-pet}"
STATE_DIR="$PET_HOME/state"
USAGE_FILE="$STATE_DIR/.usage"
REWRITE_SEC=60   # 값이 같아도 이 간격마다 시각을 갱신 (오래된 값 판별용)

input="$(cat)"

usage=""
if command -v jq >/dev/null 2>&1; then
  usage="$(jq -r '[(.rate_limits.five_hour.used_percentage // -1), (.rate_limits.seven_day.used_percentage // -1)] | map(round) | join("|")' <<<"$input" 2>/dev/null)"
fi
five="${usage%%|*}"
week="${usage##*|}"

if [ -n "$usage" ] && [ "$usage" != "-1|-1" ]; then
  now=$(date +%s)
  mtime=$(stat -f %m "$USAGE_FILE" 2>/dev/null || echo 0)
  prev="$(cut -d'|' -f1,2 "$USAGE_FILE" 2>/dev/null)"
  if [ "$usage" != "$prev" ] || [ $((now - mtime)) -ge $REWRITE_SEC ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s|%s\n' "$usage" "$now" > "$USAGE_FILE.tmp" 2>/dev/null && mv "$USAGE_FILE.tmp" "$USAGE_FILE"
  fi
fi

if [ $# -gt 0 ]; then
  printf '%s' "$input" | "$@"
else
  out=""
  [ -n "$five" ] && [ "$five" != "-1" ] && out="5h:${five}%"
  [ -n "$week" ] && [ "$week" != "-1" ] && out="$out 7d:${week}%"
  echo "${out# }"
fi
exit 0
