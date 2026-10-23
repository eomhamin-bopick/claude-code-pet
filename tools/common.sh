# 공통 경로와 도우미 (install.sh / uninstall.sh / add-pet.sh 가 source 한다)
# macOS 기본 bash(3.2)에서도 돌도록 배열·연관 배열은 쓰지 않는다.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PET_HOME="${CLAUDE_PET_HOME:-$HOME/.claude-pet}"
HS_DIR="${HAMMERSPOON_DIR:-$HOME/.hammerspoon}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
SETUP_PY="$REPO_DIR/tools/claude_pet_setup.py"

say() { printf '%s\n' "$*"; }
warn() { printf '주의: %s\n' "$*" >&2; }
die() { printf '오류: %s\n' "$*" >&2; exit 1; }

need_python() {
  command -v python3 >/dev/null 2>&1 || die "python3 가 필요합니다 (macOS: xcode-select --install)"
}

# 우리가 만든 폴더라는 표시. 이 표시가 없는 폴더는 지우거나 덮어쓰지 않는다.
MARKER=".managed-by-claude-code-pet"

# 펫 id: 영문 소문자, 숫자, 하이픈만 (경로로 쓰이므로 복사/삭제보다 먼저 검사한다)
valid_pet_id() {
  case "$1" in
    ''|*[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

require_pet_id() {
  valid_pet_id "$1" || die "펫 id 는 영문 소문자, 숫자, 하이픈만 쓸 수 있습니다: $1"
}

# sudo 로 돌리면 root 소유 파일이 홈에 생겨서 나중에 일반 권한으로 못 고친다
refuse_root() {
  [ "$(id -u)" != 0 ] || [ "${CLAUDE_PET_ALLOW_ROOT:-0}" = 1 ] || die "root(sudo)로 실행하지 마세요. 일반 사용자 권한으로 실행해 주세요."
}

# 파일을 덮어쓰기 전에, 내용이 다르면 옆에 백업을 남긴다 (사용자가 고쳐 둔 훅 보호)
copy_with_backup() {
  local src="$1" dest="$2"
  if [ -e "$dest" ] && ! cmp -s "$src" "$dest"; then
    cp -p "$dest" "$dest.bak-claude-pet-$(date +%Y%m%d-%H%M%S)"
  fi
  cp "$src" "$dest"
}

# 명령을 최대 N초만 기다린다 (macOS 에는 timeout 명령이 없다). 시간 초과면 124.
run_with_timeout() {
  local limit="$1"; shift
  "$@" >/dev/null 2>&1 &
  local pid=$! ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((limit * 10)) ]; then kill "$pid" 2>/dev/null; return 124; fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

# Hammerspoon 을 켜거나 설정을 다시 불러온다. --no-reload 면 건너뛴다.
reload_hammerspoon() {
  if [ "${NO_RELOAD:-0}" = 1 ]; then
    say "→ Hammerspoon 다시 불러오기는 건너뜀 (--no-reload)"
    return 0
  fi
  if ! pgrep -x Hammerspoon >/dev/null 2>&1; then
    if open -a Hammerspoon 2>/dev/null; then say "→ Hammerspoon 을 실행했습니다"; else warn "Hammerspoon 을 실행하지 못했습니다. 직접 열어 주세요."; fi
    return 0
  fi
  if command -v hs >/dev/null 2>&1 && run_with_timeout 4 hs -c 'hs.timer.doAfter(0.2, hs.reload)'; then
    say "→ Hammerspoon 설정을 다시 불러왔습니다"
  else
    say "→ 메뉴바의 Hammerspoon 아이콘 → Reload Config 를 눌러 주세요"
    say "   (설치 스크립트가 자동으로 다시 불러오려면 내 init.lua 에 require(\"hs.ipc\") 가 있어야 합니다. 이 프로젝트는 일부러 켜지 않습니다.)"
  fi
}

has_hammerspoon() {
  # CLAUDE_PET_SKIP_HS_CHECK=1 은 Hammerspoon 이 없는 환경(테스트)에서 점검을 건너뛰는 용도
  [ "${CLAUDE_PET_SKIP_HS_CHECK:-0}" = 1 ] || [ -d /Applications/Hammerspoon.app ] || [ -d "$HOME/Applications/Hammerspoon.app" ]
}
