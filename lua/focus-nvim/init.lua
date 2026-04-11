local defaults = require("focus-nvim.defaults")
local state = require("focus-nvim.state")

--- @class FocusNvim
local M = {}

---@param cmdStr string
local function normal(cmdStr)
	vim.cmd.normal({ cmdStr, bang = true })
end

---@return integer ns
local function ensureNamespace()
	if state.ns then
		return state.ns
	end
	state.ns = vim.api.nvim_create_namespace("focusNvimFoldDiagnostics")
	return state.ns
end

---@param bufnr integer
---@return integer[] winids
local function windowsForBuf(bufnr)
	local wins = vim.fn.win_findbuf(bufnr)
	if type(wins) ~= "table" then
		return {}
	end
	return wins
end

-- Register a predicate that filters out nodes that are (or contain) Tree-sitter parse errors.
-- This avoids folding "broken" syntax while you are actively editing.
local function registerPredicates()
	if state.predicatesRegistered then
		return
	end
	state.predicatesRegistered = true

	local ok = pcall(vim.treesitter.query.add_predicate, "focus-nvim-no-error?", function(match, _, _, predicate, _)
		local captureId = predicate[2]
		local nodes = match[captureId]

		if nodes == nil then
			return true
		end

		-- match[captureId] is usually a list of nodes
		if nodes.id ~= nil then
			nodes = { nodes }
		end

		for _, node in ipairs(nodes) do
			-- has_error() is true if the node is an error node OR contains one
			-- missing() catches recovery nodes
			if node:has_error() or node:missing() then
				return false
			end
		end

		return true
	end, { force = true })

	-- Older Neovim versions / LuaLS stubs might not accept { force = true }
	if not ok then
		pcall(vim.treesitter.query.add_predicate, "focus-nvim-no-error?", function(match, _, _, predicate, _)
			local captureId = predicate[2]
			local nodes = match[captureId]
			if nodes == nil then
				return true
			end
			if nodes.id ~= nil then
				nodes = { nodes }
			end
			for _, node in ipairs(nodes) do
				if node:has_error() or node:missing() then
					return false
				end
			end
			return true
		end)
	end
end

---@param lang string
---@param queryText string
---@return boolean ok
local function canParseQuery(lang, queryText)
	return pcall(vim.treesitter.query.parse, lang, queryText)
end

---@param lang string
---@param spec any
---@return string? queryText
local function normalizeFoldsQuery(lang, spec)
	registerPredicates()

	if type(spec) == "table" then
		---@type string[]
		local validNodes = {}

		for _, node in ipairs(spec) do
			if type(node) == "string" then
				local probe = ("(%s) @fold"):format(node)
				if canParseQuery(lang, probe) then
					table.insert(validNodes, node)
				end
			end
		end

		if #validNodes == 0 then
			return nil
		end

		-- Single pattern with directives inside it (safe + standard query style)
		local out = { "(" }
		table.insert(out, "\t[")
		for _, node in ipairs(validNodes) do
			table.insert(out, ("\t\t(%s)"):format(node))
		end
		table.insert(out, "\t] @fold")
		table.insert(out, "\t(#trim! @fold)")
		table.insert(out, "\t(#focus-nvim-no-error? @fold)")
		table.insert(out, ")")

		return table.concat(out, "\n")
	end

	if type(spec) == "string" then
		local q = spec

		-- legacy: "[ (node) (node) ]" (no captures) -> convert to @fold pattern
		if not q:find("@fold") then
			if q:match("%[") and q:match("%]") and not q:match("@[%w%._-]+") then
				-- Wrap it so we can attach directives safely
				q = table.concat({
					"(",
					q .. " @fold",
					"\t(#trim! @fold)",
					"\t(#focus-nvim-no-error? @fold)",
					")",
				}, "\n")
			end
		end

		-- If user provides a raw query string with @fold, we validate it as-is.
		-- Note: we do NOT attempt to inject our predicate into arbitrary query strings,
		-- because doing it correctly requires rewriting each pattern.
		if not q:find("@fold") then
			return nil
		end

		if not canParseQuery(lang, q) then
			return nil
		end

		return q
	end

	return nil
end

