--[[
    Ollama Code Assistant for Roblox Studio
    ----------------------------------------
    REQUIRES: proxy.js running locally (see README.md)
    
    The plugin communicates with a local Node.js proxy on port 3000,
    which forwards requests to Ollama on port 11434.
    
    Setup:
    1. Install Node.js
    2. Run: node proxy.js
    3. Install this plugin in Roblox Studio
    4. Enable HTTP requests in Studio: File → Game Settings → Security → Allow HTTP Requests
--]]

-- Services
local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local ScriptEditorService = game:GetService("ScriptEditorService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local StudioService = game:GetService("StudioService")

-- Plugin State
local PROXY_URL = "http://localhost:3000"
local DEFAULT_MODEL = "codellama:7b"
local PLUGIN_TITLE = "Ollama Code Assistant"
local VERSION = "1.0.0"

local state = {
    guiEnabled = false,
    model = DEFAULT_MODEL,
    proxyUrl = PROXY_URL,
    isLoading = false,
    chatHistory = {},
    -- Saved settings
    savedModel = plugin:GetSetting("model") or DEFAULT_MODEL,
    savedProxy = plugin:GetSetting("proxyUrl") or PROXY_URL,
}

state.model = state.savedModel
state.proxyUrl = state.savedProxy

-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================

local function saveSettings()
    plugin:SetSetting("model", state.model)
    plugin:SetSetting("proxyUrl", state.proxyUrl)
end

local function showNotification(title, text, duration)
    -- Use pcall because notifications can fail in certain contexts
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = duration or 4,
        })
    end)
end

local function getSelectedScript()
    local sel = Selection:Get()
    if #sel > 0 then
        local obj = sel[1]
        if obj:IsA("LuaSourceContainer") then
            return obj
        end
    end
    return nil
end

-- ============================================================
-- OLLAMA API (via proxy)
-- ============================================================

local function callOllama(prompt, systemPrompt, onSuccess, onError)
    if state.isLoading then
        onError("Already processing a request. Please wait.")
        return
    end

    state.isLoading = true

    local messages = {}
    -- Include chat history for context
    for _, msg in ipairs(state.chatHistory) do
        table.insert(messages, msg)
    end
    table.insert(messages, { role = "user", content = prompt })

    local body = HttpService:JSONEncode({
        model = state.model,
        system = systemPrompt or "You are an expert Roblox Lua scripting assistant. Write clean, well-commented Roblox Luau code. Use modern Roblox APIs. Always follow Roblox best practices.",
        messages = messages,
        stream = false,
    })

    -- Roblox HttpService.RequestAsync is the correct method for plugin HTTP calls
    local success, result = pcall(function()
        return HttpService:RequestAsync({
            Url = state.proxyUrl .. "/chat",
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
            },
            Body = body,
        })
    end)

    state.isLoading = false

    if not success then
        onError("HTTP Error: " .. tostring(result) .. "\n\nMake sure:\n• proxy.js is running (node proxy.js)\n• Ollama is running\n• HTTP requests are enabled in Studio Settings → Security")
        return
    end

    if not result.Success then
        onError("Request failed: HTTP " .. result.StatusCode .. " — " .. tostring(result.Body))
        return
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(result.Body)
    end)

    if not ok or not data then
        onError("Failed to parse response from proxy.")
        return
    end

    if data.error then
        onError("Ollama error: " .. tostring(data.error))
        return
    end

    local responseText = ""
    if data.message and data.message.content then
        responseText = data.message.content
    elseif data.content then
        responseText = data.content
    else
        onError("Unexpected response format from proxy.")
        return
    end

    -- Update chat history
    table.insert(state.chatHistory, { role = "user", content = prompt })
    table.insert(state.chatHistory, { role = "assistant", content = responseText })

    -- Keep history manageable (last 10 exchanges)
    while #state.chatHistory > 20 do
        table.remove(state.chatHistory, 1)
    end

    onSuccess(responseText)
end

local function extractCodeBlock(text)
    -- Try to extract Lua code block from markdown
    local code = text:match("```lua\n(.-)```")
        or text:match("```luau\n(.-)```")
        or text:match("```\n(.-)```")
    if code then
        return code:gsub("^%s+", ""):gsub("%s+$", "")
    end
    -- If no code block, return as-is (might be plain code)
    return text
end

-- ============================================================
-- CODE INSERTION
-- ============================================================

