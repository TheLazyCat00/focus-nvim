local defaults = require("focus-nvim.defaults")
local state = require("focus-nvim.state")

--- @class FocusNvim
local M = {}

local origHandler = vim.lsp.handlers["textDocument/publishDiagnostics"]

--- Executes a normal mode command with bang.
--- @param cmdStr string The normal mode command to execute
local function normal(cmdStr)
	vim.cmd.normal { cmdStr, bang = true }
end

--- Scans all closed folds in the current buffer and renders diagnostic
--- counts as virtual text and signs on each fold's opening line.
local function updateFoldDiagnostics()
	if not state.diags then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local ns = vim.api.nvim_create_namespace("fold_diagnostics")
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local totalLines = vim.api.nvim_buf_line_count(bufnr)

	local i = 1
	while i <= totalLines do
		local foldStart = vim.fn.foldclosed(i)
		if foldStart == -1 then
			i = i + 1
		else
			local foldEnd = vim.fn.foldclosedend(i)
			local errorCount = 0
			local warnCount = 0
			local infoCount = 0
			local hintCount = 0

			for _, diag in ipairs(state.diags) do
				if diag.lnum >= (foldStart - 1) and diag.lnum <= (foldEnd - 1) then
					if diag.severity == vim.diagnostic.severity.ERROR then
						errorCount = errorCount + 1
					elseif diag.severity == vim.diagnostic.severity.WARN then
						warnCount = warnCount + 1
					elseif diag.severity == vim.diagnostic.severity.INFO then
						infoCount = infoCount + 1
					elseif diag.severity == vim.diagnostic.severity.HINT then
						hintCount = hintCount + 1
					end
				end
			end

			local severity = vim.diagnostic.severity
			local virtConfig = vim.diagnostic.config().signs.text or {}
			--- @type string
			local virtText = ""
			--- @type string | nil
			local hl = nil

			if errorCount > 0 then
				virtText = virtConfig[severity.ERROR]
				hl = "DiagnosticError"
			elseif warnCount > 0 then
				virtText = virtConfig[severity.WARN]
				hl = "DiagnosticWarn"
			elseif infoCount > 0 then
				virtText = virtConfig[severity.INFO]
				hl = "DiagnosticInfo"
			elseif hintCount > 0 then
				virtText = virtConfig[severity.HINT]
				hl = "DiagnosticHint"
			end

			vim.api.nvim_buf_set_extmark(bufnr, ns, foldStart - 1, -1, {
				virt_text = { { state.config.callback(errorCount, warnCount, infoCount, hintCount), state.config.hlGroup } },
				virt_text_pos = "inline",
			})
			vim.api.nvim_buf_set_extmark(bufnr, ns, foldStart - 1, 0, {
				sign_text = virtText,
				sign_hl_group = hl,
			})

			i = foldEnd + 1
		end
	end
end

--- Returns the treesitter query string for the current buffer's filetype.
--- @param ft string The filetype to look up
--- @return string queryStr The query string to use
local function getQueryStr(ft)
	if state.config.languages[ft] then
		return state.config.languages[ft]
	end
	return state.config.fallback
end

--- Returns a fresh treesitter parser and parsed query for the given buffer,
--- or nil if either step fails.
--- @param buf integer The buffer to parse
--- @param ft string The filetype of the buffer
--- @return vim.treesitter.LanguageTree | nil parser
--- @return vim.treesitter.Query | nil query
local function getParserAndQuery(buf, ft)
	local parser_name = vim.treesitter.language.get_lang(ft)
	local status, parser = pcall(vim.treesitter.get_parser, buf, parser_name)
	if not status then return nil, nil end
	parser:invalidate()

	local queryStr = getQueryStr(ft)
	local ok, query = pcall(vim.treesitter.query.parse, parser_name, queryStr)
	if not ok then return nil, nil end

	return parser, query
end