---@param ft string
local function applyFoldsQueryForFt(ft)
	local lang = vim.treesitter.language.get_lang(ft)
	if not lang then
		return
	end

	local cfg = state.config
	local spec = cfg.languages[ft] or cfg.fallback

	-- Always override folds query:
	-- If nothing validates for this language => "", so runtime folds.scm never applies for this lang.
	local q = normalizeFoldsQuery(lang, spec)
	vim.treesitter.query.set(lang, "folds", q or "")
end

local function applyGlobalFoldOptions()
	local f = state.config.fold
	vim.o.foldlevelstart = f.levelStart
	vim.o.foldopen = f.open
	vim.o.foldclose = f.close
end

---@param winid integer
local function enableBuiltinTsFolding(winid)
	local f = state.config.fold

	vim.api.nvim_win_call(winid, function()
		vim.wo.foldmethod = "expr"
		vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
		vim.wo.foldenable = true
		vim.wo.foldlevel = f.level
	end)
end

---@param bufnr integer
---@return FocusDiagPrefix
local function rebuildDiagPrefix(bufnr)
	local lineCount = vim.api.nvim_buf_line_count(bufnr)
	local diags = state.diagsByBuf[bufnr] or vim.diagnostic.get(bufnr)

	local function zeros(n)
		local t = {}
		t[0] = 0
		for i = 1, n do
			t[i] = 0
		end
		return t
	end

	local err = zeros(lineCount)
	local warn = zeros(lineCount)
	local info = zeros(lineCount)
	local hint = zeros(lineCount)

	for _, d in ipairs(diags) do
		local l = (d.lnum or 0) + 1
		if l >= 1 and l <= lineCount then
			if d.severity == vim.diagnostic.severity.ERROR then
				err[l] = err[l] + 1
			elseif d.severity == vim.diagnostic.severity.WARN then
				warn[l] = warn[l] + 1
			elseif d.severity == vim.diagnostic.severity.INFO then
				info[l] = info[l] + 1
			elseif d.severity == vim.diagnostic.severity.HINT then
				hint[l] = hint[l] + 1
			end
		end
	end

	for i = 1, lineCount do
		err[i] = err[i] + err[i - 1]
		warn[i] = warn[i] + warn[i - 1]
		info[i] = info[i] + info[i - 1]
		hint[i] = hint[i] + hint[i - 1]
	end

	---@type FocusDiagPrefix
	local prefix = {
		lineCount = lineCount,
		err = err,
		warn = warn,
		info = info,
		hint = hint,
	}

	state.diagPrefixCache[bufnr] = prefix
	return prefix
end

---@param bufnr integer
---@return fun(s: integer, e: integer): integer, integer, integer, integer
local function getRangeCounts(bufnr)
	local cached = state.diagPrefixCache[bufnr]
	local currentLineCount = vim.api.nvim_buf_line_count(bufnr)

	if not cached or cached.lineCount ~= currentLineCount then
		cached = rebuildDiagPrefix(bufnr)
	end

	local function count(pref, s, e)
		if s < 1 then s = 1 end
		if e > cached.lineCount then e = cached.lineCount end
		if e < s then return 0 end
		return pref[e] - pref[s - 1]
	end

	return function(s, e)
		return count(cached.err, s, e),
			count(cached.warn, s, e),
			count(cached.info, s, e),
			count(cached.hint, s, e)
	end
end

---@param winid integer
---@return integer top, integer bot
local function visibleRange(winid)
	local top = 1
	local bot = 1

	vim.api.nvim_win_call(winid, function()
		top = vim.fn.line("w0")
		bot = vim.fn.line("w$")
	end)

	return top, bot
end

