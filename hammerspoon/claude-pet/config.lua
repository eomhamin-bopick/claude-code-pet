-- 설정: 기본값 < ~/.claude-pet/config.json < require("claude-pet").start({...}) 인자
local M = {}

local HOME = os.getenv("HOME")

local DEFAULTS = {
  pet = "jelly",          -- ~/.claude-pet/pets/<id>/ 안의 펫
  scale = 1.6,            -- 위젯 전체 크기 배율
  showUsage = true,       -- 머리 위 사용량 알약 (사용량 파일이 없으면 저절로 숨겨짐)
  showRemaining = false,  -- false: 쓴 %, true: 남은 %
  hoverMenu = true,       -- 마우스를 올리면 새 채팅/새 세션 아이콘
  autoLaunch = false,     -- true: 로그인할 때 Hammerspoon 자동 실행
  claudeApp = "Claude",   -- 클릭하면 앞으로 올릴 앱 이름
  inactiveHours = 5,      -- 이 시간 동안 활동이 없으면 위젯을 숨김
  margin = 24,            -- 첫 위치(오른쪽 아래 구석)에서 화면 가장자리와의 간격
}

-- 데이터 폴더: start({ petHome = "..." }) > 환경변수 CLAUDE_PET_HOME > ~/.claude-pet
M.petHome = os.getenv("CLAUDE_PET_HOME") or (HOME .. "/.claude-pet")

local function merge(into, from)
  if type(from) ~= "table" then return end
  for key, default in pairs(DEFAULTS) do
    local value = from[key]
    if value ~= nil and type(value) == type(default) then into[key] = value end
  end
end

function M.load(overrides)
  local home = (type(overrides) == "table" and type(overrides.petHome) == "string") and overrides.petHome
    or M.petHome
  local cfg = {}
  for key, value in pairs(DEFAULTS) do cfg[key] = value end
  merge(cfg, hs.json.read(home .. "/config.json"))
  merge(cfg, overrides)
  cfg.petHome, cfg.stateDir, cfg.petsDir = home, home .. "/state", home .. "/pets"
  return cfg
end

return M
