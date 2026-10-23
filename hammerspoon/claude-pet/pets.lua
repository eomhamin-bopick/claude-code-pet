-- 펫 불러오기: <petsDir>/<id>/pet.json + spritesheet.png (Codex 펫 규격: 8열 x 11줄, 칸 192x208)
local M = {}

M.CELL_W, M.CELL_H, M.SHEET_W = 192, 208, 1536
M.ROW_FRAMES = { [0] = 6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8 }  -- 줄별 프레임 수 (0번 줄부터)

-- 동작 표: row = 시트 줄 번호, secs = 프레임당 초(숫자) 또는 프레임별 초(표)
-- pet.json 의 "animations": { "idle": { "secs": 0.25 } } 로 펫마다 덮어쓸 수 있다.
local function defaultAnim()
  return {
    idle       = { row = 0,  secs = { 1.4, 0.12, 0.2, 0.12, 0.5, 0.5 } },  -- 눈 깜빡임
    runRight   = { row = 1,  secs = 0.09 },                                 -- 끌 때 오른쪽으로
    runLeft    = { row = 2,  secs = 0.09 },                                 -- 끌 때 왼쪽으로
    wave       = { row = 3,  secs = 0.14 },                                 -- 클릭, 확인 요청
    jump       = { row = 4,  secs = 0.12 },                                 -- 작업 완료, 호버
    failed     = { row = 5,  secs = 0.14 },                                 -- (아직 연결 안 함)
    waiting    = { row = 6,  secs = 0.25 },                                 -- 확인 대기
    working    = { row = 7,  secs = 0.22 },                                 -- 작업 중
    review     = { row = 8,  secs = 0.22 },                                 -- (아직 연결 안 함)
    lookAround = { row = 9,  secs = 0.14 },                                 -- 가끔 두리번
  }
end

-- 성공하면 { id, name, frames[row][i], anim }, 실패하면 nil, 이유
function M.load(petsDir, id)
  local dir = petsDir .. "/" .. id
  local meta = hs.json.read(dir .. "/pet.json")
  if type(meta) ~= "table" then return nil, "pet.json 을 읽을 수 없습니다: " .. dir end

  -- 시트는 펫 폴더 안의 파일 이름만 허용한다 (인터넷에서 받은 pet.json 이 다른 경로를 가리키지 못하게)
  local sheetName = meta.spritesheetPath
  if sheetName == nil then sheetName = "spritesheet.png" end
  if type(sheetName) ~= "string" or sheetName == "" or sheetName:find("[/\\]") or sheetName:find("^%.") then
    return nil, "spritesheetPath 는 펫 폴더 안의 파일 이름이어야 합니다: " .. dir
  end
  local sheet = hs.image.imageFromPath(dir .. "/" .. sheetName)
  if not sheet then return nil, "스프라이트 시트를 읽을 수 없습니다: " .. dir end
  local px = sheet:size().w / M.SHEET_W  -- 이미지 DPI가 72가 아닐 때 보정

  local frames = {}
  for row = 0, #M.ROW_FRAMES do
    frames[row] = {}
    for i = 1, M.ROW_FRAMES[row] do
      frames[row][i] = sheet:croppedCopy({
        x = (i - 1) * M.CELL_W * px, y = row * M.CELL_H * px, w = M.CELL_W * px, h = M.CELL_H * px,
      })
    end
  end

  -- 프레임 간격(초)은 0.02~5 사이의 숫자만 받는다 (이상한 값이 타이머 오류를 반복해서 내지 않게)
  local function validSecs(v)
    local function ok(n) return type(n) == "number" and n >= 0.02 and n <= 5 end
    if type(v) == "table" then
      if #v == 0 then return false end
      for _, n in ipairs(v) do if not ok(n) then return false end end
      return true
    end
    return ok(v)
  end

  local anim = defaultAnim()
  if type(meta.animations) == "table" then
    for name, override in pairs(meta.animations) do
      if anim[name] and type(override) == "table" and validSecs(override.secs) then
        anim[name].secs = override.secs
      end
    end
  end
  return { id = id, name = meta.displayName or id, frames = frames, anim = anim }
end

return M
