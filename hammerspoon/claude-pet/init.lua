-- claude-code-pet: Claude Code 상태를 보여 주는 떠 있는 펫 위젯 (Hammerspoon 모듈)
--   · 펫 동작: 작업 중 / 확인 대기 / 완료 / 대기, 끌면 달리고, 마우스를 올리면 폴짝
--   · 머리 위 숫자: 5시간/7일 사용량 (사용량 파일이 있을 때만)
--   · 마우스를 올리면 새 채팅 / 새 세션 아이콘, 클릭하면 Claude 창을 앞으로
-- 상태는 ~/.claude-pet/state/ 에서 읽는다 (hooks/pet-state.sh 가 Claude Code 훅에서 쓴다).
-- 주의: 여기서 require("hs.ipc") 를 하지 않는다. hs.ipc 는 `hs` 명령으로 Hammerspoon 안에서 코드를
-- 실행하게 해 주는 통로라서, 쓸지 말지는 사용자의 init.lua 가 정한다 (README 참고).

local config = require("claude-pet.config")
local pets = require("claude-pet.pets")

local M = {}
local refs = {}  -- 캔버스·타이머를 붙들어 두어 GC로 사라지지 않게 한다

function M.stop()
  for _, t in pairs(refs.timers or {}) do t:stop() end
  for _, c in pairs(refs.canvases or {}) do c:delete() end
  if refs.screenWatcher then refs.screenWatcher:stop() end
  refs = {}
end

