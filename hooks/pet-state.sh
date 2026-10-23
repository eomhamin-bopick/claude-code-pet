#!/bin/bash
# Claude Code 훅 -> 펫 위젯 상태 전달 (+ 완료/대기 알림음)
# usage: pet-state.sh <idle|working|waiting|done|end>   (훅 JSON은 stdin)
#
# 세션마다 state/<session_id> 파일에 상태를 한 줄로 쓰고, 위젯이 그 폴더를 읽는다.
# 훅이 Claude를 막지 않도록 어떤 경우에도 exit 0.
#
#   소리 끄기: touch ~/.claude-pet/.mute      켜기: rm ~/.claude-pet/.mute
#   위젯에서 빼기: 사용자 프롬프트가 [pet-quiet] 로 시작하는 세션(예약 작업 등)은 위젯·알림음에서 제외된다.
PET_HOME="${CLAUDE_PET_HOME:-$HOME/.claude-pet}"
STATE_DIR="$PET_HOME/state"
state="${1:-idle}"

input="$(cat)"
quiet=0
if command -v jq >/dev/null 2>&1; then
  sid="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)"
  # 사용자 프롬프트(UserPromptSubmit)의 맨 앞에 있을 때만 인정한다. 도구 입력 안의 같은 글자는 무시.
  if [ "$(jq -r 'select(.hook_event_name == "UserPromptSubmit") | (.prompt // "") | startswith("[pet-quiet]")' <<<"$input" 2>/dev/null)" = "true" ]; then quiet=1; fi
else
  # jq 가 없을 때: 처음 나오는 session_id 를 쓴다 (도구 입력 안에 같은 키가 있어도 앞의 것이 이긴다)
  sid="$(printf '%s' "$input" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
  if printf '%s' "$input" | grep -q '"hook_event_name"[[:space:]]*:[[:space:]]*"UserPromptSubmit"' \
     && printf '%s' "$input" | grep -q '"prompt"[[:space:]]*:[[:space:]]*"\[pet-quiet\]'; then quiet=1; fi
fi
sid="${sid//[^A-Za-z0-9_-]/_}"
[ -z "$sid" ] && sid="unknown"

mkdir -p "$STATE_DIR" 2>/dev/null
file="$STATE_DIR/$sid"
prev="$(head -n1 "$file" 2>/dev/null)"

# [pet-quiet] 세션은 한 번 표시되면 끝날 때까지 건너뛴다
#  (파일 시각을 갱신해 둔다. 위젯이 오래된 ignore 파일을 정리하므로, 오래 도는 작업이 표시를 잃지 않게)
if [ "$prev" = "ignore" ] && [ "$state" != "end" ]; then touch "$file" 2>/dev/null; exit 0; fi
if [ "$quiet" = 1 ]; then state="ignore"; fi

if [ "$state" = "end" ]; then
  rm -f "$file"
else
  # 같은 세션의 훅이 동시에 와도 서로의 임시 파일을 덮지 않도록 프로세스 번호를 붙인다
  tmp="$file.$$.tmp"
  printf '%s\n' "$state" > "$tmp" && mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
fi

play() { [ -e "$PET_HOME/.mute" ] || afplay "$1" >/dev/null 2>&1 & }

# 상태가 바뀔 때만 울린다 (같은 대기가 훅 두 개로 와도 한 번만)
if [ "$state" != "$prev" ]; then
  case "$state" in
    done) play /System/Library/Sounds/Glass.aiff ;;
    waiting) play /System/Library/Sounds/Funk.aiff ;;
  esac
fi
exit 0
