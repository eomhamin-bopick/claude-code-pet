# 보안

## 취약점 신고

이 저장소의 **Security** 탭에서 "Report a vulnerability"(비공개 보안 권고)로 알려 주세요. 공개 이슈에는 올리지 마세요.

## 이 프로젝트가 하는 일 (범위 확인용)

- `~/.claude/settings.json`에 훅 8개를 추가해서 Claude Code 이벤트마다 `~/.claude-pet/hooks/pet-state.sh`를 실행합니다.
- 그 스크립트는 상태 단어 한 줄과 세션 id를 `~/.claude-pet/state/`에 씁니다. 프롬프트와 도구 결과는 저장하지 않습니다.
- Hammerspoon 모듈이 그 파일을 읽어서 화면에 펫을 그립니다. 네트워크 요청을 하지 않습니다.
- 설치할 때 `~/.hammerspoon/init.lua`, `~/.claude/settings.json`을 바꾸고, 바꾸기 전에 백업을 만듭니다.

## 알려진 한계

- 한 줄 설치(`bootstrap.sh`)는 내려받은 파일의 서명을 검증하지 않습니다. 릴리스 태그나 커밋 SHA로 고정해서 쓰세요.
- 설치된 훅 스크립트는 사용자 권한으로 매번 실행됩니다. `~/.claude-pet/hooks/`에 쓸 수 있는 프로세스는 `settings.json`을 고칠 수 있는 프로세스와 같은 수준의 신뢰가 필요합니다.
- 외부에서 받은 펫(`pet.json` + `spritesheet.png`)의 그림 파일은 macOS 이미지 해석기가 엽니다. 신뢰하는 출처의 펫만 쓰세요.
