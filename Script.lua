--  Loader fuer Script-Bedwars.
--
--  Hier steht bewusst KEIN Skriptinhalt mehr. Frueher lag die verschluesselte
--  Payload samt Schluessel in derselben oeffentlichen Datei - wer sie hatte,
--  konnte beides offline zusammenrechnen und brauchte nie einen Key. Jetzt
--  liefert der Server das Skript erst nach bestandener Pruefung aus. Ohne
--  gueltigen Key gibt es nichts zu entschluesseln, weil nichts da ist.
--
--  Alles hier faellt im Zweifel ZU: kein Server, kein Skript.

local WORKER_URL      = "https://bedwars-auth.gamerscripting.workers.dev"
local BEDWARS_GAME_ID = 2619619496   -- gilt fuer alle BedWars-Places (Lobby, Ranked, Mega, ...)

local HttpService  = game:GetService("HttpService")
local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local LocalPlayer  = Players.LocalPlayer

local CONFIG_FOLDER = "KitDisplay"
local AUTH_FILE     = CONFIG_FOLDER .. "/auth.json"

local REASONS = {
	invalid_key   = "Invalid key.",
	revoked       = "This key has been revoked.",
	max_devices   = "Device limit reached for this key.",
	rate_limited  = "Too many attempts. Wait a few minutes.",
	bad_request   = "Internal error, please try again.",
	no_payload    = "Server is not serving the script right now.",
}

local function guiParent()
	local ok, hui = pcall(function() return gethui() end)
	return (ok and hui) or game:GetService("CoreGui")
end

local function loadAuth()
	local ok, data = pcall(function()
		if isfile and isfile(AUTH_FILE) then
			return HttpService:JSONDecode(readfile(AUTH_FILE))
		end
		return nil
	end)
	if ok and type(data) == "table" then return data end
	return {}
end

local function saveAuth(data)
	pcall(function()
		if not isfolder(CONFIG_FOLDER) then makefolder(CONFIG_FOLDER) end
		writefile(AUTH_FILE, HttpService:JSONEncode(data))
	end)
end

--  Dieselbe settings.json, die das Hauptskript pflegt - damit die Meldung
--  die wirklich belegte Taste nennt und nicht stur "H".
local function panelKeyName()
	local ok, name = pcall(function()
		local f = CONFIG_FOLDER .. "/settings.json"
		if isfile and isfile(f) then
			local s = HttpService:JSONDecode(readfile(f))
			if type(s) == "table" and type(s.keybinds) == "table" then
				return s.keybinds.panel
			end
		end
		return nil
	end)
	if ok and type(name) == "string" and name ~= "" then return name end
	return "H"
end

