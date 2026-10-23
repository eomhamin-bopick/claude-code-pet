#!/bin/bash
# 설치/제거/훅을 임시 HOME 에서 통째로 돌려 본다. 진짜 ~ 와 실행 중인 Hammerspoon 은 건드리지 않는다.
#   bash tests/test_install.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export CLAUDE_PET_SKIP_HS_CHECK=1   # Hammerspoon 이 없는 환경에서도 돌도록
unset CLAUDE_PET_HOME HAMMERSPOON_DIR CLAUDE_SETTINGS CLAUDE_PET_ALLOW_ROOT
mkdir -p "$HOME/.claude" "$HOME/.hammerspoon"

FAILS=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }
json_eq() { python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))==json.load(open(sys.argv[2])) else 1)' "$1" "$2"; }
hooks_count() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for v in d.get("hooks",{}).values() for e in v for h in e["hooks"] if "pet-state.sh" in h["command"]))' "$1"; }

SETTINGS="$HOME/.claude/settings.json"
INIT="$HOME/.hammerspoon/init.lua"
cat > "$SETTINGS" <<'EOF'
{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo existing-stop"}]}]},
 "statusLine": {"type": "command", "command": "echo my-status"}}
EOF
cp "$SETTINGS" "$TMP/settings.orig.json"
printf 'hs.alert.show("mine")\n' > "$INIT"
cp "$INIT" "$TMP/init.orig.lua"

echo "== 1. dry-run 은 아무것도 바꾸지 않는다"
bash "$REPO/install.sh" --dry-run --no-reload >/dev/null
check "settings.json 그대로" 'cmp -s "$SETTINGS" "$TMP/settings.orig.json"'
check "init.lua 그대로" 'cmp -s "$INIT" "$TMP/init.orig.lua"'
check "~/.claude-pet 만들지 않음" '[ ! -e "$HOME/.claude-pet" ]'
bash "$REPO/install.sh" --dry-run --statusline --no-reload >/dev/null
check "--statusline 을 줘도 dry-run 은 파일을 쓰지 않음" '[ ! -e "$HOME/.claude-pet" ] && cmp -s "$SETTINGS" "$TMP/settings.orig.json"'

echo "== 2. 설치"
bash "$REPO/install.sh" --no-reload >/dev/null
check "훅 스크립트 설치(실행 권한)" '[ -x "$HOME/.claude-pet/hooks/pet-state.sh" ]'
check "위젯 모듈 설치" '[ -f "$HOME/.hammerspoon/claude-pet/init.lua" ] && [ -f "$HOME/.hammerspoon/claude-pet/pets.lua" ]'
check "위젯 모듈이 hs.ipc 를 켜지 않음" '! grep -q "^[^-]*require(\"hs.ipc\")" "$HOME/.hammerspoon/claude-pet/init.lua"'
check "젤리 펫 설치" '[ -f "$HOME/.claude-pet/pets/jelly/spritesheet.png" ] && [ -f "$HOME/.claude-pet/pets/jelly/pet.json" ]'
check "원본 그림(source.png)은 복사하지 않음" '[ ! -e "$HOME/.claude-pet/pets/jelly/source.png" ]'
check "config.json 에 jelly" 'grep -q "\"jelly\"" "$HOME/.claude-pet/config.json"'
check "훅 8개 등록" '[ "$(hooks_count "$SETTINGS")" = 8 ]'
check "기존 Stop 훅 보존" 'grep -q "existing-stop" "$SETTINGS"'
check "다른 설정 보존" 'grep -q "\"model\": \"opus\"" "$SETTINGS"'
check "상태줄은 건드리지 않음(--statusline 없이)" 'grep -q "echo my-status" "$SETTINGS" && ! grep -q "pet-usage.sh" "$SETTINGS"'
check "init.lua 에 기존 줄 보존 + 블록 추가" 'grep -q "hs.alert.show(\"mine\")" "$INIT" && grep -q "claude-code-pet" "$INIT"'
check "백업 파일 생성" 'ls "$HOME/.claude/" | grep -q "bak-claude-pet"'
check "제거/펫 추가 스크립트가 ~/.claude-pet/app 에 남음" '[ -x "$HOME/.claude-pet/app/uninstall.sh" ] && [ -x "$HOME/.claude-pet/app/add-pet.sh" ] && [ -f "$HOME/.claude-pet/app/tools/claude_pet_setup.py" ] && [ -f "$HOME/.claude-pet/app/tools/make_pet.py" ]'
check "~/.claude-pet / 위젯 모듈에 표시 파일" '[ -e "$HOME/.claude-pet/.managed-by-claude-code-pet" ] && [ -e "$HOME/.hammerspoon/claude-pet/.managed-by-claude-code-pet" ]'

