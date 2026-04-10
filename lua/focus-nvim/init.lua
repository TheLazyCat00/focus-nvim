-- lua/focus-nvim/init.lua

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

		local out = { "[" }
		for _, node in ipairs(validNodes) do
			table.insert(out, ("\t(%s)"):format(node))
		end
		table.insert(out, "] @fold")
		table.insert(out, "(#trim! @fold)")
		return table.concat(out, "\n")
	end

	if type(spec) == "string" then
		local q = spec

		if not q:find("@fold") then
			-- legacy: "[ (node) (node) ]" (no captures)
			if q:match("%[") and q:match("%]") and not q:match("@[%w%._-]+") then
				q = q .. " @fold\n(#trim! @fold)"
			end
		end

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
	local spec = (cfg.languages and cfg.languages[ft]) or cfg.fallback

	-- Always override folds query:
	-- If nothing validates for this language => "", so runtime folds.scm never applies for this lang.
	local q = normalizeFoldsQuery(lang, spec)
	vim.treesitter.query.set(lang, "folds", q or "")
end

local function applyGlobalFoldOptions()
	local f = state.config.fold

	-- Global options (do NOT use vim.wo)
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

---@param winid integer
local function recomputeFolds(winid)
	vim.api.nvim_win_call(winid, function()
		vim.cmd("silent! normal! zx")
	end)
end

-- Diagnostic prefix cache (per buffer). Rebuilt on DiagnosticChanged and lazily if line count changes.

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
		-- Clear only visible lines (big win vs clearing entire buffer).
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

		vim.schedule(function()
			if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_buf_is_valid(bufnr) then
				recomputeFolds(winid)
				scheduleDiagUpdate(bufnr, winid)
			end
		end)
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

	vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
		group = aug,
		callback = function(ev)
			scheduleDiagUpdate(ev.buf, vim.api.nvim_get_current_win())
		end,
	})

	vim.api.nvim_create_autocmd({ "BufWritePost", "InsertLeave" }, {
		group = aug,
		callback = function(ev)
			local bufnr = ev.buf
			local winid = vim.api.nvim_get_current_win()

			vim.schedule(function()
				if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_buf_is_valid(bufnr) then
					recomputeFolds(winid)
					scheduleDiagUpdate(bufnr, winid)
				end
			end)
		end,
	})
end

return M