local function insertIntoSelected(code)
    local script = getSelectedScript()
    if not script then
        return false, "No Script or LocalScript selected. Select one in the Explorer first."
    end

    local ok, err = pcall(function()
        ChangeHistoryService:SetWaypoint("Before Ollama Insert")
        local existing = script.Source or ""
        if existing == "" then
            script.Source = "-- Generated by Ollama Code Assistant\n\n" .. code
        else
            script.Source = existing .. "\n\n-- Generated by Ollama Code Assistant\n" .. code
        end
        ChangeHistoryService:SetWaypoint("After Ollama Insert")
    end)

    if not ok then return false, err end
    return true, "Code appended to " .. script.Name
end

local function createNewScript(code, asLocal)
    local scriptType = asLocal and "LocalScript" or "Script"
    local ok, err = pcall(function()
        ChangeHistoryService:SetWaypoint("Before Ollama CreateScript")
        local newScript = Instance.new(scriptType)
        newScript.Name = "OllamaGenerated"
        newScript.Source = "-- Generated by Ollama Code Assistant\n\n" .. code
        newScript.Parent = game:GetService("Workspace")
        Selection:Set({newScript})
        ChangeHistoryService:SetWaypoint("After Ollama CreateScript")
    end)
    if not ok then return false, err end
    return true, scriptType .. " created in Workspace"
end

-- ============================================================
-- THEME HELPERS
-- ============================================================

local function getTheme()
    local t = settings().Studio.Theme
    return {
        bg = t:GetColor(Enum.StudioStyleGuideColor.MainBackground),
        bg2 = t:GetColor(Enum.StudioStyleGuideColor.InputFieldBackground),
        border = t:GetColor(Enum.StudioStyleGuideColor.Border),
        text = t:GetColor(Enum.StudioStyleGuideColor.MainText),
        subtext = t:GetColor(Enum.StudioStyleGuideColor.SubText),
        button = t:GetColor(Enum.StudioStyleGuideColor.Button),
        buttonText = t:GetColor(Enum.StudioStyleGuideColor.ButtonText),
        accent = Color3.fromRGB(0, 122, 255),
        success = Color3.fromRGB(52, 199, 89),
        danger = Color3.fromRGB(255, 59, 48),
        warning = Color3.fromRGB(255, 149, 0),
    }
end

-- ============================================================
-- GUI CONSTRUCTION
-- ============================================================

local pluginGui = nil
local chatMessages = {} -- UI references for chat bubbles