local function showToast(text, color, seconds)
	local gui = Instance.new("ScreenGui")
	gui.Name           = "KitDisplayToast"
	gui.ResetOnSpawn   = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder   = 998
	gui.Parent         = guiParent()

	local card = Instance.new("Frame")
	card.Size             = UDim2.fromOffset(0, 36)
	card.AutomaticSize    = Enum.AutomaticSize.X
	card.Position         = UDim2.new(0.5, 0, 1, -28)
	card.AnchorPoint      = Vector2.new(0.5, 1)
	card.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
	card.BackgroundTransparency = 0.05
	card.BorderSizePixel  = 0
	card.Parent           = gui
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)
	local cardStroke = Instance.new("UIStroke", card)
	cardStroke.Color        = Color3.fromRGB(90, 100, 120)
	cardStroke.Thickness    = 1
	cardStroke.Transparency = 0.5
	local pad = Instance.new("UIPadding", card)
	pad.PaddingLeft  = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)

	local label = Instance.new("TextLabel")
	label.Size                   = UDim2.new(0, 0, 1, 0)
	label.AutomaticSize          = Enum.AutomaticSize.X
	label.BackgroundTransparency = 1
	label.Font                   = Enum.Font.GothamMedium
	label.TextSize               = 13
	label.TextColor3             = color or Color3.fromRGB(230, 235, 245)
	label.Text                   = text
	label.AutoLocalize           = false
	label.Parent                 = card

	task.delay(seconds or 3.5, function()
		TweenService:Create(card, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(cardStroke, TweenInfo.new(0.4), { Transparency = 1 }):Play()
		TweenService:Create(label, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
		task.wait(0.4)
		gui:Destroy()
	end)
end

local function getHWID()
	local ok, id = pcall(function()
		if gethwid then return gethwid() end
		if get_hwid then return get_hwid() end
		if syn and syn.get_hwid then return syn.get_hwid() end
		return nil
	end)
	if ok and id and tostring(id) ~= "" then return tostring(id) end
	return nil
end

local function httpRequest(opts)
	local ok, res = pcall(function()
		local fn = request or http_request or (syn and syn.request)
		if not fn then return nil end
		return fn(opts)
	end)
	if ok then return res end
	return nil
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_LUT = {}
for i = 1, #B64 do B64_LUT[B64:sub(i, i)] = i - 1 end

local function b64decode(data)
	data = data:gsub("[^" .. B64 .. "=]", "")
	local out, n = {}, 0
	local bits, bitc = 0, 0
	for i = 1, #data do
		local c = data:sub(i, i)
		if c == "=" then break end
		local v = B64_LUT[c]
		if v then
			bits = bit32.bor(bit32.lshift(bits, 6), v)
			bitc = bitc + 6
			if bitc >= 8 then
				bitc = bitc - 8
				n = n + 1
				out[n] = string.char(bit32.band(bit32.rshift(bits, bitc), 0xFF))
			end
		end
	end
	return table.concat(out)
end

--  nil = Server nicht erreichbar. Das ist KEIN Freifahrtschein: ohne Antwort
--  gibt es keine Payload, also laeuft auch nichts.
local function callVerify(key, hwid)
	local res = httpRequest({
		Url     = WORKER_URL .. "/verify",
		Method  = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body    = HttpService:JSONEncode({
			key      = key,
			hwid     = hwid,
			userId   = LocalPlayer.UserId,
			username = LocalPlayer.Name,
		}),
	})
	if not res or not res.Body then return nil end
	local ok, decoded = pcall(function() return HttpService:JSONDecode(res.Body) end)
	if not ok or type(decoded) ~= "table" then return nil end
	return decoded
end

--  Fuehrt aus, was der Server geschickt hat. Die Markierung (w) wird
--  vorangestellt, damit eine geleakte Kopie ihre Herkunft mitfuehrt.
local function runPayload(result)
	if type(result.p) ~= "string" or result.p == "" then return false, "no_payload" end
	local source = (type(result.w) == "string" and result.w or "") .. b64decode(result.p)
	local chunk, err = loadstring(source)
	if not chunk then
		warn("[KitDisplay] payload failed to compile: " .. tostring(err))
		return false, "compile_error"
	end
	local ok, runErr = pcall(chunk)
	if not ok then
		warn("[KitDisplay] payload error: " .. tostring(runErr))
		return false, "runtime_error"
	end
	return true
end

local function showKeyPrompt(hwid, prefill, message)
	local gui = Instance.new("ScreenGui")
	gui.Name           = "KitDisplayAuth"
	gui.ResetOnSpawn   = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder   = 999
	gui.Parent         = guiParent()

	local card = Instance.new("Frame")
	card.Size             = UDim2.fromOffset(300, 172)
	card.Position         = UDim2.fromScale(0.5, 0.5)
	card.AnchorPoint      = Vector2.new(0.5, 0.5)
	card.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
	card.BorderSizePixel  = 0
	card.Parent           = gui
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 10)
	local cardStroke = Instance.new("UIStroke", card)
	cardStroke.Color     = Color3.fromRGB(90, 100, 120)
	cardStroke.Thickness = 1

	local title = Instance.new("TextLabel")
	title.Text            = "Key Required"
	title.Font            = Enum.Font.GothamBold
	title.TextSize        = 18
	title.TextColor3      = Color3.fromRGB(230, 235, 245)
	title.BackgroundTransparency = 1
	title.Size            = UDim2.new(1, -20, 0, 26)
	title.Position        = UDim2.fromOffset(10, 12)
	title.TextXAlignment  = Enum.TextXAlignment.Left
	title.AutoLocalize    = false
	title.Parent          = card

	local status = Instance.new("TextLabel")
	status.Text            = message or ""
	status.Font            = Enum.Font.Gotham
	status.TextSize        = 13
	status.TextWrapped     = true
	status.TextColor3      = Color3.fromRGB(240, 190, 110)
	status.BackgroundTransparency = 1
	status.Size            = UDim2.new(1, -20, 0, 32)
	status.Position        = UDim2.fromOffset(10, 40)
	status.TextXAlignment  = Enum.TextXAlignment.Left
	status.TextYAlignment  = Enum.TextYAlignment.Top
	status.AutoLocalize    = false
	status.Parent          = card

	local box = Instance.new("TextBox")
	box.PlaceholderText   = "Enter key..."
	box.Text              = prefill or ""
	box.ClearTextOnFocus  = false
	box.Font              = Enum.Font.Code
	box.TextSize          = 14
	box.TextColor3        = Color3.fromRGB(230, 235, 245)
	box.BackgroundColor3  = Color3.fromRGB(14, 15, 20)
	box.Size              = UDim2.new(1, -20, 0, 34)
	box.Position          = UDim2.fromOffset(10, 80)
	box.AutoLocalize      = false
	box.Parent            = card
	Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)

	local submit = Instance.new("TextButton")
	submit.Text             = "Confirm"
	submit.Font             = Enum.Font.GothamBold
	submit.TextSize         = 14
	submit.TextColor3       = Color3.fromRGB(230, 235, 245)
	submit.BackgroundColor3 = Color3.fromRGB(45, 49, 60)
	submit.Size             = UDim2.new(1, -20, 0, 32)
	submit.Position         = UDim2.fromOffset(10, 126)
	submit.AutoLocalize     = false
	submit.Parent           = card
	Instance.new("UICorner", submit).CornerRadius = UDim.new(0, 6)

	local busy = false
	local function attempt()
		if busy then return end
		local key = (box.Text:gsub("^%s+", ""):gsub("%s+$", ""))
		if key == "" then
			status.TextColor3 = Color3.fromRGB(235, 120, 120)
			status.Text       = "Key cannot be empty."
			return
		end
		busy = true
		status.TextColor3 = Color3.fromRGB(240, 190, 110)
		status.Text       = "Checking..."
		task.spawn(function()
			local result = callVerify(key, hwid)
			busy = false
			if result == nil then
				status.TextColor3 = Color3.fromRGB(235, 120, 120)
				status.Text       = "Server unreachable. Try again."
				return
			end
			if result.ok then
				saveAuth({ key = key })
				gui:Destroy()
				runPayload(result)
			else
				status.TextColor3 = Color3.fromRGB(235, 120, 120)
				status.Text       = REASONS[result.reason] or ("Error: " .. tostring(result.reason))
			end
		end)
	end

	submit.MouseButton1Click:Connect(attempt)
	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then attempt() end
	end)
end

local function main()
	if game.GameId ~= BEDWARS_GAME_ID then
		showToast("Unsupported game - this script only runs in BedWars",
			Color3.fromRGB(235, 120, 120), 6)
		warn("[KitDisplay] Unsupported game (GameId " .. tostring(game.GameId) .. ").")
		return
	end

	showToast(("Injected - press %s to open"):format(panelKeyName()), nil, 3.5)

	local hwid = getHWID()
	if not hwid then
		showToast("Your executor does not support gethwid()",
			Color3.fromRGB(235, 120, 120), 6)
		return
	end

	--  Gespeicherter Key: still versuchen. Klappt es, laeuft das Skript ohne
	--  Nachfrage; klappt es nicht, kommt der Dialog mit dem Grund.
	local auth = loadAuth()
	if type(auth.key) == "string" and auth.key ~= "" then
		local result = callVerify(auth.key, hwid)
		if result == nil then
			showToast("Server unreachable - script not started",
				Color3.fromRGB(235, 120, 120), 6)
			return
		end
		if result.ok then
			runPayload(result)
			return
		end
		showKeyPrompt(hwid, auth.key, REASONS[result.reason] or "Please confirm your key.")
		return
	end

	showKeyPrompt(hwid, nil, nil)
end

main()
