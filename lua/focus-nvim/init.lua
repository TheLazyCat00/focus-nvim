local defaults = require("focus-nvim.defaults")
local state = require("focus-nvim.state")

--- @class FocusNvim
local M = {}

-- namespace for fold diagnostic extmarks
state.ns = state.ns or vim.api.nvim_create_namespace("focusNvimFoldDiagnostics")

-- diagnostics cache per-buffer
state.diagsByBuf = state.diagsByBuf or {}

-- debounce flags per-buffer (avoid re-scanning folds too often)
state.pendingUpdate = state.pendingUpdate or {}

local function normal(cmdStr)
	vim.cmd.normal({ cmdStr, bang = true })
end

local function canParseQuery(lang, queryText)
	return pcall(vim.treesitter.query.parse, lang, queryText)
end

-- Turn a config entry into a valid folds query.
-- Supports:
--   - table of node type strings: { "function_definition", "class_definition" }
--   - string query. If it doesn't include "@fold" but looks like a bracketed list,
--     we append " @fold"
local function normalizeFoldsQuery(lang, spec)
	if type(spec) == "table" then
		-- Filter nodes that don't exist in this language (best-effort fallback)
		local validNodes = {}

		for _, node in ipairs(spec) do
			-- Minimal per-node probe; if node type is invalid, parse errors.
			local probe = ("(%s) @fold"):format(node)
			if canParseQuery(lang, probe) then
				table.insert(validNodes, node)
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
		if not spec:find("@fold") then
			-- legacy: "[ (node) (node) ]" (no captures)
			if spec:match("%[") and spec:match("%]") and not spec:match("@[%w%._-]+") then
				spec = spec .. " @fold\n(#trim! @fold)"
			end
		end

		-- Validate full query for this language; if invalid, skip
		if not canParseQuery(lang, spec) then
			return nil
		end

		return spec
	end

	return nil
end

-- Install/override folds query for the current buffer filetype.
state.invalidQueryNotified = state.invalidQueryNotified or {}

local function applyFoldsQueryForFt(ft)
	local lang = vim.treesitter.language.get_lang(ft)
	if not lang then return end

	local spec = (state.config.languages and state.config.languages[ft])
	if not spec then
		spec = state.config.fallback
	end
	if not spec then return end

	local q = normalizeFoldsQuery(lang, spec)
	if not q then
		-- best-effort: invalid for this lang, so do nothing (keep runtime folds)
		if not state.invalidQueryNotified[ft] then
			state.invalidQueryNotified[ft] = true
			vim.notify(
				("focus-nvim: skipping folds override for ft=%s (lang=%s); query invalid or no valid nodes"):format(ft, lang),
				vim.log.levels.DEBUG
			)
		end
		return
	end

	if not q:find("@fold") then
		vim.notify(
			("focus-nvim: folds query for ft=%s must capture @fold"):format(ft),
			vim.log.levels.WARN
		)
		return
	end

	vim.treesitter.query.set(lang, "folds", q)
end

local function enableBuiltinTsFolding(winid)
	-- global options first (not window-scoped)
	local f = state.config.fold or {}
	if f.levelStart ~= nil then vim.o.foldlevelstart = f.levelStart end
	if f.open ~= nil then vim.o.foldopen = f.open end
	if f.close ~= nil then vim.o.foldclose = f.close end

	-- window-local options
	vim.api.nvim_win_call(winid, function()
		vim.wo.foldmethod = "expr"
		vim.wo.foldexpr   = "v:lua.vim.treesitter.foldexpr()"
		vim.wo.foldenable  = true
		if f.level ~= nil then vim.wo.foldlevel = f.level end
	end)
end

local function recomputeFolds(winid)
	-- Many configs need a delayed zx so TS has built a tree at startup.
	vim.api.nvim_win_call(winid, function()
		vim.cmd("silent! normal! zx")

		local f = state.config.fold or {}
		if f.startClosed then
			vim.cmd("silent! normal! zM")
			vim.cmd("silent! normal! zv")
		end
	end)
end

-- Build prefix sums for quick diag counts per line range.
local function buildDiagPrefix(bufnr, totalLines)
	local diags = state.diagsByBuf[bufnr] or vim.diagnostic.get(bufnr)

	local function zeros(n)
		local t = {}
		t[0] = 0
		for i = 1, n do t[i] = 0 end
		return t
	end

	local err  = zeros(totalLines)
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
		err[i]  = err[i]  + err[i - 1]
		warn[i] = warn[i] + warn[i - 1]
		info[i] = info[i] + info[i - 1]
		hint[i] = hint[i] + hint[i - 1]
	end

	local function count(pref, s, e)
		if s < 1 then s = 1 end
		if e > totalLines then e = totalLines end
		return pref[e] - pref[s - 1]
	end

	return function(s, e)
		return count(err, s, e), count(warn, s, e), count(info, s, e), count(hint, s, e)
	end
