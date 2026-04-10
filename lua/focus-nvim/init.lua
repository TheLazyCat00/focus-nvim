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
---@return integer? winid
local function pickWindowForBuf(bufnr)
	local wins = vim.fn.win_findbuf(bufnr)
	if type(wins) ~= "table" or #wins == 0 then
		return nil
	end

	local cur = vim.api.nvim_get_current_win()
	for _, w in ipairs(wins) do
		if w == cur then
			return cur
		end
	end

	return wins[1]
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
	if not cfg then
		return
	end

	-- Try ft-specific rules; otherwise fallback.
	local spec = cfg.languages and cfg.languages[ft]
	if spec == nil then
		spec = cfg.fallback
	end

	-- If nothing validates for this language, set folds query to ""
	-- so Neovim runtime folds.scm never applies for this lang.
	local q = nil
	if spec ~= nil then
		q = normalizeFoldsQuery(lang, spec)
	end

	vim.treesitter.query.set(lang, "folds", q or "")
end

local function applyGlobalFoldOptions()
	local cfg = state.config
	if not cfg then
		return
	end

	local f = cfg.fold or {}

	-- These are GLOBAL options in Neovim (do NOT use vim.wo here).
	if f.levelStart ~= nil then
		vim.o.foldlevelstart = f.levelStart
	end
	if f.open ~= nil then
		vim.o.foldopen = f.open
	end
	if f.close ~= nil then
		vim.o.foldclose = f.close
	end
end

---@param winid integer
local function enableBuiltinTsFolding(winid)
	local cfg = state.config
	if not cfg then
		return
	end

	local f = cfg.fold or {}

	vim.api.nvim_win_call(winid, function()
		-- Built-in Tree-sitter folding
		vim.wo.foldmethod = "expr"
		vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
		vim.wo.foldenable = true

		-- Window-local
		if f.level ~= nil then
			vim.wo.foldlevel = f.level
		end
	end)
end

---@param winid integer
local function recomputeFolds(winid)
	vim.api.nvim_win_call(winid, function()
		vim.cmd("silent! normal! zx")

		local cfg = state.config
		local f = (cfg and cfg.fold) or {}
		if f.startClosed then
			vim.cmd("silent! normal! zM")
			vim.cmd("silent! normal! zv")
		end
	end)
end

---@param bufnr integer
---@param totalLines integer
---@return fun(s: integer, e: integer): integer, integer, integer, integer
local function buildDiagPrefix(bufnr, totalLines)
	local diags = state.diagsByBuf[bufnr] or vim.diagnostic.get(bufnr)

	local function zeros(n)
		local t = {}
		t[0] = 0
		for i = 1, n do
			t[i] = 0
		end
		return t
	end

	local err = zeros(totalLines)
	local warn = zeros(totalLines)
	local info = zeros(totalLines)
	local hint = zeros(totalLines)

	for _, d in ipairs(diags) do
		local l = (d.lnum or 0) + 1
		if l >= 1 and l <= totalLines then
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

	for i = 1, totalLines do
		err[i] = err[i] + err[i - 1]
		warn[i] = warn[i] + warn[i - 1]
		info[i] = info[i] + info[i - 1]
		hint[i] = hint[i] + hint[i - 1]
	end

	local function count(pref, s, e)
		if s < 1 then
			s = 1
		end
		if e > totalLines then
			e = totalLines
		end
		return pref[e] - pref[s - 1]
	end

	return function(s, e)
		return count(err, s, e), count(warn, s, e), count(info, s, e), count(hint, s, e)
	end
end

---@param bufnr integer
local function updateFoldDiagnostics(bufnr)
	local cfg = state.config
	if not (cfg and cfg.diagnostics and cfg.diagnostics.enabled) then
		return
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local winid = pickWindowForBuf(bufnr)
	if not winid then
		return
	end

	local ns = ensureNamespace()

	vim.api.nvim_win_call(winid, function()
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

		local totalLines = vim.api.nvim_buf_line_count(bufnr)
		local rangeCounts = buildDiagPrefix(bufnr, totalLines)

		local dcfg = vim.diagnostic.config() or {}
		local signs = dcfg.signs or {}
		local signTexts = (type(signs) == "table" and signs.text) or {}
		if type(signTexts) ~= "table" then
			signTexts = {}
		end

		local severity = vim.diagnostic.severity

		local i = 1
		while i <= totalLines do
			local foldStart = vim.fn.foldclosed(i)
			if foldStart == -1 then
				i = i + 1
			else
				local foldEnd = vim.fn.foldclosedend(i)
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

				local virt = cfg.diagnostics.callback(e, w, inf, h)
				if virt and virt ~= "" then
					vim.api.nvim_buf_set_extmark(bufnr, ns, foldStart - 1, -1, {
						virt_text = {
							{ virt, cfg.diagnostics.hlGroup },
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

				i = foldEnd + 1
			end
		end
	end)
end

---@param bufnr integer
local function scheduleDiagUpdate(bufnr)
	if state.pendingUpdate[bufnr] then
		return
	end
	state.pendingUpdate[bufnr] = true

	local cfg = state.config or defaults
	local ms = (cfg.diagnostics and cfg.diagnostics.debounceMs) or 80

	vim.defer_fn(function()
		state.pendingUpdate[bufnr] = nil
		if vim.api.nvim_buf_is_valid(bufnr) then
			updateFoldDiagnostics(bufnr)
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

	vim.api.nvim_create_autocmd("FileType", {
		group = aug,
		callback = function(ev)
			local bufnr = ev.buf
			local ft = vim.bo[bufnr].filetype
			local winid = pickWindowForBuf(bufnr)
			if not winid then
				return
			end

			if not pcall(vim.treesitter.get_parser, bufnr) then
				return
			end

			-- Always override folds query (possibly to "")
			-- so runtime folds.scm never applies unless you provide a valid spec/fallback.
			applyFoldsQueryForFt(ft)

			enableBuiltinTsFolding(winid)

			vim.schedule(function()
				if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_buf_is_valid(bufnr) then
					recomputeFolds(winid)
					scheduleDiagUpdate(bufnr)
				end
			end)
		end,
	})

	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		group = aug,
		callback = function(ev)
			local bufnr = ev.buf
			state.diagsByBuf[bufnr] = (ev.data and ev.data.diagnostics) or vim.diagnostic.get(ev.buf)
			scheduleDiagUpdate(bufnr)
		end,
	})

	vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
		group = aug,
		callback = function(ev)
			scheduleDiagUpdate(ev.buf)
		end,
	})

	vim.api.nvim_create_autocmd({ "BufWritePost", "InsertLeave" }, {
		group = aug,
		callback = function(ev)
			local bufnr = ev.buf
			local winid = pickWindowForBuf(bufnr)
			if not winid then
				return
			end

			vim.schedule(function()
				if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_buf_is_valid(bufnr) then
					recomputeFolds(winid)
					scheduleDiagUpdate(bufnr)
				end
			end)
		end,
	})
end

return M
