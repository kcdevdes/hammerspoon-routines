-- =========================
-- Notify helper (robust)
-- =========================
local function notify(title, text)
  -- 1) Try macOS Notification Center
  pcall(function()
    hs.notify.new({ title = title, informativeText = text }):send()
  end)
  -- 2) Always show an on-screen HUD as a fallback (so you can see something even if notifications are disabled)
  pcall(function()
    hs.alert.show(string.format("%s: %s", title, text), 2)
  end)
end

local function safeFocusAndMove(appName, unit, delaySec)
  hs.application.launchOrFocus(appName)
  hs.timer.doAfter(delaySec or 0.8, function()
    local win = hs.window.focusedWindow()
    if win then win:moveToUnit(unit) end
  end)
end

local function openUrlsInChrome(urls)
  for _, url in ipairs(urls) do
    hs.execute(string.format([[open -a "Google Chrome" "%s"]], url), true)
    hs.timer.usleep(150000)
  end
end

local function minimizeAllWindows(appName)
  local app = hs.application.get(appName)
  if not app then return end
  for _, w in ipairs(app:allWindows()) do
    w:minimize()
  end
end

local function mediaPlayPause()
  hs.eventtap.event.newSystemKeyEvent("PLAY", true):post()
  hs.eventtap.event.newSystemKeyEvent("PLAY", false):post()
end

-- (옵션) 앱 이름 탐색을 Spotlight까지 확장
hs.application.enableSpotlightForNameSearches(true)

-- =========================
-- Dock Apps Quitter (Cmd+Opt+0)
-- =========================
local PROTECTED_APPS = {
  ["Finder"] = true,
  ["Hammerspoon"] = true,
  ["Dock"] = true,
  ["SystemUIServer"] = true,
}

-- Dock에 점이 찍히는 “일반 앱”을 AppleScript로 가져옴
local function getDockAppNames()
  local script = [[
    tell application "System Events"
      set appNames to name of every process whose background only is false
    end tell
    return appNames
  ]]
  local ok, result = hs.osascript.applescript(script)
  if not ok then return {} end

  -- result는 Lua 테이블(배열)로 들어오는 경우가 대부분
  if type(result) == "table" then return result end

  -- 혹시 문자열로 들어오면 방어적으로 분리
  if type(result) == "string" then
    local t = {}
    for name in string.gmatch(result, "([^,]+)") do
      table.insert(t, (name:gsub("^%s+", ""):gsub("%s+$", "")))
    end
    return t
  end

  return {}
end

local function quitDockApps()
  local names = getDockAppNames()
  if #names == 0 then
    notify("Hammerspoon", "종료할 Dock 앱을 찾지 못했습니다.")
    return
  end

  local quitCount = 0
  local skipped = {}

  for _, name in ipairs(names) do
    if not PROTECTED_APPS[name] then
      local app = hs.application.get(name)
      -- getDockAppNames에 잡혔는데 get()이 nil이면 이름 불일치/특수 케이스일 수 있어 스킵
      if app then
        -- 정상 종료 시도 (당신 환경에서 terminate() 없음 → kill() 사용)
        app:kill()
        quitCount = quitCount + 1
      else
        table.insert(skipped, name)
      end
    end
  end

  if quitCount > 0 then
    notify("Hammerspoon", string.format("Dock 앱 %d개 종료 시도 완료 (⌘⌥0)", quitCount))
  else
    notify("Hammerspoon", "종료할 Dock 앱이 없거나 모두 보호 목록이었습니다.")
  end

  -- 디버깅이 필요하면 아래 로그를 활성화
  -- if #skipped > 0 then hs.printf("Skipped (not resolved): %s", hs.inspect(skipped)) end
end

-- =========================
-- Routine: Coding (Cmd+Opt+1)
-- =========================

hs.application.enableSpotlightForNameSearches(true)

local function getApp(appName)
  return hs.application.get(appName) or hs.application.find(appName)
end

-- Wait for a "real" main window, not the splash.
-- For IntelliJ, ignore tiny windows and windows with empty title.
local function waitForRealMainWindow(appName, timeoutSec, opts, cb)
  opts = opts or {}
  local minArea = opts.minArea or 250000 -- roughly filters splash/small windows
  local requireTitle = (opts.requireTitle ~= false)

  local deadline = hs.timer.secondsSinceEpoch() + (timeoutSec or 15)

  local function pickWindow(app)
    -- Try mainWindow first
    local w = app:mainWindow()
    if w then
      local f = w:frame()
      local area = f.w * f.h
      local title = w:title() or ""
      if area >= minArea and ((not requireTitle) or title ~= "") then
        return w
      end
    end

    -- Fall back: scan all windows for a "big" standard window
    for _, win in ipairs(app:allWindows()) do
      local f = win:frame()
      local area = f.w * f.h
      local title = win:title() or ""
      if area >= minArea and ((not requireTitle) or title ~= "") then
        return win
      end
    end

    return nil
  end

  local function tick()
    local app = getApp(appName)
    if app then
      local win = pickWindow(app)
      if win then
        cb(win, app)
        return
      end
    end

    if hs.timer.secondsSinceEpoch() < deadline then
      hs.timer.doAfter(0.25, tick)
    else
      notify("Hammerspoon", "메인 창 대기 실패: " .. appName)
    end
  end

  tick()