echo "== 3. 다시 설치해도 같은 결과 (멱등)"
cp "$SETTINGS" "$TMP/settings.after1.json"; cp "$INIT" "$TMP/init.after1.lua"
bash "$REPO/install.sh" --no-reload >/dev/null
check "settings.json 변하지 않음" 'cmp -s "$SETTINGS" "$TMP/settings.after1.json"'
check "init.lua 변하지 않음" 'cmp -s "$INIT" "$TMP/init.after1.lua"'
check "훅이 여전히 8개" '[ "$(hooks_count "$SETTINGS")" = 8 ]'

echo "== 4. 훅 스크립트 동작"
HOOK="$HOME/.claude-pet/hooks/pet-state.sh"
STATE="$HOME/.claude-pet/state"
touch "$HOME/.claude-pet/.mute"   # 테스트 중 소리 끄기
echo '{"session_id":"s1"}' | bash "$HOOK" working
check "working 기록" '[ "$(cat "$STATE/s1")" = working ]'
echo '{"session_id":"s1"}' | bash "$HOOK" done
check "done 기록" '[ "$(cat "$STATE/s1")" = done ]'
echo '{"session_id":"s1"}' | bash "$HOOK" end
check "end 는 파일 삭제" '[ ! -e "$STATE/s1" ]'
echo '{"session_id":"q1","hook_event_name":"UserPromptSubmit","prompt":"[pet-quiet] 예약 작업"}' | bash "$HOOK" working
echo '{"session_id":"q1"}' | bash "$HOOK" done
check "[pet-quiet] 세션은 ignore 로 고정" '[ "$(cat "$STATE/q1")" = ignore ]'
echo '{"session_id":"q2","hook_event_name":"PreToolUse","tool_name":"Task","tool_input":{"prompt":"[pet-quiet] 흉내"}}' | bash "$HOOK" working
check "도구 입력 안의 [pet-quiet] 는 무시(표시기를 못 끈다)" '[ "$(cat "$STATE/q2")" = working ]'
echo '{"session_id":"q3","hook_event_name":"UserPromptSubmit","prompt":"설명: [pet-quiet] 는 맨 앞에 쓰는 표시"}' | bash "$HOOK" working
check "프롬프트 맨 앞이 아니면 무시" '[ "$(cat "$STATE/q3")" = working ]'
echo '{"session_id":"../evil"}' | bash "$HOOK" working
check "세션 id 의 경로 문자는 무해화" '[ -f "$STATE/___evil" ] && [ ! -e "$HOME/evil" ]'
echo 'not json' | bash "$HOOK" working; code=$?
check "깨진 입력에도 exit 0" '[ "$code" = 0 ]'
bash "$HOME/.claude-pet/hooks/pet-usage-set.sh" 13 20 >/dev/null
check "사용량 기록 형식(5h|7d|시각)" 'grep -Eq "^13\|20\|[0-9]+$" "$STATE/.usage"'
bash "$HOME/.claude-pet/hooks/pet-usage-set.sh" abc 20 >/dev/null 2>&1; code=$?
check "숫자가 아니면 거부" '[ "$code" != 0 ]'