-- 성공하면 true. 펫을 못 읽으면 알림만 띄우고 false.
function M.start(overrides)
  M.stop()
  local C = config.load(overrides)
  local pet, err = pets.load(C.petsDir, C.pet)
  if not pet then
    hs.printf("claude-pet: %s", err)
    hs.alert.show("claude-pet: " .. err, 5)
    return false
  end
  if C.autoLaunch then hs.autoLaunch(true) end
  math.randomseed(os.time())
  hs.fs.mkdir(C.petHome)
  hs.fs.mkdir(C.stateDir)
  refs.timers, refs.canvases = {}, {}

  local usageFile = C.stateDir .. "/.usage"
  local frames, ANIM, ROW_FRAMES = pet.frames, pet.anim, pets.ROW_FRAMES

  -- ===== 크기 =====
  local SCALE = C.scale
  local PAD = 8 * SCALE
  local iconSize = 80 * SCALE
  local PILL_H, PILL_PAD_X = 11 * SCALE, 6 * SCALE  -- 머리 위 사용량 알약
  local pillY = PAD                                  -- 그림자가 잘리지 않게 위에 여유
  local iconY = pillY + PILL_H + 1 * SCALE
  local canvasW = iconSize + PAD * 2
  local canvasH = iconY + iconSize + PAD
  local glowR = iconSize / 2 + 6 * SCALE
  local glowCenter = { x = PAD + iconSize / 2, y = iconY + iconSize / 2 }

  -- ===== 시간 =====
  local T = {
    inactive = C.inactiveHours * 3600,  -- 이 시간 동안 활동이 없으면 위젯 숨김
    tick = 0.2,                         -- 상태·사용량 읽기 주기
    anim = 0.04,                        -- 프레임 갱신 주기
    done = 12, waiting = 300,           -- 완료/대기 표시 유지(초)
    stale = 2 * 3600,                   -- 갱신 없는 세션은 무시 (종료 훅이 안 불린 경우)
    usageStale = 6 * 3600,              -- 오래된 사용량 숫자는 숨김
    prune = 24 * 3600,                  -- 시작할 때 하루 넘은 세션 파일 정리
    ignorePrune = 10 * 60,              -- 위젯에서 제외된 세션(ignore) 파일 보관
    fidgetMin = 20, fidgetMax = 45,     -- 한가할 때 두리번/손흔들기 간격
  }
  local PRIORITY = { "waiting", "working", "done" }  -- 여러 세션이면 앞쪽이 이긴다
  local BASE_ANIM = { idle = "idle", working = "working", waiting = "waiting", done = "idle" }
  local FIDGETS = { "lookAround", "lookAround", "wave" }

  -- ===== 색: 패널은 따뜻한 흰색 + 아주 옅은 테두리, 포인트만 분홍 =====
  local K = {
    ink = { red = 0.29, green = 0.20, blue = 0.18, alpha = 0.92 },
    panel = { red = 1.0, green = 0.984, blue = 0.976, alpha = 0.95 },
    edge = { red = 0.235, green = 0.110, blue = 0.078, alpha = 0.10 },
    hover = { red = 0.992, green = 0.698, blue = 0.714, alpha = 0.45 },
    warn = { red = 0.992, green = 0.867, blue = 0.882, alpha = 0.96 },  -- 70% 이상
    crit = { red = 0.980, green = 0.760, blue = 0.800, alpha = 0.96 },  -- 90% 이상
    clear = { red = 0, green = 0, blue = 0, alpha = 0 },
    glow = { red = 0.28, green = 0.85, blue = 0.75 },                   -- 확인 대기 글로우
  }
  local EDGE_W = 0.5 * SCALE
  local softShadow = { blurRadius = 6, color = { red = 0.24, green = 0.11, blue = 0.08, alpha = 0.18 },
    offset = { h = -1.5, w = 0 } }

  -- ===== 호버 팝업(아이콘 알약) 설정 =====
  local MENU = {
    buttons = {
      { icon = "chat",     url = "claude://claude.ai/new?surface=chat&source=desktop_action" },
      { icon = "terminal", url = "claude://code/new?source=desktop_action" },
    },
    btn = 17 * SCALE, icon = 9.5 * SCALE,                       -- 둥근 버튼 지름, 아이콘 한 변
    pad = 3 * SCALE, gap = 2 * SCALE, offset = 4 * SCALE,
    shadow = 8 * SCALE,                                         -- 그림자 여백
    slide = 8 * SCALE, showSec = 0.22, hideSec = 0.14, interval = 1 / 60,
    hoverShow = 0.2, hoverHide = 0.35, hoverInterval = 0.1,
  }
  local menuW = MENU.pad * 2 + MENU.btn * #MENU.buttons + MENU.gap * (#MENU.buttons - 1)  -- 보이는 알약 크기
  local menuH = MENU.pad * 2 + MENU.btn
  -- 위젯을 끌어 내릴 수 있는 하한선: 아래로 펼쳐지는 팝업이 화면 안에 들어올 자리
  local BOTTOM_RESERVE = menuH + MENU.offset - PAD + 6

  -- ===== 위치 =====
  local POS_KEY = "claudeCodePet.topLeft"  -- 끌어서 옮긴 위치 (hs.settings에 저장)

  local function screenFrameAt(pt)
    for _, s in ipairs(hs.screen.allScreens()) do
      local f = s:frame()
      if pt.x >= f.x and pt.x <= f.x + f.w and pt.y >= f.y and pt.y <= f.y + f.h then return f end
    end
    return nil
  end

  -- 위젯이 화면 안에, 그리고 아래로 펼쳐질 팝업 자리가 남는 범위에 있게 맞춘다
  local function clampTopLeft(tl, refPoint)
    local sf = screenFrameAt(refPoint or { x = tl.x + canvasW / 2, y = tl.y + canvasH / 2 })
      or hs.screen.mainScreen():frame()
    return {
      x = math.max(sf.x, math.min(tl.x, sf.x + sf.w - canvasW)),
      y = math.max(sf.y, math.min(tl.y, sf.y + sf.h - canvasH - BOTTOM_RESERVE)),
    }
  end

  local function defaultTopLeft()
    local f = hs.screen.mainScreen():frame()
    return clampTopLeft({ x = f.x + f.w - canvasW - C.margin, y = f.y + f.h },
      { x = f.x + f.w / 2, y = f.y + f.h / 2 })
  end

  -- 저장된 위치는 위젯 중심이 어느 화면 안에 있을 때만 쓴다 (모니터를 뺀 경우 대비)
  local function usableTopLeft(pt)
    if type(pt) ~= "table" or not pt.x or not pt.y then return nil end
    if screenFrameAt({ x = pt.x + canvasW / 2, y = pt.y + canvasH / 2 }) then
      return clampTopLeft({ x = pt.x, y = pt.y })
    end
    return nil
  end

  local startPos = usableTopLeft(hs.settings.get(POS_KEY)) or defaultTopLeft()
  local canvas = hs.canvas.new(hs.geometry.rect(startPos.x, startPos.y, canvasW, canvasH))
  refs.canvases.pet = canvas
  canvas:level(hs.canvas.windowLevels.floating)
  canvas:behavior({ hs.canvas.windowBehaviors.canJoinAllSpaces, hs.canvas.windowBehaviors.stationary })
  canvas:clickActivating(false)

  -- 모니터 구성이 바뀌면 위젯을 다시 범위 안으로
  refs.screenWatcher = hs.screen.watcher.new(function()
    local tl = canvas:topLeft()
    canvas:topLeft(clampTopLeft({ x = tl.x, y = tl.y }))
  end):start()

  -- ===== 상태(여러 곳에서 공유) =====
  local S = {
    state = "idle",            -- tick이 갱신하는 지금 상태
    overlay = nil,             -- 한 번 재생 중인 동작 { name, startedAt, repeats }
    lastActivity = os.time(),
    pulseT = 0,
    shownName = nil, shownIdx = nil,
    baseStart = hs.timer.secondsSinceEpoch(),
    nextFidget = hs.timer.secondsSinceEpoch() + math.random(T.fidgetMin, T.fidgetMax),
    lastFive = -2, lastWeek = -2,
  }
  local drag = { offset = nil, timer = nil, dir = "right", movingUntil = 0, travel = 0, startedAt = 0 }
  local DRAG = { interval = 0.016, runMinDx = 1, runHold = 0.18, clickTravel = 6, clickSec = 0.6 }
  local onPetClick  -- 아래 호버 메뉴 쪽에서 정의

  local function playOverlay(name, repeats)
    S.overlay = { name = name, startedAt = hs.timer.secondsSinceEpoch(), repeats = repeats or 1 }
  end

  -- ===== 끌어서 이동: 움직이는 동안은 가는 방향으로 달리고, 거의 안 움직인 채 놓으면 클릭 =====
  local function endDrag()
    if drag.timer then
      drag.timer:stop()
      drag.timer = nil
    end
    if not drag.offset then return end
    drag.offset = nil
    local clicked = drag.travel <= DRAG.clickTravel and hs.timer.secondsSinceEpoch() - drag.startedAt <= DRAG.clickSec
    local tl = canvas:topLeft()
    if usableTopLeft(tl) then
      hs.settings.set(POS_KEY, { x = tl.x, y = tl.y })
    else
      canvas:topLeft(defaultTopLeft())
      hs.settings.clear(POS_KEY)
    end
    if clicked then
      playOverlay("wave", 1)
      if onPetClick then onPetClick() end
    end
  end

  local function dragStep()
    if not drag.offset then return end
    if not hs.mouse.getButtons()[1] then
      endDrag()
      return
    end
    local m = hs.mouse.absolutePosition()
    local target = clampTopLeft({ x = m.x - drag.offset.x, y = m.y - drag.offset.y }, m)
    local cur = canvas:topLeft()
    local dx, dy = target.x - cur.x, target.y - cur.y
    drag.travel = drag.travel + math.abs(dx) + math.abs(dy)
    if math.abs(dx) >= DRAG.runMinDx then
      drag.dir = dx > 0 and "right" or "left"
      drag.movingUntil = hs.timer.secondsSinceEpoch() + DRAG.runHold
    end
    canvas:topLeft(target)
  end

  canvas:canvasMouseEvents(true, true, false, false)
  canvas:mouseCallback(function(_, event, _, x, y)
    if event == "mouseDown" then
      drag.offset = { x = x, y = y }
      drag.travel, drag.startedAt = 0, hs.timer.secondsSinceEpoch()
      if drag.timer then drag.timer:stop() end
      drag.timer = hs.timer.doEvery(DRAG.interval, dragStep)
      refs.timers.drag = drag.timer
    elseif event == "mouseUp" and drag.offset then
      endDrag()
    end
  end)

  -- ===== 캔버스 요소: 1 글로우, 2 아이콘, 3 사용량 알약, 4 사용량 글자 =====
  canvas[1] = {
    type = "circle", action = "fill", center = glowCenter, radius = glowR,
    fillColor = { red = K.glow.red, green = K.glow.green, blue = K.glow.blue, alpha = 0 },
  }
  canvas[2] = {
    type = "image", image = frames[ANIM.idle.row][1],
    frame = { x = PAD, y = iconY, w = iconSize, h = iconSize },
  }
  canvas[3] = {
    type = "rectangle", action = "strokeAndFill",
    fillColor = K.panel, strokeColor = K.edge, strokeWidth = EDGE_W,
    withShadow = true, shadow = softShadow,
    roundedRectRadii = { xRadius = PILL_H / 2, yRadius = PILL_H / 2 },
    frame = { x = 0, y = 0, w = 0, h = 0 },
  }
  canvas[4] = {
    type = "text", text = "", textFont = "AppleSDGothicNeo-SemiBold", textSize = 7.5 * SCALE,
    textColor = K.ink, textAlignment = "center",
    frame = { x = 0, y = 0, w = 0, h = 0 },
  }
  canvas:show()

  -- ===== 상태·사용량 읽기 =====
  local function eachSessionFile(visit)
    local ok, iter, dirObj = pcall(hs.fs.dir, C.stateDir)
    if not ok or not iter then return end
    for name in iter, dirObj do
      if name:sub(1, 1) ~= "." and not name:match("%.tmp$") then
        local path = C.stateDir .. "/" .. name
        local mtime = hs.fs.attributes(path, "modification")
        if mtime then visit(path, mtime) end
      end
    end
  end

  -- 세션별 상태를 모아 하나로: 대기 > 작업 > 완료 > idle. 두 번째 값은 가장 최근 활동 시각.
  local function readStatus()
    local now = os.time()
    local newest, activity = {}, nil
    eachSessionFile(function(path, mtime)
      local age = now - mtime
      if age > T.stale then return end
      local f = io.open(path, "r")
      local state = f and f:read("*l")
      if f then f:close() end
      if not state then return end
      -- [pet-quiet] 세션(예약 작업 등)은 끝나도 파일이 남으니 잠시 뒤 치운다
      if state == "ignore" and age > T.ignorePrune then
        os.remove(path)
        return
      end
      activity = math.max(activity or 0, mtime)
      if state == "done" and age > T.done then return end
      if state == "waiting" and age > T.waiting then return end
      newest[state] = math.max(newest[state] or 0, mtime)
    end)
    for _, state in ipairs(PRIORITY) do
      if newest[state] then return state, activity end
    end
    return "idle", activity
  end

  local function readUsage()
    local f = io.open(usageFile, "r")
    if not f then return nil, nil end
    local line = f:read("*l")
    f:close()
    if not line then return nil, nil end
    local five, week, stamp = line:match("([%-%d%.]+)|([%-%d%.]+)|(%d+)")
    if not stamp or os.time() - tonumber(stamp) > T.usageStale then return nil, nil end
    five, week = tonumber(five), tonumber(week)
    if five and five < 0 then five = nil end
    if week and week < 0 then week = nil end
    return five, week
  end

  -- ===== 머리 위 사용량 알약: "5h 19% · 7d 21%". 70%/90%를 넘으면 바탕이 분홍으로 =====
  local function pctShown(v) return C.showRemaining and (100 - v) or v end

  local function pillFillFor(maxUsed)
    if maxUsed >= 90 then return K.crit end
    if maxUsed >= 70 then return K.warn end
    return K.panel
  end

  local function usageLabel(five, week)
    local parts = {}
    -- .usage 에 19.5 같은 소수가 들어와도 %d 서식 오류로 타이머가 멈추지 않게 반올림한다
    local function whole(v) return math.floor(pctShown(v) + 0.5) end
    if five then parts[#parts + 1] = ("5h %d%%"):format(whole(five)) end
    if week then parts[#parts + 1] = ("7d %d%%"):format(whole(week)) end
    return table.concat(parts, " · ")
  end

  -- 캔버스 요소의 중첩 테이블은 제자리 수정이 안 먹을 수 있어서 frame을 통째로 다시 넣는다
  local function updateUsagePill(five, week)
    local label = C.showUsage and usageLabel(five, week) or ""
    if label == "" then
      canvas[3].frame = { x = 0, y = 0, w = 0, h = 0 }  -- 데이터가 없으면 숨김
      canvas[4].text = ""
      return
    end
    canvas[4].text = label
    local size = canvas:minimumTextSize(4, label)
    local w = size.w + PILL_PAD_X * 2
    local x = (canvasW - w) / 2
    canvas[3].fillColor = pillFillFor(math.max(five or 0, week or 0))
    canvas[3].frame = { x = x, y = pillY, w = w, h = PILL_H }
    canvas[4].frame = { x = x, y = pillY + (PILL_H - size.h) / 2, w = w, h = size.h }
  end

  -- ===== 호버 팝업 (아이콘 알약) =====
  -- 16x16 격자에 그린 선 아이콘. 한 경로는 점 목록, closed면 닫힌 도형, width는 선 굵기(격자 단위).
  local ICON_PATHS = {
    chat = {  -- 말풍선
      { pts = { { 4.5, 3 }, { 11.5, 3 }, { 14, 5.5 }, { 14, 8.5 }, { 11.5, 11 }, { 7.5, 11 },
                { 4.5, 13.6 }, { 4.5, 11 }, { 2, 8.5 }, { 2, 5.5 } }, closed = true },
    },
    terminal = {  -- 터미널 프롬프트 (Code 세션)
      { pts = { { 4, 3 }, { 12, 3 }, { 14, 5 }, { 14, 11 }, { 12, 13 }, { 4, 13 }, { 2, 11 }, { 2, 5 } }, closed = true },
      { pts = { { 5.2, 6.6 }, { 7.6, 8.2 }, { 5.2, 9.8 } } },
      { pts = { { 9, 10 }, { 11.4, 10 } } },
    },
  }

  local function addIcon(cv, kind, cx, cy, size)
    local u = size / 16
    local ox, oy = cx - size / 2, cy - size / 2
    for _, path in ipairs(ICON_PATHS[kind]) do
      local coords = {}
      for _, p in ipairs(path.pts) do coords[#coords + 1] = { x = ox + p[1] * u, y = oy + p[2] * u } end
      cv[cv:elementCount() + 1] = {
        type = "segments", action = "stroke", coordinates = coords, closed = path.closed or false,
        strokeColor = K.ink, strokeWidth = (path.width or 1.3) * u,
        strokeCapStyle = "round", strokeJoinStyle = "round",
      }
    end
  end

  local menuCanvas = hs.canvas.new({ x = 0, y = 0, w = menuW + MENU.shadow * 2, h = menuH + MENU.shadow * 2 })
  refs.canvases.menu = menuCanvas
  menuCanvas:level(hs.canvas.windowLevels.floating)
  menuCanvas:behavior({ hs.canvas.windowBehaviors.canJoinAllSpaces, hs.canvas.windowBehaviors.stationary })
  menuCanvas:clickActivating(false)  -- 눌러도 Hammerspoon이 앞으로 나오지 않게

  local function buttonCenter(i)  -- 알약 기준(왼쪽 위가 원점) 버튼 중심
    return MENU.pad + (i - 1) * (MENU.btn + MENU.gap) + MENU.btn / 2, MENU.pad + MENU.btn / 2
  end

  menuCanvas[1] = {
    type = "rectangle", action = "strokeAndFill",
    fillColor = K.panel, strokeColor = K.edge, strokeWidth = EDGE_W,
    withShadow = true, shadow = softShadow,
    roundedRectRadii = { xRadius = menuH / 2, yRadius = menuH / 2 },
    frame = { x = MENU.shadow, y = MENU.shadow, w = menuW, h = menuH },
  }
  local hoverEl = {}  -- 버튼 번호 -> 호버 원 요소 번호
  for i, b in ipairs(MENU.buttons) do
    local cx, cy = buttonCenter(i)
    cx, cy = cx + MENU.shadow, cy + MENU.shadow
    hoverEl[i] = menuCanvas:elementCount() + 1
    menuCanvas[hoverEl[i]] = {
      type = "circle", action = "fill", center = { x = cx, y = cy }, radius = MENU.btn / 2, fillColor = K.clear,
    }
    addIcon(menuCanvas, b.icon, cx, cy, MENU.icon)
  end

  local menu = { shown = false, hoverIdx = nil, anchor = { x = 0, y = 0 }, p = 0, animTimer = nil }

  local function menuButtonAt(x, y)  -- 알약 기준 좌표
    for i = 1, #MENU.buttons do
      local cx, cy = buttonCenter(i)
      if (x - cx) ^ 2 + (y - cy) ^ 2 <= (MENU.btn / 2 + 1) ^ 2 then return i end
    end
    return nil
  end

  local function setMenuHover(idx)
    if idx == menu.hoverIdx then return end
    menu.hoverIdx = idx
    for i = 1, #MENU.buttons do
      menuCanvas[hoverEl[i]].fillColor = (i == idx) and K.hover or K.clear
    end
  end

  -- 팝업은 위젯 아이콘 바로 아래 가운데에 붙는다. 하한선 덕분에 항상 아래에 들어온다.
  local function placeBelowPet(w)
    local pf = canvas:frame()
    local sf = screenFrameAt({ x = pf.x + pf.w / 2, y = pf.y + pf.h / 2 }) or hs.screen.mainScreen():frame()
    local x = math.max(sf.x, math.min(pf.x + (pf.w - w) / 2, sf.x + sf.w - w))
    return { x = x, y = pf.y + pf.h - PAD + MENU.offset }
  end

  -- 진행도 p(0~1): 투명도는 p, 위치는 위젯 쪽에서 MENU.slide만큼 위에서 최종 위치로 내려온다
  local function applyMenuProgress(p)
    menu.p = p
    menuCanvas:alpha(p)
    menuCanvas:topLeft({ x = menu.anchor.x - MENU.shadow, y = menu.anchor.y - MENU.shadow - (1 - p) * MENU.slide })
  end

  -- 지금 진행도에서 target(1=나타남, 0=사라짐)까지 감속 곡선(easeOutCubic)으로 이어서 움직인다
  local function animateMenuTo(target, fullSec, onDone)
    if menu.animTimer then menu.animTimer:stop() end
    local p0, t0 = menu.p, hs.timer.secondsSinceEpoch()
    local dur = math.max(0.04, fullSec * math.abs(target - p0))
    menu.animTimer = hs.timer.doEvery(MENU.interval, function()
      local k = math.min(1, (hs.timer.secondsSinceEpoch() - t0) / dur)
      applyMenuProgress(p0 + (target - p0) * (1 - (1 - k) ^ 3))
      if k >= 1 then
        menu.animTimer:stop()
        menu.animTimer = nil
        if onDone then onDone() end
      end
    end)
    refs.timers.menu = menu.animTimer
  end

  local function showMenu()
    if menu.shown then return end
    menu.shown = true
    menu.anchor = placeBelowPet(menuW)
    applyMenuProgress(menu.p)
    if not menuCanvas:isShowing() then menuCanvas:show() end
    animateMenuTo(1, MENU.showSec)
  end

  local function hideMenu()
    if not menu.shown then return end
    menu.shown = false
    setMenuHover(nil)
    animateMenuTo(0, MENU.hideSec, function() menuCanvas:hide() end)
  end

  -- URL을 Claude 앱에 넘기고 창을 앞으로 올린다 (URL이 없으면 창만 올린다)
  local function openClaude(url)
    if url then hs.urlevent.openURL(url) end
    hs.timer.doAfter(0.3, function() hs.application.launchOrFocus(C.claudeApp) end)
  end

  -- 확인이 필요한 세션이 있으면(대기 상태) 그 세션으로, 아니면 Claude 창만 앞으로
  onPetClick = function()
    hideMenu()
    if S.state == "waiting" then
      openClaude("claude://code/needs-input?source=desktop_action")
    else
      openClaude(nil)
    end
  end

  menuCanvas:canvasMouseEvents(false, true, false, false)
  menuCanvas:mouseCallback(function(_, event, _, x, y)
    if event ~= "mouseUp" then return end
    local idx = menuButtonAt(x - MENU.shadow, y - MENU.shadow)
    if not idx then return end
    hideMenu()
    openClaude(MENU.buttons[idx].url)
  end)

  local function inRect(p, r) return p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h end

  -- 호버 판정: 위젯(팝업이 떠 있으면 위젯+팝업+그 사이 틈)을 감싼 사각형 안에 커서가 있는가
  local function hoverArea()
    local pf = canvas:frame()
    if not menu.shown then return pf end
    local mf = { x = menu.anchor.x, y = menu.anchor.y, w = menuW, h = menuH }
    local x1, y1 = math.min(pf.x, mf.x), math.min(pf.y, mf.y)
    local x2, y2 = math.max(pf.x + pf.w, mf.x + mf.w), math.max(pf.y + pf.h, mf.y + mf.h)
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
  end

  local hover = { since = nil, leftSince = nil }

  local function hoverTick()
    if drag.offset or not canvas:isShowing() then
      hideMenu()
      hover.since = nil
      return
    end
    local now = hs.timer.secondsSinceEpoch()
    local m = hs.mouse.absolutePosition()
    if inRect(m, hoverArea()) then
      hover.leftSince = nil
      if not hover.since then
        hover.since = now
        -- 마우스를 올리면 폴짝 (한가할 때만)
        if S.state == "idle" or S.state == "done" then playOverlay("jump", 1) end
      end
      if C.hoverMenu and not menu.shown and now - hover.since >= MENU.hoverShow then showMenu() end
      if menu.shown then setMenuHover(menuButtonAt(m.x - menu.anchor.x, m.y - menu.anchor.y)) end
    else
      hover.since = nil
      hover.leftSince = hover.leftSince or now
      if menu.shown and now - hover.leftSince >= MENU.hoverHide then hideMenu() end
    end
  end

  -- ===== 애니메이션: 끄는 중 달리기 > 한 번 재생(점프·손흔들기·두리번) > 상태별 바탕 동작 =====
  local function cycleSecs(a)
    if type(a.secs) == "number" then return a.secs * ROW_FRAMES[a.row] end
    local sum = 0
    for _, s in ipairs(a.secs) do sum = sum + s end
    return sum
  end

  local function frameIndexAt(a, t)
    local n = ROW_FRAMES[a.row]
    if type(a.secs) == "number" then return math.floor(t / a.secs) % n + 1 end
    local pos = t % cycleSecs(a)
    for i, s in ipairs(a.secs) do
      if pos < s then return i end
      pos = pos - s
    end
    return n
  end

  local function onStateChange(to)
    S.state = to
    S.baseStart = hs.timer.secondsSinceEpoch()
    if to == "done" then
      playOverlay("jump", 1)
    elseif to == "waiting" then
      playOverlay("wave", 2)
    end
  end

  local function animTick()
    local now = hs.timer.secondsSinceEpoch()
    local name, t

    if drag.offset and now < drag.movingUntil then
      name, t = (drag.dir == "right") and "runRight" or "runLeft", now
    elseif S.overlay then
      t = now - S.overlay.startedAt
      if t >= cycleSecs(ANIM[S.overlay.name]) * S.overlay.repeats then
        S.overlay = nil
      else
        name = S.overlay.name
      end
    end
    if not name then
      name, t = BASE_ANIM[S.state] or "idle", now - S.baseStart
    end

    local a = ANIM[name]
    local idx = frameIndexAt(a, t)
    if name ~= S.shownName or idx ~= S.shownIdx then
      canvas[2].image = frames[a.row][idx]
      S.shownName, S.shownIdx = name, idx
    end
  end

  local function maybeFidget(state)
    local now = hs.timer.secondsSinceEpoch()
    if state ~= "idle" or S.overlay or drag.offset then
      if state ~= "idle" then S.nextFidget = now + math.random(T.fidgetMin, T.fidgetMax) end
      return
    end
    if now >= S.nextFidget then
      playOverlay(FIDGETS[math.random(#FIDGETS)], 1)
      S.nextFidget = now + math.random(T.fidgetMin, T.fidgetMax)
    end
  end

  local function tick()
    local state, activity = readStatus()
    if activity then S.lastActivity = math.max(S.lastActivity, activity) end

    if os.time() - S.lastActivity > T.inactive then
      if canvas:isShowing() then canvas:hide() end
      return
    elseif not canvas:isShowing() then
      canvas:show()
    end

    if state ~= S.state then onStateChange(state) end
    maybeFidget(state)

    if state == "waiting" then
      S.pulseT = S.pulseT + T.tick
      local a = 0.20 + 0.35 * (0.5 + 0.5 * math.sin(S.pulseT * 3.2))
      canvas[1].fillColor = { red = K.glow.red, green = K.glow.green, blue = K.glow.blue, alpha = a }
    elseif canvas[1].fillColor.alpha ~= 0 then
      canvas[1].fillColor = { red = K.glow.red, green = K.glow.green, blue = K.glow.blue, alpha = 0 }
      S.pulseT = 0
    end

    local five, week = readUsage()
    if five ~= S.lastFive or week ~= S.lastWeek then
      updateUsagePill(five, week)
      S.lastFive, S.lastWeek = five, week
    end
  end

  -- 하루 넘은 세션 파일은 시작할 때 치운다
  local now = os.time()
  eachSessionFile(function(path, mtime)
    if now - mtime > T.prune then os.remove(path) end
  end)

  tick()
  animTick()
  refs.timers.tick = hs.timer.doEvery(T.tick, tick)
  refs.timers.anim = hs.timer.doEvery(T.anim, animTick)
  refs.timers.hover = hs.timer.doEvery(MENU.hoverInterval, hoverTick)

  -- 확인·디버그용 (hs -c 'print(hs.inspect(require("claude-pet").info()))')
  function M.info()
    return { pet = pet.id, state = S.state, playing = S.shownName, frame = S.shownIdx,
             menuShown = menu.shown, topLeft = canvas:topLeft(), bottomReserve = BOTTOM_RESERVE }
  end
  -- 테스트용: 캔버스와 팝업을 직접 다룰 수 있게 내보낸다 (일반 사용에는 필요 없음)
  M._debug = { canvas = canvas, menuCanvas = menuCanvas, showMenu = showMenu, hideMenu = hideMenu }
  return true
end

return M