end

local function moveAppToUnit(appName, unit, waitOpts)
  hs.application.launchOrFocus(appName)
  waitForRealMainWindow(appName, 18, waitOpts, function(win, _)
    win:focus()
    win:moveToUnit(unit)
  end)
end

local function minimizeApp(appName)
  local app = getApp(appName)
  if not app then return end
  for _, w in ipairs(app:allWindows()) do
    pcall(function() w:minimize() end)
  end
end

-- Strong URL open: force Chrome bundle
local function openUrlsInChrome(urls)
  hs.application.launchOrFocus("Google Chrome")
  for _, url in ipairs(urls) do
    hs.urlevent.openURLWithBundle(url, "com.google.Chrome")
    hs.timer.usleep(180000)
  end
end

-- =========================
-- Coding Routine (Cmd+Option+1)
-- - IntelliJ + YouTube Music: left
-- - Chrome + ChatGPT: right
-- - No YT play request
-- - Chrome URLs must open
-- =========================
local function codingRoutine()
  notify("Hammerspoon", "Coding routine 시작 (⌘⌥1)")

  -- IntelliJ: wait for real main window (avoid splash)
  moveAppToUnit("IntelliJ IDEA", hs.layout.left50, {
    minArea = 300000,    -- splash 회피를 조금 더 강하게
    requireTitle = true  -- 메인 창은 타이틀이 있는 편
  })

  -- YouTube Music (PWA): left (재생 요청 없음)
  hs.timer.doAfter(0.8, function()
    moveAppToUnit("YouTube Music", hs.layout.left50, {
      minArea = 200000,
      requireTitle = false
    })
  end)

  -- ChatGPT: right
  hs.timer.doAfter(1.4, function()
    moveAppToUnit("ChatGPT", hs.layout.right50, {
      minArea = 200000,
      requireTitle = false
    })
  end)

  -- Chrome: right
  hs.timer.doAfter(2.0, function()
    moveAppToUnit("Google Chrome", hs.layout.right50, {
      minArea = 200000,
      requireTitle = false
    })
  end)

  -- Chrome URLs: must run (layout과 분리)
  hs.timer.doAfter(2.6, function()
    openUrlsInChrome({
      "https://github.com/kcdevdes",
      "https://velog.io"
    })
  end)

  hs.timer.doAfter(4.4, function()
    notify("Hammerspoon", "Coding routine 완료 (⌘⌥1)")
  end)
end

-- =========================
-- Pomodoro
-- =========================
-- =========================
-- Simple Pomodoro (Built-in)
-- =========================
local pomodoroTimer = nil
local breakTimer = nil

local function startPomodoro(workMin, breakMin)
  workMin = workMin or 25
  breakMin = breakMin or 5

  -- 기존 타이머 정리
  if pomodoroTimer then pomodoroTimer:stop() end
  if breakTimer then breakTimer:stop() end

  notify("Pomodoro", "집중 시작 (" .. workMin .. "분)")

  pomodoroTimer = hs.timer.doAfter(workMin * 60, function()
    notify("Pomodoro", "집중 종료 · 휴식 " .. breakMin .. "분")

    breakTimer = hs.timer.doAfter(breakMin * 60, function()
      notify("Pomodoro", "휴식 종료 · 다음 집중 준비")
    end)
  end)
end

-- =========================
-- Hotkey Binding
-- =========================
hs.hotkey.bind({ "cmd", "alt" }, "0", quitDockApps)  -- Dock 앱 종료(정리)
hs.hotkey.bind({ "cmd", "alt" }, "1", codingRoutine) -- 코딩 루틴

hs.hotkey.bind({ "cmd", "alt" }, "P", function() -- 포모도로 스타트
  startPomodoro(25, 5)
end)

hs.hotkey.bind({ "cmd", "alt", "shift" }, "P", function() -- 포모도로 중지
  if pomodoroTimer then
    pomodoroTimer:stop()
    pomodoroTimer = nil
  end
  if breakTimer then
    breakTimer:stop()
    breakTimer = nil
  end
  notify("Pomodoro", "Pomodoro/Break stopped")
end)

notify("Hammerspoon", "Config loaded")