local function buildGUI()
    if pluginGui then
        pluginGui:Destroy()
    end
    chatMessages = {}

    local theme = getTheme()

    -- DockWidget setup
    local widgetInfo = DockWidgetPluginGuiInfo.new(
        Enum.InitialDockState.Right,
        false, -- initial enabled
        false, -- override previous
        340,   -- default width
        600,   -- default height
        260,   -- min width
        400    -- min height
    )

    pluginGui = plugin:CreateDockWidgetPluginGui("OllamaAssistant", widgetInfo)
    pluginGui.Title = PLUGIN_TITLE
    pluginGui.Name = "OllamaAssistantWidget"

    -- ── Root frame ──────────────────────────────────────────
    local root = Instance.new("Frame")
    root.Size = UDim2.fromScale(1, 1)
    root.BackgroundColor3 = theme.bg
    root.BorderSizePixel = 0
    root.Parent = pluginGui

    local rootLayout = Instance.new("UIListLayout")
    rootLayout.FillDirection = Enum.FillDirection.Vertical
    rootLayout.SortOrder = Enum.SortOrder.LayoutOrder
    rootLayout.Padding = UDim.new(0, 0)
    rootLayout.Parent = root

    -- ── Tab bar ─────────────────────────────────────────────
    local tabBar = Instance.new("Frame")
    tabBar.Size = UDim2.new(1, 0, 0, 34)
    tabBar.BackgroundColor3 = theme.bg2
    tabBar.BorderSizePixel = 0
    tabBar.LayoutOrder = 1
    tabBar.Parent = root

    local tabLayout = Instance.new("UIListLayout")
    tabLayout.FillDirection = Enum.FillDirection.Horizontal
    tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
    tabLayout.Parent = tabBar

    local function makeTab(name, order)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0.33, 0, 1, 0)
        btn.BackgroundTransparency = 1
        btn.Text = name
        btn.TextColor3 = theme.subtext
        btn.Font = Enum.Font.SourceSans
        btn.TextSize = 14
        btn.LayoutOrder = order
        btn.Parent = tabBar

        local indicator = Instance.new("Frame")
        indicator.Size = UDim2.new(1, 0, 0, 2)
        indicator.Position = UDim2.new(0, 0, 1, -2)
        indicator.BackgroundColor3 = theme.accent
        indicator.BorderSizePixel = 0
        indicator.Visible = false
        indicator.Parent = btn

        return btn, indicator
    end

    local codeTabBtn, codeIndicator = makeTab("⌨ Code", 1)
    local chatTabBtn, chatIndicator = makeTab("💬 Chat", 2)
    local settingsTabBtn, settingsIndicator = makeTab("⚙ Settings", 3)

    -- ── Content frame ────────────────────────────────────────
    local content = Instance.new("Frame")
    content.Size = UDim2.new(1, 0, 1, -34)
    content.BackgroundColor3 = theme.bg
    content.BorderSizePixel = 0
    content.LayoutOrder = 2
    content.Parent = root

    -- ============================================================
    -- HELPER: make standard UI elements
    -- ============================================================

    local function makePadded(parent, pad)
        local p = Instance.new("UIPadding")
        p.PaddingLeft = UDim.new(0, pad)
        p.PaddingRight = UDim.new(0, pad)
        p.PaddingTop = UDim.new(0, pad)
        p.PaddingBottom = UDim.new(0, pad)
        p.Parent = parent
    end

    local function makeCorner(parent, radius)
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, radius or 6)
        c.Parent = parent
    end

    local function makeLabel(parent, text, size, bold, order)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, 0, 0, size or 18)
        lbl.BackgroundTransparency = 1
        lbl.Text = text
        lbl.TextColor3 = theme.text
        lbl.Font = bold and Enum.Font.SourceSansBold or Enum.Font.SourceSans
        lbl.TextSize = size or 14
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.LayoutOrder = order or 0
        lbl.Parent = parent
        return lbl
    end

    local function makeTextBox(parent, placeholder, multiline, order)
        local box = Instance.new("TextBox")
        box.Size = UDim2.new(1, 0, 0, multiline and 80 or 30)
        box.BackgroundColor3 = theme.bg2
        box.BorderColor3 = theme.border
        box.BorderSizePixel = 1
        box.Text = ""
        box.PlaceholderText = placeholder or ""
        box.PlaceholderColor3 = theme.subtext
        box.TextColor3 = theme.text
        box.Font = Enum.Font.SourceSans
        box.TextSize = 13
        box.ClearTextOnFocus = false
        box.MultiLine = multiline or false
        box.TextWrapped = true
        box.TextXAlignment = Enum.TextXAlignment.Left
        box.TextYAlignment = multiline and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center
        box.LayoutOrder = order or 0
        box.Parent = parent
        makeCorner(box, 4)
        makePadded(box, 6)
        return box
    end

    local function makeButton(parent, text, color, order)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 32)
        btn.BackgroundColor3 = color or theme.accent
        btn.BorderSizePixel = 0
        btn.Text = text
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Font = Enum.Font.SourceSansBold
        btn.TextSize = 14
        btn.LayoutOrder = order or 0
        btn.Parent = parent
        makeCorner(btn, 6)
        return btn
    end

    local function makeScrollFrame(parent, order)
        local scroll = Instance.new("ScrollingFrame")
        scroll.Size = UDim2.new(1, 0, 1, 0)
        scroll.BackgroundTransparency = 1
        scroll.BorderSizePixel = 0
        scroll.ScrollBarThickness = 5
        scroll.ScrollBarImageColor3 = theme.border
        scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroll.LayoutOrder = order or 0
        scroll.Parent = parent
        local layout = Instance.new("UIListLayout")
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Padding = UDim.new(0, 8)
        layout.Parent = scroll
        return scroll, layout
    end

    -- ============================================================
    -- TAB 1: CODE ASSISTANT
    -- ============================================================

    local codePanel = Instance.new("Frame")
    codePanel.Size = UDim2.fromScale(1, 1)
    codePanel.BackgroundTransparency = 1
    codePanel.Parent = content
    makePadded(codePanel, 10)

    local codePanelLayout = Instance.new("UIListLayout")
    codePanelLayout.SortOrder = Enum.SortOrder.LayoutOrder
    codePanelLayout.Padding = UDim.new(0, 8)
    codePanelLayout.Parent = codePanel

    makeLabel(codePanel, "Describe what to generate:", 13, true, 1)

    local promptBox = makeTextBox(codePanel, "e.g. A door that opens when a player touches it", true, 2)
    promptBox.Size = UDim2.new(1, 0, 0, 90)

    -- Model badge
    local modelBadge = Instance.new("TextLabel")
    modelBadge.Size = UDim2.new(1, 0, 0, 16)
    modelBadge.BackgroundTransparency = 1
    modelBadge.Text = "Model: " .. state.model
    modelBadge.TextColor3 = theme.subtext
    modelBadge.Font = Enum.Font.SourceSans
    modelBadge.TextSize = 11
    modelBadge.TextXAlignment = Enum.TextXAlignment.Left
    modelBadge.LayoutOrder = 3
    modelBadge.Parent = codePanel

    -- Button row
    local codeButtons = Instance.new("Frame")
    codeButtons.Size = UDim2.new(1, 0, 0, 32)
    codeButtons.BackgroundTransparency = 1
    codeButtons.LayoutOrder = 4
    codeButtons.Parent = codePanel

    local genBtn = Instance.new("TextButton")
    genBtn.Size = UDim2.new(0.6, -4, 1, 0)
    genBtn.Position = UDim2.new(0, 0, 0, 0)
    genBtn.BackgroundColor3 = theme.accent
    genBtn.BorderSizePixel = 0
    genBtn.Text = "⚡ Generate"
    genBtn.TextColor3 = Color3.new(1, 1, 1)
    genBtn.Font = Enum.Font.SourceSansBold
    genBtn.TextSize = 14
    genBtn.Parent = codeButtons
    makeCorner(genBtn, 6)

    local explainBtn = Instance.new("TextButton")
    explainBtn.Size = UDim2.new(0.4, -4, 1, 0)
    explainBtn.Position = UDim2.new(0.6, 4, 0, 0)
    explainBtn.BackgroundColor3 = theme.button
    explainBtn.BorderSizePixel = 0
    explainBtn.Text = "🔍 Explain Selection"
    explainBtn.TextColor3 = theme.buttonText
    explainBtn.Font = Enum.Font.SourceSans
    explainBtn.TextSize = 12
    explainBtn.Parent = codeButtons
    makeCorner(explainBtn, 6)

    -- Status label
    local statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1, 0, 0, 14)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = ""
    statusLabel.TextColor3 = theme.subtext
    statusLabel.Font = Enum.Font.SourceSans
    statusLabel.TextSize = 12
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.LayoutOrder = 5
    statusLabel.Parent = codePanel

    makeLabel(codePanel, "Generated Code:", 13, true, 6)

    local outputBox = makeTextBox(codePanel, "Your generated code will appear here...", true, 7)
    outputBox.Size = UDim2.new(1, 0, 0, 160)
    outputBox.Font = Enum.Font.Code
    outputBox.TextSize = 12
    outputBox.TextColor3 = Color3.fromRGB(200, 230, 200)

    -- Insert options
    makeLabel(codePanel, "Insert Options:", 13, true, 8)

    local insertRow1 = Instance.new("Frame")
    insertRow1.Size = UDim2.new(1, 0, 0, 30)
    insertRow1.BackgroundTransparency = 1
    insertRow1.LayoutOrder = 9
    insertRow1.Parent = codePanel

    local insertSelBtn = Instance.new("TextButton")
    insertSelBtn.Size = UDim2.new(0.5, -3, 1, 0)
    insertSelBtn.Position = UDim2.new(0, 0, 0, 0)
    insertSelBtn.BackgroundColor3 = theme.success
    insertSelBtn.BorderSizePixel = 0
    insertSelBtn.Text = "→ Selected Script"
    insertSelBtn.TextColor3 = Color3.new(1, 1, 1)
    insertSelBtn.Font = Enum.Font.SourceSansBold
    insertSelBtn.TextSize = 12
    insertSelBtn.Parent = insertRow1
    makeCorner(insertSelBtn, 6)

    local newScriptBtn = Instance.new("TextButton")
    newScriptBtn.Size = UDim2.new(0.25, -3, 1, 0)
    newScriptBtn.Position = UDim2.new(0.5, 3, 0, 0)
    newScriptBtn.BackgroundColor3 = theme.warning
    newScriptBtn.BorderSizePixel = 0
    newScriptBtn.Text = "+ Script"
    newScriptBtn.TextColor3 = Color3.new(1, 1, 1)
    newScriptBtn.Font = Enum.Font.SourceSansBold
    newScriptBtn.TextSize = 11
    newScriptBtn.Parent = insertRow1
    makeCorner(newScriptBtn, 6)

    local newLocalBtn = Instance.new("TextButton")
    newLocalBtn.Size = UDim2.new(0.25, -3, 1, 0)
    newLocalBtn.Position = UDim2.new(0.75, 3, 0, 0)
    newLocalBtn.BackgroundColor3 = theme.warning
    newLocalBtn.BorderSizePixel = 0
    newLocalBtn.Text = "+ Local"
    newLocalBtn.TextColor3 = Color3.new(1, 1, 1)
    newLocalBtn.Font = Enum.Font.SourceSansBold
    newLocalBtn.TextSize = 11
    newLocalBtn.Parent = insertRow1
    makeCorner(newLocalBtn, 6)

    -- Open in editor button
    local openEditorBtn = makeButton(codePanel, "📝 Open in Script Editor", theme.button, 10)
    openEditorBtn.TextColor3 = theme.buttonText

    -- ============================================================
    -- TAB 2: CHAT
    -- ============================================================

    local chatPanel = Instance.new("Frame")
    chatPanel.Size = UDim2.fromScale(1, 1)
    chatPanel.BackgroundTransparency = 1
    chatPanel.Visible = false
    chatPanel.Parent = content

    -- Chat display area (takes up most space)
    local chatArea = Instance.new("Frame")
    chatArea.Size = UDim2.new(1, 0, 1, -90)
    chatArea.BackgroundColor3 = theme.bg2
    chatArea.BorderSizePixel = 0
    chatArea.Parent = chatPanel

    local chatScroll = Instance.new("ScrollingFrame")
    chatScroll.Size = UDim2.fromScale(1, 1)
    chatScroll.BackgroundTransparency = 1
    chatScroll.BorderSizePixel = 0
    chatScroll.ScrollBarThickness = 5
    chatScroll.ScrollBarImageColor3 = theme.border
    chatScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    chatScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    chatScroll.Parent = chatArea
    makePadded(chatScroll, 8)

    local chatLayout = Instance.new("UIListLayout")
    chatLayout.SortOrder = Enum.SortOrder.LayoutOrder
    chatLayout.Padding = UDim.new(0, 8)
    chatLayout.Parent = chatScroll

    -- Welcome message
    local welcomeLabel = Instance.new("TextLabel")
    welcomeLabel.Size = UDim2.new(1, 0, 0, 40)
    welcomeLabel.BackgroundTransparency = 1
    welcomeLabel.Text = "Ask anything about Roblox scripting. Use Code tab to generate full scripts."
    welcomeLabel.TextColor3 = theme.subtext
    welcomeLabel.Font = Enum.Font.SourceSans
    welcomeLabel.TextSize = 13
    welcomeLabel.TextWrapped = true
    welcomeLabel.TextXAlignment = Enum.TextXAlignment.Center
    welcomeLabel.TextYAlignment = Enum.TextYAlignment.Center
    welcomeLabel.LayoutOrder = 0
    welcomeLabel.Parent = chatScroll

    -- Input row
    local chatInputArea = Instance.new("Frame")
    chatInputArea.Size = UDim2.new(1, 0, 0, 90)
    chatInputArea.Position = UDim2.new(0, 0, 1, -90)
    chatInputArea.BackgroundColor3 = theme.bg
    chatInputArea.BorderColor3 = theme.border
    chatInputArea.BorderSizePixel = 1
    chatInputArea.Parent = chatPanel
    makePadded(chatInputArea, 8)

    local chatInputLayout = Instance.new("UIListLayout")
    chatInputLayout.SortOrder = Enum.SortOrder.LayoutOrder
    chatInputLayout.Padding = UDim.new(0, 6)
    chatInputLayout.Parent = chatInputArea

    local chatBox = makeTextBox(chatInputArea, "Ask a Roblox scripting question...", true, 1)
    chatBox.Size = UDim2.new(1, 0, 0, 50)

    local chatSendBtn = makeButton(chatInputArea, "Send →", theme.accent, 2)
    chatSendBtn.Size = UDim2.new(1, 0, 0, 26)

    -- ============================================================
    -- TAB 3: SETTINGS
    -- ============================================================

    local settingsPanel = Instance.new("Frame")
    settingsPanel.Size = UDim2.fromScale(1, 1)
    settingsPanel.BackgroundTransparency = 1
    settingsPanel.Visible = false
    settingsPanel.Parent = content
    makePadded(settingsPanel, 12)

    local settingsLayout = Instance.new("UIListLayout")
    settingsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    settingsLayout.Padding = UDim.new(0, 10)
    settingsLayout.Parent = settingsPanel

    makeLabel(settingsPanel, "Ollama Code Assistant v" .. VERSION, 15, true, 0)

    -- Connection section
    local connSep = Instance.new("Frame")
    connSep.Size = UDim2.new(1, 0, 0, 1)
    connSep.BackgroundColor3 = theme.border
    connSep.BorderSizePixel = 0
    connSep.LayoutOrder = 1
    connSep.Parent = settingsPanel

    makeLabel(settingsPanel, "Proxy URL (default: http://localhost:3000)", 12, false, 2)
    local proxyInput = makeTextBox(settingsPanel, "http://localhost:3000", false, 3)
    proxyInput.Size = UDim2.new(1, 0, 0, 28)
    proxyInput.Text = state.proxyUrl

    makeLabel(settingsPanel, "Ollama Model", 12, false, 4)
    local modelInput = makeTextBox(settingsPanel, "codellama:7b", false, 5)
    modelInput.Size = UDim2.new(1, 0, 0, 28)
    modelInput.Text = state.model

    -- Common models hint
    local hintLabel = Instance.new("TextLabel")
    hintLabel.Size = UDim2.new(1, 0, 0, 50)
    hintLabel.BackgroundTransparency = 1
    hintLabel.Text = "Common models: codellama:7b, codellama:13b,\nllama3:8b, mistral:7b, deepseek-coder:6.7b"
    hintLabel.TextColor3 = theme.subtext
    hintLabel.Font = Enum.Font.SourceSans
    hintLabel.TextSize = 12
    hintLabel.TextWrapped = true
    hintLabel.TextXAlignment = Enum.TextXAlignment.Left
    hintLabel.LayoutOrder = 6
    hintLabel.Parent = settingsPanel

    local saveBtn = makeButton(settingsPanel, "💾 Save Settings", theme.accent, 7)

    local connStatusLabel = Instance.new("TextLabel")
    connStatusLabel.Size = UDim2.new(1, 0, 0, 20)
    connStatusLabel.BackgroundTransparency = 1
    connStatusLabel.Text = ""
    connStatusLabel.TextColor3 = theme.subtext
    connStatusLabel.Font = Enum.Font.SourceSans
    connStatusLabel.TextSize = 12
    connStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
    connStatusLabel.LayoutOrder = 8
    connStatusLabel.Parent = settingsPanel

    local testBtn = makeButton(settingsPanel, "🔌 Test Connection", theme.button, 9)
    testBtn.TextColor3 = theme.buttonText

    -- Instructions
    local instructionSep = Instance.new("Frame")
    instructionSep.Size = UDim2.new(1, 0, 0, 1)
    instructionSep.BackgroundColor3 = theme.border
    instructionSep.BorderSizePixel = 0
    instructionSep.LayoutOrder = 10
    instructionSep.Parent = settingsPanel

    local instructLabel = Instance.new("TextLabel")
    instructLabel.Size = UDim2.new(1, 0, 0, 120)
    instructLabel.BackgroundTransparency = 1
    instructLabel.Text = "SETUP INSTRUCTIONS:\n1. Install Node.js (nodejs.org)\n2. Run: node proxy.js  in terminal\n3. Start Ollama: ollama serve\n4. Pull a model: ollama pull codellama:7b\n5. Enable HTTP in Studio:\n   File → Game Settings → Security\n   → Allow HTTP Requests"
    instructLabel.TextColor3 = theme.subtext
    instructLabel.Font = Enum.Font.SourceSans
    instructLabel.TextSize = 12
    instructLabel.TextWrapped = true
    instructLabel.TextXAlignment = Enum.TextXAlignment.Left
    instructLabel.TextYAlignment = Enum.TextYAlignment.Top
    instructLabel.LayoutOrder = 11
    instructLabel.Parent = settingsPanel

    -- ============================================================
    -- TAB SWITCHING LOGIC
    -- ============================================================

    local function switchTab(activePanel, activeBtn, activeIndicator)
        for _, p in ipairs({codePanel, chatPanel, settingsPanel}) do
            p.Visible = p == activePanel
        end
        for _, b in ipairs({
            {codeTabBtn, codeIndicator},
            {chatTabBtn, chatIndicator},
            {settingsTabBtn, settingsIndicator},
        }) do
            b[1].TextColor3 = (b[1] == activeBtn) and theme.text or theme.subtext
            b[2].Visible = b[1] == activeBtn
        end
    end

    switchTab(codePanel, codeTabBtn, codeIndicator) -- default

    codeTabBtn.MouseButton1Click:Connect(function()
        switchTab(codePanel, codeTabBtn, codeIndicator)
    end)
    chatTabBtn.MouseButton1Click:Connect(function()
        switchTab(chatPanel, chatTabBtn, chatIndicator)
    end)
    settingsTabBtn.MouseButton1Click:Connect(function()
        switchTab(settingsPanel, settingsTabBtn, settingsIndicator)
    end)

    -- ============================================================
    -- CHAT BUBBLE RENDERING
    -- ============================================================

    local chatMessageCount = 0

    local function addChatBubble(sender, text, isUser)
        welcomeLabel.Visible = false
        chatMessageCount += 1

        local bubble = Instance.new("Frame")
        bubble.Size = UDim2.new(1, 0, 0, 10)
        bubble.BackgroundColor3 = isUser and theme.accent or theme.bg2
        bubble.BorderSizePixel = 0
        bubble.AutomaticSize = Enum.AutomaticSize.Y
        bubble.LayoutOrder = chatMessageCount
        bubble.Parent = chatScroll
        makeCorner(bubble, 8)
        makePadded(bubble, 8)

        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, 0, 0, 14)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = sender
        nameLabel.TextColor3 = isUser and Color3.new(1,1,1) or theme.accent
        nameLabel.Font = Enum.Font.SourceSansBold
        nameLabel.TextSize = 11
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.Parent = bubble

        local msgLabel = Instance.new("TextLabel")
        msgLabel.Size = UDim2.new(1, 0, 0, 10)
        msgLabel.AutomaticSize = Enum.AutomaticSize.Y
        msgLabel.BackgroundTransparency = 1
        msgLabel.Text = text
        msgLabel.TextColor3 = isUser and Color3.new(1,1,1) or theme.text
        msgLabel.Font = Enum.Font.SourceSans
        msgLabel.TextSize = 13
        msgLabel.TextWrapped = true
        msgLabel.TextXAlignment = Enum.TextXAlignment.Left
        msgLabel.TextYAlignment = Enum.TextYAlignment.Top
        msgLabel.Parent = bubble

        local bubbleLayout = Instance.new("UIListLayout")
        bubbleLayout.SortOrder = Enum.SortOrder.LayoutOrder
        bubbleLayout.Padding = UDim.new(0, 4)
        bubbleLayout.Parent = bubble

        nameLabel.LayoutOrder = 1
        msgLabel.LayoutOrder = 2

        -- scroll to bottom
        task.defer(function()
            chatScroll.CanvasPosition = Vector2.new(0, math.huge)
        end)

        return msgLabel
    end

    local function setStreamingText(label, text)
        if label and label.Parent then
            label.Text = text
        end
    end

    -- ============================================================
    -- BUTTON LOGIC: CODE TAB
    -- ============================================================

    local function setStatus(msg, color)
        statusLabel.Text = msg
        statusLabel.TextColor3 = color or theme.subtext
    end

    local function setGenerating(yes)
        if yes then
            genBtn.Text = "⏳ Generating..."
            genBtn.BackgroundColor3 = theme.subtext
        else
            genBtn.Text = "⚡ Generate"
            genBtn.BackgroundColor3 = theme.accent
        end
        genBtn.Active = not yes
        modelBadge.Text = "Model: " .. state.model
    end

    genBtn.MouseButton1Click:Connect(function()
        local prompt = promptBox.Text
        if prompt == "" then
            setStatus("⚠ Enter a description first.", theme.warning)
            return
        end

        setGenerating(true)
        setStatus("Connecting to Ollama...", theme.subtext)
        outputBox.Text = ""

        local systemPrompt = [[You are an expert Roblox Luau scripting assistant embedded in Roblox Studio.
Generate clean, well-commented, production-ready Roblox Luau code.
- Use modern Roblox APIs (task.wait instead of wait, task.spawn instead of spawn, etc.)
- Prefer event-driven patterns over polling loops where possible
- Always use :IsA() for type checking
- Use game:GetService() for all services
- Wrap potentially failing operations in pcall()
- Include brief comments explaining key logic
Return ONLY the Lua code, optionally wrapped in ```lua ... ``` code fences. No explanation outside the code block.]]

        local fullPrompt = "Write a Roblox Luau script for: " .. prompt

        callOllama(fullPrompt, systemPrompt, function(response)
            local code = extractCodeBlock(response)
            outputBox.Text = code
            setGenerating(false)
            setStatus("✓ Code generated! Choose an insert option below.", theme.success)
        end, function(err)
            setGenerating(false)
            setStatus("✗ Error: " .. err, theme.danger)
        end)
    end)

    explainBtn.MouseButton1Click:Connect(function()
        local script = getSelectedScript()
        if not script then
            setStatus("⚠ No script selected in Explorer.", theme.warning)
            return
        end

        local source = script.Source or ""
        if source == "" then
            setStatus("⚠ Selected script is empty.", theme.warning)
            return
        end

        if #source > 3000 then
            source = source:sub(1, 3000) .. "\n-- [truncated]"
        end

        setGenerating(true)
        setStatus("Analyzing " .. script.Name .. "...", theme.subtext)

        local systemPrompt = "You are a Roblox Luau expert. Explain the given script clearly and concisely. List what it does, key functions, and any potential issues."
        local fullPrompt = "Explain this Roblox script:\n```lua\n" .. source .. "\n```"

        callOllama(fullPrompt, systemPrompt, function(response)
            outputBox.Text = response
            setGenerating(false)
            setStatus("✓ Explanation ready.", theme.success)
        end, function(err)
            setGenerating(false)
            setStatus("✗ Error: " .. err, theme.danger)
        end)
    end)

    insertSelBtn.MouseButton1Click:Connect(function()
        local code = outputBox.Text
        if code == "" then
            setStatus("⚠ Generate code first.", theme.warning)
            return
        end
        local ok, msg = insertIntoSelected(code)
        if ok then
            setStatus("✓ " .. msg, theme.success)
            showNotification(PLUGIN_TITLE, msg, 3)
        else
            setStatus("✗ " .. msg, theme.danger)
        end
    end)

    newScriptBtn.MouseButton1Click:Connect(function()
        local code = outputBox.Text
        if code == "" then setStatus("⚠ Generate code first.", theme.warning) return end
        local ok, msg = createNewScript(code, false)
        if ok then setStatus("✓ " .. msg, theme.success) else setStatus("✗ " .. msg, theme.danger) end
    end)

    newLocalBtn.MouseButton1Click:Connect(function()
        local code = outputBox.Text
        if code == "" then setStatus("⚠ Generate code first.", theme.warning) return end
        local ok, msg = createNewScript(code, true)
        if ok then setStatus("✓ " .. msg, theme.success) else setStatus("✗ " .. msg, theme.danger) end
    end)

    openEditorBtn.MouseButton1Click:Connect(function()
        local code = outputBox.Text
        if code == "" then setStatus("⚠ No code to open.", theme.warning) return end
        -- Create a temp script, open it in editor
        local ok, msg = createNewScript(code, false)
        if ok then
            local sel = Selection:Get()
            if #sel > 0 then
                local s = sel[1]
                pcall(function()
                    plugin:OpenScript(s)
                end)
            end
            setStatus("✓ Opened in editor.", theme.success)
        else
            setStatus("✗ " .. msg, theme.danger)
        end
    end)

    -- ============================================================
    -- BUTTON LOGIC: CHAT TAB
    -- ============================================================

    local function sendChatMessage()
        local msg = chatBox.Text
        if msg == "" then return end
        chatBox.Text = ""

        addChatBubble("You", msg, true)

        local typingLabel = addChatBubble("Ollama", "...", false)

        local systemPrompt = [[You are a friendly Roblox Lua/Luau scripting expert. Answer questions about Roblox game development clearly and concisely. When showing code, wrap it in ```lua ... ``` blocks. Be specific and practical.]]

        callOllama(msg, systemPrompt, function(response)
            setStreamingText(typingLabel, response)
        end, function(err)
            setStreamingText(typingLabel, "⚠ Error: " .. err)
        end)
    end

    chatSendBtn.MouseButton1Click:Connect(sendChatMessage)
    chatBox.FocusLost:Connect(function(enter)
        if enter then sendChatMessage() end
    end)

    -- ============================================================
    -- BUTTON LOGIC: SETTINGS TAB
    -- ============================================================

    saveBtn.MouseButton1Click:Connect(function()
        state.proxyUrl = proxyInput.Text
        state.model = modelInput.Text
        saveSettings()
        modelBadge.Text = "Model: " .. state.model
        connStatusLabel.Text = "✓ Settings saved!"
        connStatusLabel.TextColor3 = theme.success
    end)

    testBtn.MouseButton1Click:Connect(function()
        connStatusLabel.Text = "Testing connection..."
        connStatusLabel.TextColor3 = theme.subtext
        testBtn.Text = "Testing..."

        local ok, result = pcall(function()
            return HttpService:RequestAsync({
                Url = state.proxyUrl .. "/health",
                Method = "GET",
            })
        end)

        testBtn.Text = "🔌 Test Connection"

        if not ok then
            connStatusLabel.Text = "✗ Cannot reach proxy: " .. tostring(result)
            connStatusLabel.TextColor3 = theme.danger
        elseif result.Success then
            local data = pcall(function() return HttpService:JSONDecode(result.Body) end)
            connStatusLabel.Text = "✓ Connected! Proxy and Ollama are running."
            connStatusLabel.TextColor3 = theme.success
        else
            connStatusLabel.Text = "✗ Proxy error: HTTP " .. result.StatusCode
            connStatusLabel.TextColor3 = theme.danger
        end
    end)

    return pluginGui
end

-- ============================================================
-- TOOLBAR BUTTON
-- ============================================================

local toolbar = plugin:CreateToolbar(PLUGIN_TITLE)
local toggleBtn = toolbar:CreateButton(
    "Ollama AI",
    "Toggle Ollama Code Assistant",
    "rbxassetid://14978048121" -- code icon
)

toggleBtn.Click:Connect(function()
    if not pluginGui then
        pluginGui = buildGUI()
    end
    pluginGui.Enabled = not pluginGui.Enabled
    toggleBtn:SetActive(pluginGui.Enabled)
end)

-- Also respond to the DockWidget being closed by user
plugin.Unloading:Connect(function()
    if pluginGui then
        pluginGui:Destroy()
    end
end)

print("[Ollama Assistant] Plugin loaded. Click the toolbar button to open.")