# 같은 세션에 훅이 동시에 몰려도 임시 파일이 겹쳐 오류가 나거나 갱신이 사라지지 않는다
errs="$( for i in $(seq 1 40); do echo '{"session_id":"race"}' | bash "$HOOK" working 2>&1 & done; wait )"
check "같은 세션에 훅 40개가 동시에 와도 오류 없음" '[ -z "$errs" ] && [ "$(cat "$STATE/race")" = working ]'
check "임시 파일이 남지 않음" '[ -z "$(ls "$STATE" | grep "\.tmp$")" ]'

# [pet-quiet] 표시는 훅이 올 때마다 파일 시각을 갱신해서, 오래 도는 작업이 표시를 잃지 않는다
touch -t 202001010000 "$STATE/q1"
echo '{"session_id":"q1"}' | bash "$HOOK" working
check "ignore 파일의 시각이 갱신되고 내용은 그대로" '[ "$(cat "$STATE/q1")" = ignore ] && [ "$(stat -f %m "$STATE/q1")" -gt 1700000000 ]'

# jq 가 없는 환경 (필요한 명령만 링크한 PATH)
mkdir -p "$TMP/nojq"
for tool in cat grep sed head mkdir mv rm; do ln -sf "$(command -v "$tool")" "$TMP/nojq/$tool"; done
echo '{"session_id":"nj1","hook_event_name":"PreToolUse","tool_input":{"session_id":"inner"}}' | PATH="$TMP/nojq" /bin/bash "$HOOK" working
check "jq 없이도 동작하고, 처음 나온 session_id 를 쓴다" '[ -f "$STATE/nj1" ] && [ ! -e "$STATE/inner" ]'
echo '{"session_id":"nj2","hook_event_name":"UserPromptSubmit","prompt":"[pet-quiet] x"}' | PATH="$TMP/nojq" /bin/bash "$HOOK" working
echo '{"session_id":"nj3","hook_event_name":"PreToolUse","tool_input":{"prompt":"[pet-quiet] x"}}' | PATH="$TMP/nojq" /bin/bash "$HOOK" working
check "jq 없이도 [pet-quiet] 판정이 같음" '[ "$(cat "$STATE/nj2")" = ignore ] && [ "$(cat "$STATE/nj3")" = working ]'

echo "== 5. 다른 펫 추가 (--from)"
bash "$REPO/add-pet.sh" --from "$REPO/pets/jelly" --id copy --no-reload >/dev/null 2>&1
check "펫 폴더 설치" '[ -f "$HOME/.claude-pet/pets/copy/pet.json" ]'
check "config.json 이 copy 로 전환" 'grep -q "\"copy\"" "$HOME/.claude-pet/config.json"'
bash "$REPO/install.sh" --pet nope --no-reload >/dev/null 2>&1; code=$?
check "없는 펫은 거부" '[ "$code" != 0 ]'
bash "$REPO/install.sh" --no-reload >/dev/null 2>&1
check "--pet 없이 다시 설치해도 쓰던 펫(copy)이 유지됨" 'grep -q "\"copy\"" "$HOME/.claude-pet/config.json"'