--- Resets all folds in the current buffer by re-running the treesitter query
--- and folding every matched node. Also refreshes fold diagnostics.
function M.reset()
	vim.opt.foldmethod = "manual"
	vim.cmd("normal! zR")
	local buf = vim.api.nvim_get_current_buf()

	local parser, query = getParserAndQuery(buf, vim.bo.filetype)
	if not parser or not query then return end

	local tree = parser:parse()[1]
	local root = tree:root()

	for _, node, _ in query:iter_captures(root, buf, 0, -1) do
		local startRow, _, endRow, _ = node:range()
		pcall(vim.cmd, string.format("%d,%dfold", startRow + 1, endRow + 1))
	end

	updateFoldDiagnostics()
end

--- Folds the treesitter node that was previously under the cursor (i.e. the
--- node at `state.lastLine`), unless the cursor is still inside it.
--- Called on every `CursorMoved` event in normal mode.
function M.foldAround()
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local line = vim.api.nvim_win_get_cursor(win)[1] -- 1-indexed

	if not state.lastLine then
		state.lastLine = line
		return
	end

	local parser, query = getParserAndQuery(buf, vim.bo.filetype)
	if not parser or not query then return end

	local tree = parser:parse()[1]
	local root = tree:root()

	for _, node, _ in query:iter_captures(root, buf, state.lastLine - 1, state.lastLine) do
		local startRow, _, endRow, _ = node:range()
		if startRow < line and line < endRow + 2 then
			goto continue
		end

		if vim.fn.foldclosed(startRow + 1) == -1 then
			pcall(vim.cmd, string.format("%d,%dfold", startRow + 1, endRow + 1))
		end
		::continue::
	end

	state.lastLine = line
	updateFoldDiagnostics()
end

--- @param normalAction string The normal mode command to fall back to when not on a fold
function M.open(normalAction)
	local isOnFold = vim.fn.foldclosed(".") ~= -1 ---@diagnostic disable-line: param-type-mismatch
	local action = isOnFold and "zo" or normalAction

	pcall(normal, action)
end

--- Sets up the plugin with user-provided options, merged over the defaults.
--- @param opts FocusConfig Partial or full config to override defaults
function M.setup(opts)
	state.config = vim.tbl_extend("force", defaults, opts)
end

-- Override the LSP publishDiagnostics handler to keep state.diags up to date.
vim.lsp.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config1)
	origHandler(err, result, ctx, config1)

	local bufnr = vim.api.nvim_get_current_buf()
	state.diags = vim.diagnostic.get(bufnr)
end

vim.api.nvim_create_autocmd("BufEnter", {
	callback = function()
		local bufnr = vim.api.nvim_get_current_buf()
		state.diags = vim.diagnostic.get(bufnr)
		state.lastContent[bufnr] = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		vim.schedule(M.reset)
	end,
})

vim.api.nvim_create_autocmd("TextChanged", {
	-- Deferred 100ms to avoid interrupting bulk operations like pasting.
	callback = function()
		vim.defer_fn(function()
			local bufnr = vim.api.nvim_get_current_buf()
			local win = vim.api.nvim_get_current_win()
			local cursor = vim.api.nvim_win_get_cursor(win)
			local currentLine = cursor[1]
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

			local shouldReset = false
			if state.lastContent[bufnr] then
				local startLine = math.max(1, currentLine - state.config.areaSearch)
				local endLine = math.min(#lines, currentLine + state.config.areaSearch)

				for i = startLine, endLine do
					if i ~= currentLine and state.lastContent[bufnr][i] ~= lines[i] then
						shouldReset = true
						break
					end
				end

				if not shouldReset then
					for i = 1, #lines, state.config.spreadSearch do
						if i ~= currentLine and state.lastContent[bufnr][i] ~= lines[i] then
							shouldReset = true
							break
						end
					end
				end
			end

			if shouldReset then
				M.reset()
			end

			state.lastContent[bufnr] = lines
		end, 100)
	end,
})

vim.api.nvim_create_autocmd("CursorMoved", {
	callback = function()
		if vim.api.nvim_get_mode().mode == "n" then
			vim.schedule(M.foldAround)
		end
	end,
})

return M
