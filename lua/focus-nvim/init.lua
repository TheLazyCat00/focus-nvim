local defaults = require("focus-nvim.defaults")
local M = {}

local origHandler = vim.lsp.handlers["textDocument/publishDiagnostics"]
local config
local lastLine
local diags

local function updateFoldDiagnostics()
	if not diags then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local ns = vim.api.nvim_create_namespace("fold_diagnostics")
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, - 1)

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

			for _, diag in ipairs(diags) do
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
			local virtText = ""
			local hl = nil

			if errorCount > 0 then
				-- virtText = "" vim.fn.sign_getdefined("Error")[1]
				virtText = virtConfig[severity.ERROR]
				hl = "DiagnosticError"
			elseif warnCount > 0 then
				-- virtText = ""
				virtText = virtConfig[severity.WARN]
				hl = "DiagnosticWarn"
			elseif infoCount > 0 then
				-- virtText = ""
				virtText = virtConfig[severity.INFO]
				hl = "DiagnosticInfo"
			elseif hintCount > 0 then
				-- virtText = ""
				virtText = virtConfig[severity.HINT]
				hl = "DiagnosticHint"
			end

			vim.api.nvim_buf_set_extmark(bufnr, ns, foldStart - 1, - 1, {
				virt_text = { {config.callback(errorCount, warnCount, infoCount, hintCount), config.hlGroup }},
				virt_text_pos = "inline"
			})
			vim.api.nvim_buf_set_extmark(bufnr, ns, foldStart - 1, 0, {
				sign_text = virtText,
				sign_hl_group = hl,
			})

			i = foldEnd + 1
		end
	end
end

function M.foldFunctionsAndMethods()
	local buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo.filetype
	local queryStr

	if config.languages[ft] then
		queryStr = config.languages[ft]
	else
		queryStr = config.fallback
	end

	local status, parser = pcall(vim.treesitter.get_parser, buf, ft)
	if not status then return end

	local tree = parser:parse()[1]
	local root = tree:root()

	local ok, query = pcall(vim.treesitter.query.parse, ft, queryStr)
	if not ok then return end

	for _, node, _ in query:iter_captures(root, buf, 0, - 1) do
		local startRow, _, endRow, _ = node:range()
		vim.cmd(string.format("%d,%dfold", startRow + 1, endRow + 1))
	end

	updateFoldDiagnostics()
end

function M.foldAround()
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(win)
	local line = cursor[1]  -- 1-indexed

	if not lastLine then
		lastLine = line
		return
	end

	local ft = vim.bo.filetype
	local queryStr
	if config.languages[ft] then
		queryStr = config.languages[ft]
	else
		queryStr = config.fallback
	end

	local status, parser = pcall(vim.treesitter.get_parser, buf, ft)
	if not status then return end

	local tree = parser:parse()[1]
	local root = tree:root()

	local ok, query = pcall(vim.treesitter.query.parse, ft, queryStr)
	if not ok then return end

	for _, node, _ in query:iter_captures(root, buf, lastLine - 1, lastLine) do
		local startRow, _, endRow, _ = node:range() -- startRow & endRow are 0-indexed
		if startRow < line and line < endRow + 2 then
			goto continue
		end
		vim.cmd(string.format("%d,%dfold", startRow + 1, endRow + 1))
		::continue::
	end

	lastLine = line
	updateFoldDiagnostics()
end

function M.setup(opts)
	config = vim.tbl_extend("force", defaults, opts)
end

vim.lsp.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config1)
	origHandler(err, result, ctx, config1)

	local bufnr = vim.api.nvim_get_current_buf()
	diags = vim.diagnostic.get(bufnr)
end

vim.api.nvim_create_autocmd("BufEnter", {
	callback = function ()
		vim.opt.foldmethod = "manual"
		vim.cmd("normal! zR")
		vim.schedule(M.foldFunctionsAndMethods)
	end
})

vim.api.nvim_create_autocmd("CursorMoved", {
	callback = function()
		if vim.api.nvim_get_mode().mode == "n" then
			vim.schedule(function ()
				M.foldAround()
			end)
		end
	end,
})

return M