echo "== 5b. 펫 id / 인자 검증"
mkdir -p "$TMP/evilpet"
cp "$REPO/pets/jelly/spritesheet.png" "$TMP/evilpet/"
printf '{"id":"../../outside/planted"}\n' > "$TMP/evilpet/pet.json"
bash "$REPO/add-pet.sh" --from "$TMP/evilpet" --no-reload >/dev/null 2>&1; code=$?
check "pet.json 의 id 가 경로를 벗어나면 거부하고 아무것도 만들지 않음" '[ "$code" != 0 ] && [ ! -e "$HOME/outside" ] && [ ! -e "$HOME/.claude-pet/outside" ]'
bash "$REPO/add-pet.sh" --from "$TMP/evilpet" --id "../escape" --no-reload >/dev/null 2>&1; code=$?
check "--id 에 .. 가 있으면 거부" '[ "$code" != 0 ] && [ ! -e "$HOME/.claude-pet/escape" ]'
bash "$REPO/add-pet.sh" "$REPO/pets/jelly/preview.png" --id "ab --out $TMP/hijack" --no-reload >/dev/null 2>&1; code=$?
check "--id 에 공백/옵션을 끼워도 거부(옵션 주입 차단)" '[ "$code" != 0 ] && [ ! -e "$TMP/hijack" ]'
bash "$REPO/add-pet.sh" "$REPO/pets/jelly/preview.png" --id ok --scale "1.0 --out $TMP/hijack2" --no-reload >/dev/null 2>&1; code=$?
check "--scale 이 숫자가 아니면 거부" '[ "$code" != 0 ] && [ ! -e "$TMP/hijack2" ]'
bash "$REPO/install.sh" --pet "BadId" --no-reload >/dev/null 2>&1; code=$?
check "--pet 에 대문자가 있으면 복사하기 전에 거부" '[ "$code" != 0 ]'

echo "== 6. 상태줄 래퍼 (--statusline)"
bash "$REPO/install.sh" --statusline --pet jelly --no-reload >/dev/null
check "상태줄이 래퍼로 감싸지고 원래 명령 유지" 'grep -q "pet-usage.sh" "$SETTINGS" && grep -q "echo my-status" "$SETTINGS"'
out="$(echo '{"rate_limits":{"five_hour":{"used_percentage":23.4},"seven_day":{"used_percentage":41.2}}}' | bash "$HOME/.claude-pet/hooks/pet-usage.sh" cat)"
check "래퍼가 입력을 그대로 통과" 'echo "$out" | grep -q five_hour'
check "래퍼가 사용량 기록" 'grep -Eq "^23\|41\|" "$STATE/.usage"'
wrapped="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$SETTINGS")"
out="$(echo '{}' | bash -c "$wrapped")"
check "감싼 상태줄을 실제로 실행하면 원래 명령이 돈다" '[ "$out" = "my-status" ]'

echo "== 7. 제거"
bash "$REPO/uninstall.sh" --no-reload >/dev/null
check "settings.json 이 설치 전과 같음(훅·상태줄 원복)" 'json_eq "$SETTINGS" "$TMP/settings.orig.json"'
check "init.lua 가 설치 전과 같음" 'cmp -s "$INIT" "$TMP/init.orig.lua"'
check "위젯 모듈 삭제" '[ ! -e "$HOME/.hammerspoon/claude-pet" ]'
check "펫·설정은 남김" '[ -d "$HOME/.claude-pet/pets" ]'
bash "$REPO/uninstall.sh" --no-reload --purge >/dev/null
check "--purge 는 ~/.claude-pet 삭제" '[ ! -e "$HOME/.claude-pet" ]'
check "다시 제거해도 오류 없음" 'bash "$REPO/uninstall.sh" --no-reload >/dev/null 2>&1'

echo "== 7b. 한 줄 설치처럼 저장소 없이 제거 / 안전장치"
cp "$TMP/settings.orig.json" "$SETTINGS"
bash "$REPO/install.sh" --no-reload >/dev/null
bash "$HOME/.claude-pet/app/uninstall.sh" --no-reload >/dev/null
check "~/.claude-pet/app/uninstall.sh 로 제거(설정 원복)" 'json_eq "$SETTINGS" "$TMP/settings.orig.json" && cmp -s "$INIT" "$TMP/init.orig.lua"'

