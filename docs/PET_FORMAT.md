# 펫 규격

펫은 폴더 하나입니다. `~/.claude-pet/pets/<id>/` 안에 두 파일이 있으면 됩니다.

```
pet.json
spritesheet.png
```

Codex 데스크톱 펫과 같은 규격(v2)이라서, 이 규격으로 만든 시트는 그대로 쓸 수 있습니다.

## spritesheet.png

- 크기 **1536 x 2288**, 투명 배경 PNG
- **8열 x 11줄**, 칸 하나는 **192 x 208**
- 줄마다 쓰는 프레임 수가 정해져 있고, 나머지 칸은 투명하게 둡니다.
- 캐릭터의 발 밑 기준점은 칸 가운데(x = 96)에서 아래쪽(y = 190쯤)입니다. 모든 프레임에서 같은 자리에 두세요. 점프나 늘어남을 위해 머리 위에 여유를 남기세요.

| 줄 | 이름 | 프레임 | 위젯이 쓰는 때 |
|---|---|---|---|
| 0 | idle | 6 | 평소. 눈 깜빡임을 넣는다면 0번이 눈 뜬 기본, 1~3번이 감기는 과정 |
| 1 | runRight | 8 | 펫을 오른쪽으로 끌 때 |
| 2 | runLeft | 8 | 펫을 왼쪽으로 끌 때 |
| 3 | wave | 4 | 확인이 필요할 때(두 번), 펫을 클릭할 때, 가끔 |
| 4 | jump | 5 | 작업 완료, 마우스를 올릴 때 |
| 5 | failed | 8 | (아직 연결 안 함) |
| 6 | waiting | 6 | 확인 대기 중 반복 |
| 7 | working | 6 | 작업 중 반복 |
| 8 | review | 6 | (아직 연결 안 함) |
| 9 | lookAround | 8 | 한가할 때 가끔 두리번 |
| 10 | (여분) | 8 | 쓰지 않음 (규격상 8칸) |

기본 프레임 간격은 `hammerspoon/claude-pet/pets.lua`의 `defaultAnim()`에 있습니다. idle은 프레임마다 간격이 다릅니다 (눈 뜬 채로 오래 있다가 빠르게 깜빡임).

## pet.json

```json
{
  "id": "jelly",
  "displayName": "Jelly",
  "description": "한 줄 설명",
  "spriteVersionNumber": 2,
  "spritesheetPath": "spritesheet.png",
  "animations": { "idle": { "secs": 0.25 } }
}
```

| 키 | 필수 | 설명 |
|---|---|---|
| `id` | 예 | 영문 소문자, 숫자, 하이픈. 폴더 이름과 같게 |
| `displayName` | 아니오 | 표시 이름 |
| `spriteVersionNumber` | 아니오 | `2` |
| `spritesheetPath` | 아니오 | 기본 `spritesheet.png`. 펫 폴더 안의 파일 이름만 허용합니다 (`/`나 `..`가 든 경로는 거부). `add-pet.sh`와 `install.sh`는 `spritesheet.png`만 복사하므로 이 이름을 쓰세요. |
| `animations` | 아니오 | 동작별 프레임 간격(초) 덮어쓰기. 숫자 하나(모든 프레임 같은 간격) 또는 프레임별 배열. 이름은 위 표의 영문 이름(`idle`, `wave`, `jump`, `waiting`, `working`, `lookAround`, `runRight`, `runLeft`, `failed`, `review`) |

## 그림 한 장으로 만들기

```bash
python3 tools/make_pet.py character.png --id my-pet --name "My Pet" --out pets/my-pet
```

| 옵션 | 설명 |
|---|---|
| `--id` | 펫 id (필수) |
| `--name` | 표시 이름 |
| `--out` | 출력 폴더 (기본 `pets/<id>`) |
| `--scale` | 캐릭터 크기 보정 (기본 1.0) |
| `--tolerance` | 배경이 불투명할 때 배경으로 볼 색 오차 (기본 8). 크게 하면 배경은 더 지워지지만 배경과 비슷한 색의 캐릭터 가장자리가 깎임 |
| `--no-blink` | 눈 깜빡임을 만들지 않음 |
| `--no-preview` | `preview.png`(줄별 확인용), `preview.gif`(README용)를 만들지 않음 |

생성된 `preview.png`를 열어 줄별로 잘렸거나 어색한 프레임이 없는지 확인하세요.

## 설치

```bash
./add-pet.sh --from pets/my-pet            # 만든 폴더를 ~/.claude-pet/pets/ 에 설치하고 config.json 을 그 펫으로 (Hammerspoon 을 다시 불러오면 적용)
./install.sh --pet my-pet                  # 저장소 pets/ 안의 펫으로 설치 (clone 한 경우)
```
