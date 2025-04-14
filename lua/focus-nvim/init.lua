local defaults = require("focus-nvim.defaults")
local M = {}

local config
local originalFoldmethod

function M.foldFunctionsAndMethods()
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()

	vim.api.nvim_set_option_value("foldmethod", "manual", { win = win })

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

	vim.opt.lazyredraw = false
	for _, node, _ in query:iter_captures(root, buf, 0, - 1) do
		local startRow, _, endRow, _ = node:range()
		vim.cmd(string.format("%d,%dfold", startRow + 1, endRow + 1))
	end

	vim.schedule(function ()
		vim.api.nvim_set_option_value("foldmethod", originalFoldmethod, { win = win })
		vim.opt.lazyredraw = true
	end)
end

function M.foldAround()
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(win)
	local line = cursor[1]  -- 1-indexed

	vim.api.nvim_set_option_value("foldmethod", "manual", { win = win })

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

	vim.opt.lazyredraw = false

	-- Calculate the limited range.
	local checkingRange = config.checkingRange
	-- Convert the 1-indexed line to 0-index for treesitter.
	local line_index = line - 1
	local query_start = math.max(0, line_index - checkingRange)
	local query_end = line_index + checkingRange + 1  -- end is typically exclusive

	for _, node, _ in query:iter_captures(root, buf, query_start, query_end) do
		local startRow, _, endRow, _ = node:range() -- startRow & endRow are 0-indexed
		if startRow < line and line < endRow + 2 then
			goto continue
		end
		vim.cmd(string.format("%d,%dfold", startRow + 1, endRow + 1))
		::continue::
	end

	vim.schedule(function ()
		vim.api.nvim_set_option_value("foldmethod", originalFoldmethod, { win = win })
		vim.opt.lazyredraw = true
	end)
end

function M.setup(opts)
	config = vim.tbl_extend("force", defaults, opts)
end

vim.api.nvim_create_autocmd("BufReadPre", {
	callback = function ()
		local win = vim.api.nvim_get_current_win()
		originalFoldmethod = vim.api.nvim_get_option_value("foldmethod", { win = win })
		vim.cmd("normal! zR")
		vim.schedule(function ()
			M.foldFunctionsAndMethods()
		end)
	end
})

vim.api.nvim_create_autocmd("CursorMoved", {
	callback = function()
		vim.schedule(function ()
			if vim.api.nvim_get_mode().mode == "n" then
				M.foldAround()
			end
		end)
	end,
})

return M