# 표시 파일이 없는 폴더는 --purge 로 지우지 않는다
mkdir -p "$TMP/work/Documents" "$TMP/work/claude-pet-x"
echo keep > "$TMP/work/Documents/important.txt"
CLAUDE_PET_HOME="$TMP/work/claude-pet-x/../Documents" bash "$REPO/uninstall.sh" --no-reload --purge >/dev/null 2>&1; code=$?
check "../ 로 우회한 --purge 는 거부, 파일 그대로" '[ "$code" != 0 ] && [ -f "$TMP/work/Documents/important.txt" ]'
mkdir -p "$TMP/work/proj/claude-pet"
echo keep > "$TMP/work/proj/claude-pet/mine.txt"
CLAUDE_PET_HOME="$TMP/work/proj/claude-pet" bash "$REPO/uninstall.sh" --no-reload --purge >/dev/null 2>&1; code=$?
check "이름만 비슷한 내 폴더(표시 파일 없음)는 --purge 거부" '[ "$code" != 0 ] && [ -f "$TMP/work/proj/claude-pet/mine.txt" ]'
(cd "$TMP/work" && mkdir -p .claude-pet && CLAUDE_PET_HOME=".claude-pet" bash "$REPO/uninstall.sh" --no-reload --purge >/dev/null 2>&1); code=$?
check "상대 경로는 --purge 거부" '[ "$code" != 0 ] && [ -d "$TMP/work/.claude-pet" ]'

# --purge 는 우리가 만든 항목만 지우고, 사용자가 넣어 둔 파일은 남긴다
bash "$REPO/install.sh" --no-reload >/dev/null
echo mine > "$HOME/.claude-pet/my-notes.txt"
bash "$REPO/uninstall.sh" --no-reload --purge >/dev/null
check "--purge 후에도 사용자가 둔 파일은 남음" '[ -f "$HOME/.claude-pet/my-notes.txt" ] && [ ! -e "$HOME/.claude-pet/hooks" ] && [ ! -e "$HOME/.claude-pet/pets" ]'
rm -f "$HOME/.claude-pet/my-notes.txt"; rmdir "$HOME/.claude-pet" 2>/dev/null

# 같은 이름의 남의 위젯 폴더는 지우지 않고 옆으로 옮긴다 / 제거할 때도 건드리지 않는다
mkdir -p "$HOME/.hammerspoon/claude-pet"
echo "-- someone else" > "$HOME/.hammerspoon/claude-pet/custom.lua"
bash "$REPO/install.sh" --no-reload >/dev/null 2>&1
check "남의 claude-pet 폴더는 백업 폴더로 이동" 'ls -d "$HOME"/.hammerspoon/claude-pet.bak-claude-pet-* >/dev/null 2>&1 && [ -f "$(ls -d "$HOME"/.hammerspoon/claude-pet.bak-claude-pet-* | head -n1)/custom.lua" ]'
check "새 위젯 모듈이 설치되고 표시 파일이 있음" '[ -f "$HOME/.hammerspoon/claude-pet/init.lua" ] && [ -e "$HOME/.hammerspoon/claude-pet/.managed-by-claude-code-pet" ]'
rm -f "$HOME/.hammerspoon/claude-pet/.managed-by-claude-code-pet"
bash "$REPO/uninstall.sh" --no-reload >/dev/null 2>&1
check "표시 파일이 없는 위젯 폴더는 제거 때 지우지 않음" '[ -f "$HOME/.hammerspoon/claude-pet/init.lua" ]'
rm -rf "$HOME/.hammerspoon/claude-pet" "$HOME"/.hammerspoon/claude-pet.bak-claude-pet-*
bash "$REPO/uninstall.sh" --no-reload --purge >/dev/null 2>&1

# 내가 고친 훅 스크립트는 덮어쓰기 전에 백업이 남는다
bash "$REPO/install.sh" --no-reload >/dev/null
echo "# my tweak" >> "$HOME/.claude-pet/hooks/pet-state.sh"
bash "$REPO/install.sh" --no-reload >/dev/null
check "고친 훅 스크립트는 덮어쓰기 전에 백업" 'ls "$HOME"/.claude-pet/hooks/pet-state.sh.bak-claude-pet-* >/dev/null 2>&1 && ! grep -q "my tweak" "$HOME/.claude-pet/hooks/pet-state.sh"'
bash "$REPO/uninstall.sh" --no-reload --purge >/dev/null 2>&1
rm -rf "$HOME/.claude-pet"

