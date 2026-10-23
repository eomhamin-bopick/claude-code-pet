# claude-code-pet

Claude Code가 일하는 동안 화면 구석에서 같이 움직이는 **데스크톱 펫**입니다. (macOS + [Hammerspoon](https://www.hammerspoon.org))

![젤리 펫 미리보기](pets/jelly/preview.gif)

- Claude Code가 작업 중이면 일하는 모션, 확인이 필요하면 손을 흔들고, 끝나면 폴짝 뜁니다.
- 마우스를 올리면 **새 채팅 / 새 세션** 아이콘이 나옵니다. 펫을 클릭하면 Claude 창이 앞으로 옵니다.
- 원하는 곳으로 끌어서 옮길 수 있습니다. 끌면 가는 방향으로 달립니다.
- 그림 한 장이면 **다른 캐릭터**로도 만들 수 있습니다. (아래 [다른 캐릭터로 만들기](#다른-캐릭터로-만들기))

> 비공식 프로젝트입니다. Anthropic, OpenAI와 관련이 없습니다. 이름의 "Claude"는 연동 대상을, "Codex 펫 규격"은 시트 규격이 호환된다는 설명을 가리킬 뿐입니다. 각 이름은 해당 회사의 상표입니다.

## 상황별 동작

| Claude Code 상황 | 펫 동작 |
|---|---|
| 아무것도 안 할 때 | 숨쉬기와 눈 깜빡임, 가끔 두리번거리거나 손 흔들기 |
| 작업 중 (프롬프트, 도구 실행) | 일하는 모션 |
| 확인이 필요할 때 (권한 요청 등) | 손을 두 번 흔들고 기다리는 모션 + 청록 글로우 + 알림음 |
| 작업 완료 | 점프 + 알림음 |
| 펫을 끌 때 | 가는 방향으로 달리기 |
| 마우스를 올릴 때 | 폴짝, 그리고 새 채팅 / 새 세션 아이콘 |
| 펫을 클릭 | Claude 창을 앞으로 (확인 대기 중이면 그 세션으로) |

세션이 여러 개면 **확인 대기 > 작업 중 > 완료** 순으로 가장 급한 상태를 보여 줍니다.

## 설치

먼저 Hammerspoon이 필요합니다.

```bash
brew install --cask hammerspoon
```

한 줄 설치 (릴리스 태그 `v0.1.0`으로 고정):

```bash
curl -fsSL https://raw.githubusercontent.com/eomhamin-bopick/claude-code-pet/v0.1.0/bootstrap.sh | bash
```

이 한 줄은 인터넷에서 받은 스크립트를 그대로 실행합니다. 서명이나 체크섬 검증은 없고, 받은 압축 파일의 SHA-256만 화면에 보여 줍니다. 설치는 `~/.claude/settings.json`에 훅을 넣고 Hammerspoon에 Lua를 올리므로, 이 저장소가 바뀌면 설치하는 모든 사람의 컴퓨터에서 코드가 실행될 수 있습니다. 그래서 **태그나 커밋 SHA로 고정**하세요. (`CLAUDE_PET_REF=<태그 또는 커밋 SHA>`로 바꿀 수 있습니다. 기본값은 위 태그이고, `main`을 쓰면 그때그때 바뀌는 최신을 받습니다.)

내키지 않으면 받아서 읽어 보고 설치하세요.

```bash
git clone https://github.com/eomhamin-bopick/claude-code-pet.git
cd claude-code-pet
git checkout v0.1.0
./install.sh --dry-run   # 아무것도 바꾸지 않고 무엇을 할지만 보여 줍니다
./install.sh
```

sudo로 실행하지 마세요. 일반 사용자 권한으로만 설치됩니다.

설치가 끝나면 **새 Claude Code 세션**을 시작하세요. (이미 열려 있던 세션은 훅을 다시 읽지 않을 수 있습니다.)

### 옵션

| 옵션 | 설명 |
|---|---|
| `--pet <id>` | 쓸 펫 (기본 `jelly`) |
| `--statusline` | 상태줄을 사용량 기록 래퍼로 감쌈 (Pro/Max 구독에서 머리 위에 5h/7d 표시) |
| `--no-hooks` | `~/.claude/settings.json`은 건드리지 않음 (위젯만 설치) |
| `--no-reload` | Hammerspoon을 다시 불러오지 않음 |
| `--dry-run` | 아무것도 바꾸지 않고 할 일만 보여 줌 |

### 설치가 하는 일

설치는 아래만 바꿉니다. 여러 번 실행해도 같은 결과입니다.

| 위치 | 내용 |
|---|---|
| `~/.claude-pet/` | 훅 스크립트(`hooks/`), 펫 그림(`pets/`), 설정(`config.json`), 상태 파일(`state/`), 제거와 펫 추가 스크립트(`app/`) |
| `~/.hammerspoon/claude-pet/` | 위젯 모듈. 같은 이름의 다른 폴더가 이미 있으면 지우지 않고 `claude-pet.bak-claude-pet-날짜`로 옮김 |
| `~/.hammerspoon/init.lua` | 맨 아래에 `-- >>> claude-code-pet >>>` 블록 한 개 추가 (기존 내용은 그대로) |
| `~/.claude/settings.json` | 훅 8개 추가 (기존 훅·설정은 그대로). `--statusline`을 쓴 경우 상태줄도 감쌈 |

`settings.json`과 `init.lua`는 바꾸기 전에 `*.bak-claude-pet-날짜` 백업을 만듭니다. 백업에는 원본의 내용(토큰 같은 비밀이 들어 있을 수 있음)이 그대로 들어 있고 같은 권한으로 만들어집니다. 심볼릭 링크(dotfiles 관리 도구)는 링크는 그대로 두고 가리키는 실제 파일을 바꾸고, 그 백업도 실제 파일 옆(dotfiles 폴더)에 생깁니다. 다시 설치해도 쓰던 펫(`config.json`의 `pet`)은 `--pet`을 직접 줄 때만 바뀝니다. 이미 있던 `~/.claude-pet/hooks/*.sh`를 고쳐 쓰고 있었다면 덮어쓰기 전에 옆에 백업이 남습니다.

### 제거

```bash
~/.claude-pet/app/uninstall.sh           # 훅, init.lua 블록, 위젯 모듈 제거 (펫 그림과 설정은 남김)
~/.claude-pet/app/uninstall.sh --purge   # ~/.claude-pet 안의 펫 파일까지 삭제
```

한 줄 설치를 썼어도 위 스크립트가 남아 있습니다. clone해서 설치했다면 저장소의 `./uninstall.sh`도 같습니다. 제거하면 `settings.json`의 훅과 상태줄, `init.lua`의 블록이 설치 전 상태로 돌아갑니다. (JSON은 들여쓰기 2칸으로 다시 쓰이고, 설치 전에 없던 `settings.json`은 `{}`로 남습니다. `--purge`도 `*.bak-claude-pet-*` 백업 파일과 `~/.claude-pet` 안의 내 파일은 지우지 않습니다.) `~/.claude-pet`을 손으로 먼저 지우면 `settings.json`에 훅이 남아 Claude Code 이벤트마다 "파일 없음" 오류가 뜨니, 지우기 전에 `uninstall.sh`를 먼저 실행하세요.

## 다른 캐릭터로 만들기

그림 한 장(투명 배경 PNG 권장)이면 모션 11줄짜리 펫으로 만들어서 설치하고, Hammerspoon을 다시 불러오면 그 펫으로 바뀝니다.

```bash
python3 -m pip install pillow          # 한 번만
~/.claude-pet/app/add-pet.sh ~/Downloads/my-character.png --id my-pet --name "My Pet"
```

(clone해서 설치했다면 저장소의 `./add-pet.sh`도 같은 스크립트입니다. 펫 id는 영문 소문자, 숫자, 하이픈만 됩니다.)

만들어지는 것: 숨쉬기, 눈 깜빡임, 달리기(좌우), 손 흔들기, 점프, 실패, 대기, 작업, 살펴보기, 두리번, 한 바퀴 돌기. 모션은 찌그러짐, 늘어남, 기울임, 흔들림으로 만들어서 **말랑한 젤리, 유령, 동그란 캐릭터**에 특히 잘 어울립니다. 팔다리를 따로 움직이는 애니메이션은 없습니다.

- **투명 배경 PNG를 권장합니다.** 배경이 불투명하면 모서리 색과 거의 같은 픽셀을 바깥쪽부터 지웁니다. 캐릭터가 배경색과 비슷하면(예: 흰 배경 위의 흰색에 가까운 캐릭터) 가장자리가 깎이거나 흰 테두리가 남을 수 있습니다. 그럴 땐 `--tolerance`를 더 낮추거나(기본 8) 배경을 먼저 지운 PNG를 쓰세요.
- 눈이 어두운 점 두 개인 캐릭터는 눈 깜빡임이 자동으로 들어갑니다. 못 찾으면 숨쉬기만 합니다 (`--no-blink`로 끌 수도 있습니다).
- 크기가 안 맞으면 `--scale 0.9`처럼 조절하세요.
- 다른 펫으로 바꾸기: `~/.claude-pet/config.json`의 `"pet"` 값을 바꾸고 Hammerspoon을 다시 불러오기. (clone해서 설치했다면 `./install.sh --pet my-pet`도 됩니다.)
- `--tolerance 4`처럼 배경 제거 허용 오차를 줄 수 있습니다 (기본 8).

이미 가진 8열 x 11줄 스프라이트 시트(Codex 펫 규격)가 있으면 그대로 쓸 수 있습니다.

```bash
~/.claude-pet/app/add-pet.sh --from ~/Downloads/some-pet-folder --id some-pet   # pet.json + spritesheet.png 가 든 폴더
```

시트를 직접 그리는 방법은 [docs/PET_FORMAT.md](docs/PET_FORMAT.md)를 보세요. 직접 만들었거나 사용 권리가 있는 캐릭터만 쓰세요. 인터넷에서 받은 펫은 신뢰하는 출처의 것만 쓰세요. 펫의 그림 파일은 Hammerspoon 프로세스가 열어서 그립니다. (`pet.json`의 id와 시트 경로, 프레임 간격은 검사하지만 이미지 파일 자체는 macOS의 이미지 해석기에 맡깁니다.)

## 설정

`~/.claude-pet/config.json` (없으면 기본값):

```json
{ "pet": "jelly", "scale": 1.6, "showUsage": true, "hoverMenu": true }
```

| 키 | 기본값 | 설명 |
|---|---|---|
| `pet` | `jelly` | `~/.claude-pet/pets/<id>/`의 펫 |
| `scale` | `1.6` | 위젯 크기 배율 |
| `showUsage` | `true` | 머리 위 사용량 알약 (사용량 값이 있을 때만 보임) |
| `showRemaining` | `false` | `true`면 쓴 %가 아니라 남은 % |
| `hoverMenu` | `true` | 마우스를 올리면 새 채팅/새 세션 아이콘 |
| `autoLaunch` | `false` | `true`면 로그인할 때 Hammerspoon 자동 실행 |
| `claudeApp` | `Claude` | 클릭하면 앞으로 올릴 앱 이름 |
| `inactiveHours` | `5` | 이 시간 동안 Claude Code 활동이 없으면 위젯을 숨김 |
| `margin` | `24` | 처음 놓을 위치(오른쪽 아래 구석)에서 화면 가장자리와의 간격 |

바꾼 뒤에는 메뉴바 Hammerspoon 아이콘 → Reload Config.

## 사용량 표시 (선택)

머리 위에 `5h 19% · 7d 21%` 같은 알약을 띄울 수 있습니다. 값이 없으면 알약은 저절로 숨겨집니다.

- Pro/Max 구독이면 `./install.sh --statusline`으로 끝납니다. (`jq`가 필요합니다. 최신 macOS에는 `/usr/bin/jq`가 있고, 없으면 `brew install jq`.) 쓰던 상태줄 명령은 `sh -c '<원래 명령>'`으로 감싸서 그대로 실행하고, 원본은 `~/.claude-pet/statusline.orig.json`에 보관합니다. 제거하면 원래대로 돌아옵니다.
- 그 밖의 경우(예: Team 플랜)는 값을 가져올 방법을 직접 골라야 합니다. [docs/USAGE.md](docs/USAGE.md)에 방법과 주의점이 있습니다.

## 문제 해결

| 증상 | 확인 |
|---|---|
| 위젯이 안 보임 | Hammerspoon이 켜져 있는지, 메뉴바 아이콘 → Reload Config. Console에 `claude-pet:` 오류가 있는지. 활동이 없으면 5시간 뒤 숨겨지니 새 세션을 시작해 보세요. |
| 펫이 안 움직임 | **새** Claude Code 세션인지. `ls ~/.claude-pet/state`에 세션 파일이 생기는지. `~/.claude/settings.json`에 `pet-state.sh` 훅이 있는지. |
| 소리가 거슬림 | `touch ~/.claude-pet/.mute` (켜기: `rm ~/.claude-pet/.mute`) |
| 위치를 초기화 | `hs -c 'hs.settings.clear("claudeCodePet.topLeft"); hs.reload()'` |
| 아이콘/클릭이 Claude를 못 엶 | `claudeApp`이 실제 앱 이름과 같은지. 새 채팅/새 세션 아이콘은 Claude 데스크톱 앱의 `claude://` 링크를 씁니다. 앱 버전에 따라 달라질 수 있습니다. |
| 설치 후 위젯이 안 뜸 / 다시 불러오기가 안 됨 | 설치 스크립트가 쓰는 `hs` 명령은 내 `~/.hammerspoon/init.lua`에 `require("hs.ipc")`가 있을 때만 동작합니다. 이 프로젝트는 일부러 켜지 않습니다(`hs.ipc`는 같은 사용자 권한의 프로세스가 Hammerspoon 안에서 코드를 실행할 수 있는 통로이기 때문). 없으면 메뉴바 Hammerspoon 아이콘 → Reload Config로 다시 불러오세요. |
| 예약 작업 같은 세션이 펫을 움직임 | 그 세션에 처음 보내는 프롬프트를 `[pet-quiet]`로 시작하면 펫과 알림음에서 제외됩니다. (프롬프트 맨 앞에 있을 때만 인식합니다.) |

## 동작 원리

```
Claude Code ──훅──> ~/.claude-pet/hooks/pet-state.sh ──> ~/.claude-pet/state/<세션id> (한 줄: working 등)
                                                                  │ 읽기
Hammerspoon ── claude-pet 모듈 ──> 떠 있는 캔버스(펫 + 아이콘 팝업)
```

- 모든 처리는 내 컴퓨터 안에서만 일어납니다. 펫이 네트워크로 보내는 것은 없습니다. (한 줄 설치를 쓰면 설치할 때 GitHub에서 이 저장소를 한 번 내려받습니다.) 훅은 프롬프트 내용이나 도구 결과를 저장하지 않고, 상태 단어 한 줄과 세션 id만 `~/.claude-pet/state/`에 남깁니다.
- 훅 스크립트는 `~/.claude-pet/hooks/`에 있고 Claude Code 이벤트마다 내 권한으로 실행됩니다. 그 폴더에 쓸 수 있는 프로세스는 `settings.json`을 고칠 수 있는 프로세스와 같은 신뢰 수준입니다.
- 취약점은 공개 이슈 말고 [SECURITY.md](SECURITY.md)의 방법으로 알려 주세요.
- 훅은 항상 정상 종료하도록 만들어져 있어서 Claude Code 동작을 막지 않습니다.
- 확인한 환경: macOS (Apple Silicon), Hammerspoon 1.1.1, Claude 데스크톱 앱.

## 테스트

```bash
python3 -m unittest discover -s tests -v   # 설치 도우미, 시트 생성기 (Pillow 필요)
bash tests/test_install.sh                 # 임시 HOME에서 설치/제거를 통째로 시험 (내 설정은 건드리지 않음)
```

## 라이선스

코드는 [MIT](LICENSE)입니다. `pets/jelly`의 그림은 저장소 소유자가 제공한 샘플 캐릭터이며 코드와 별개입니다. 자기 캐릭터로 바꿔 쓰세요.