---@param bufnr integer
---@param winid integer
local function updateFoldDiagnostics(bufnr, winid)
	local dcfg = state.config.diagnostics
	if not dcfg.enabled then
		return
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if not (winid and vim.api.nvim_win_is_valid(winid)) then
		return
	end
	if vim.api.nvim_win_get_buf(winid) ~= bufnr then
		return
	end

	local ns = ensureNamespace()
	local top, bot = visibleRange(winid)
	local rangeCounts = getRangeCounts(bufnr)

	vim.api.nvim_win_call(winid, function()
		-- Clear only visible lines (performance).
		vim.api.nvim_buf_clear_namespace(bufnr, ns, math.max(top - 1, 0), bot)

		local globalDiagCfg = vim.diagnostic.config() or {}
		local signs = globalDiagCfg.signs or {}
		local signTexts = (type(signs) == "table" and signs.text) or {}
		if type(signTexts) ~= "table" then
			signTexts = {}
		end

		local severity = vim.diagnostic.severity

		local i = top
		while i <= bot do
			local foldStart = vim.fn.foldclosed(i)
			if foldStart == -1 then
				i = i + 1
			else
				local foldEnd = vim.fn.foldclosedend(i)

				-- Only annotate folds whose start line is visible.
				if foldStart >= top and foldStart <= bot then
					local e, w, inf, h = rangeCounts(foldStart, foldEnd)

					local signText, signHl
					if e > 0 then
						signText = signTexts[severity.ERROR]
						signHl = "DiagnosticSignError"
					elseif w > 0 then
						signText = signTexts[severity.WARN]
						signHl = "DiagnosticSignWarn"
					elseif inf > 0 then
						signText = signTexts[severity.INFO]
						signHl = "DiagnosticSignInfo"
					elseif h > 0 then
						signText = signTexts[severity.HINT]
						signHl = "DiagnosticSignHint"
					end

					local virt = dcfg.callback(e, w, inf, h)
					if virt and virt ~= "" then
						vim.api.nvim_buf_set_extmark(bufnr, ns, foldStart - 1, -1, {
							virt_text = {
								{ virt, dcfg.hlGroup },
							},
							virt_text_pos = "inline",
						})
					end

					if signText and signHl then
						vim.api.nvim_buf_set_extmark(bufnr, ns, foldStart - 1, 0, {
							sign_text = signText,
							sign_hl_group = signHl,
						})
					end
				end

				i = foldEnd + 1
			end
		end
	end)
end

---@param bufnr integer
---@param winid integer
local function scheduleDiagUpdate(bufnr, winid)
	if not (winid and vim.api.nvim_win_is_valid(winid)) then
		return
	end

	local key = ("%d:%d"):format(bufnr, winid)
	if state.pendingUpdate[key] then
		return
	end
	state.pendingUpdate[key] = true

	local ms = state.config.diagnostics.debounceMs

	vim.defer_fn(function()
		state.pendingUpdate[key] = nil
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_win_is_valid(winid) then
			updateFoldDiagnostics(bufnr, winid)
		end
	end, ms)
end

--- If on a closed fold, open it; otherwise perform normalAction.
--- @param normalAction string
function M.open(normalAction)
	local isOnFold = vim.fn.foldclosed(".") ~= -1 ---@diagnostic disable-line: param-type-mismatch
	local action = isOnFold and "zo" or normalAction
	pcall(normal, action)
end

--- @param opts FocusConfig?
function M.setup(opts)
	state.config = vim.tbl_deep_extend("force", defaults, opts or {})
	registerPredicates()
	applyGlobalFoldOptions()

	local aug = vim.api.nvim_create_augroup("FocusNvim", { clear = true })

	---@param bufnr integer
	---@param winid integer
	local function attachToWindow(bufnr, winid)
		if not (vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_win_is_valid(winid)) then
			return
		end
		if not pcall(vim.treesitter.get_parser, bufnr) then
			return
		end

		-- Avoid redoing the expensive parts repeatedly for the same window+buffer
		vim.w[winid].focusNvimAttached = vim.w[winid].focusNvimAttached or {}
		if vim.w[winid].focusNvimAttached[bufnr] then
			scheduleDiagUpdate(bufnr, winid)
			return
		end
		vim.w[winid].focusNvimAttached[bufnr] = true

		local ft = vim.bo[bufnr].filetype
		applyFoldsQueryForFt(ft)
		enableBuiltinTsFolding(winid)
	end

	vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
		group = aug,
		callback = function(ev)
			attachToWindow(ev.buf, vim.api.nvim_get_current_win())
		end,
	})

	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		group = aug,
		callback = function(ev)
			local bufnr = ev.buf
			state.diagsByBuf[bufnr] = (ev.data and ev.data.diagnostics) or vim.diagnostic.get(bufnr)
			rebuildDiagPrefix(bufnr)

			for _, winid in ipairs(windowsForBuf(bufnr)) do
				scheduleDiagUpdate(bufnr, winid)
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinScrolled", {
		group = aug,
		callback = function(ev)
			scheduleDiagUpdate(ev.buf, vim.api.nvim_get_current_win())
		end,
	})
end

return M