# dotfiles 심볼릭 링크는 링크를 유지하고 원본을 고친다
cp "$TMP/settings.orig.json" "$SETTINGS"
mkdir -p "$TMP/dotfiles"
mv "$SETTINGS" "$TMP/dotfiles/settings.json"
ln -s "$TMP/dotfiles/settings.json" "$SETTINGS"
cp "$INIT" "$TMP/dotfiles/init.lua"; rm -f "$INIT"; ln -s "$TMP/dotfiles/init.lua" "$INIT"
bash "$REPO/install.sh" --no-reload >/dev/null 2>&1
check "심볼릭 링크가 유지되고 가리키는 파일에 반영됨" '[ -L "$SETTINGS" ] && [ -L "$INIT" ] && [ "$(hooks_count "$TMP/dotfiles/settings.json")" = 8 ] && grep -q "claude-code-pet" "$TMP/dotfiles/init.lua"'
bash "$REPO/uninstall.sh" --no-reload --purge >/dev/null 2>&1
check "제거해도 링크가 유지되고 원래대로 돌아감" '[ -L "$SETTINGS" ] && [ -L "$INIT" ] && json_eq "$TMP/dotfiles/settings.json" "$TMP/settings.orig.json" && cmp -s "$TMP/dotfiles/init.lua" "$TMP/init.orig.lua"'
rm -f "$SETTINGS" "$INIT"; cp "$TMP/settings.orig.json" "$SETTINGS"; cp "$TMP/init.orig.lua" "$INIT"

echo "== 7c. bootstrap.sh 입력 검사 (네트워크 없이 거절되는 것만)"
CLAUDE_PET_REF='../x' bash "$REPO/bootstrap.sh" >/dev/null 2>&1; code=$?
check "REF 에 .. 가 있으면 거부" '[ "$code" != 0 ]'
CLAUDE_PET_REF='-o' bash "$REPO/bootstrap.sh" >/dev/null 2>&1; code=$?
check "REF 가 - 로 시작하면 거부" '[ "$code" != 0 ]'
CLAUDE_PET_REPO='a/b/c' bash "$REPO/bootstrap.sh" >/dev/null 2>&1; code=$?
check "REPO 형식이 올바르지 않으면 거부" '[ "$code" != 0 ]'
CLAUDE_PET_REPO='owner/repo;id' bash "$REPO/bootstrap.sh" >/dev/null 2>&1; code=$?
check "REPO 에 특수문자가 있으면 거부" '[ "$code" != 0 ]'

echo "== 7d. 비어 있는 settings.json 도 새 파일처럼 설치된다"
: > "$SETTINGS"
bash "$REPO/install.sh" --no-reload >/dev/null 2>&1; code=$?
check "빈 settings.json 설치 성공 + 훅 8개" '[ "$code" = 0 ] && [ "$(hooks_count "$SETTINGS")" = 8 ]'
bash "$REPO/uninstall.sh" --no-reload --purge >/dev/null 2>&1
rm -rf "$HOME/.claude-pet"

echo "== 8. 깨진 settings.json 은 건드리지 않는다"
echo "{ broken" > "$SETTINGS"
bash "$REPO/install.sh" --no-reload >/dev/null 2>&1; code=$?
check "설치 실패(종료 코드 != 0)" '[ "$code" != 0 ]'
check "파일 내용 그대로" '[ "$(cat "$SETTINGS")" = "{ broken" ]'

echo
if [ "$FAILS" = 0 ]; then echo "모두 통과"; else echo "실패 $FAILS건"; exit 1; fi