end

-- Scan closed folds and render fold diagnostics (virt text + sign) at fold start line.
local function updateFoldDiagnostics(bufnr)
	if not (state.config.diagnostics and state.config.diagnostics.enabled) then
		return
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then return end

	vim.api.nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)

	local totalLines = vim.api.nvim_buf_line_count(bufnr)
	local rangeCounts = buildDiagPrefix(bufnr, totalLines)

	local cfg       = vim.diagnostic.config() or {}
	local signs     = cfg.signs or {}
	local signTexts = signs.text or {}

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
				signHl   = "DiagnosticSignError"
			elseif w > 0 then
				signText = signTexts[severity.WARN]
				signHl   = "DiagnosticSignWarn"
			elseif inf > 0 then
				signText = signTexts[severity.INFO]
				signHl   = "DiagnosticSignInfo"
			elseif h > 0 then
				signText = signTexts[severity.HINT]
				signHl   = "DiagnosticSignHint"
			end

			-- inline virtual text with your callback
			vim.api.nvim_buf_set_extmark(bufnr, state.ns, foldStart - 1, -1, {
				virt_text = {
					{ state.config.diagnostics.callback(e, w, inf, h), state.config.diagnostics.hlGroup },
				},
				virt_text_pos = "inline",
			})

			-- optional sign in signcolumn
			if signText and signHl then
				vim.api.nvim_buf_set_extmark(bufnr, state.ns, foldStart - 1, 0, {
					sign_text     = signText,
					sign_hl_group = signHl,
				})
			end

			i = foldEnd + 1
		end
	end
end

local function scheduleDiagUpdate(bufnr)
	if state.pendingUpdate[bufnr] then return end
	state.pendingUpdate[bufnr] = true

	local ms = (state.config.diagnostics and state.config.diagnostics.debounceMs) or 80
	vim.defer_fn(function()
		state.pendingUpdate[bufnr] = nil
		updateFoldDiagnostics(bufnr)
	end, ms)
end

-- Public helper: if on a fold, open it; otherwise perform normalAction.
function M.open(normalAction)
	local isOnFold = vim.fn.foldclosed(".") ~= -1 ---@diagnostic disable-line: param-type-mismatch
	local action = isOnFold and "zo" or normalAction
	pcall(normal, action)
end

function M.setup(opts)
	state.config = vim.tbl_deep_extend("force", defaults, opts or {})

	local aug = vim.api.nvim_create_augroup("FocusNvim", { clear = true })

	-- 1) Apply folds query + folding options when filetype is known
	vim.api.nvim_create_autocmd({ "FileType" }, {
		group = aug,
		callback = function(ev)
			local bufnr = ev.buf
			local winid = vim.api.nvim_get_current_win()
			local ft    = vim.bo[bufnr].filetype

			-- only enable if TS parser exists
			if not pcall(vim.treesitter.get_parser, bufnr) then return end

			applyFoldsQueryForFt(ft)
			enableBuiltinTsFolding(winid)

			vim.schedule(function()
				if vim.api.nvim_win_is_valid(winid) then
					recomputeFolds(winid)
					scheduleDiagUpdate(bufnr)
				end
			end)
		end,
	})

	-- 2) Update cached diagnostics + refresh fold diagnostic decorations
	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		group = aug,
		callback = function(ev)
			state.diagsByBuf[ev.buf] = (ev.data and ev.data.diagnostics) or vim.diagnostic.get(ev.buf)
			scheduleDiagUpdate(ev.buf)
		end,
	})

	-- 3) When folds open/close due to movement, redraw fold diagnostics (debounced)
	vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
		group = aug,
		callback = function(ev)
			scheduleDiagUpdate(ev.buf)
		end,
	})

	-- 4) If text changes, force fold recompute (optional but helps TS-fold correctness)
	vim.api.nvim_create_autocmd({ "BufWritePost", "InsertLeave" }, {
		group = aug,
		callback = function(ev)
			local winid = vim.api.nvim_get_current_win()
			vim.schedule(function()
				if vim.api.nvim_win_is_valid(winid) then
					recomputeFolds(winid)
					scheduleDiagUpdate(ev.buf)
				end
			end)
		end,
	})
end

return M
