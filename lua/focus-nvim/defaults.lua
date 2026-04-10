--- Formats diagnostic counts into a virtual text string.
--- @param errors integer Number of error diagnostics
--- @param warns integer Number of warning diagnostics
--- @param infos integer Number of info diagnostics
--- @param hints integer Number of hint diagnostics
--- @return string formatted The formatted diagnostic string, or "" if none
local function defaultFormat(errors, warns, infos, hints)
	local segments = {}

	if errors > 0 then
		table.insert(segments, "Errors: " .. errors)
	end
	if warns > 0 then
		table.insert(segments, "Warns: " .. warns)
	end
	if infos > 0 then
		table.insert(segments, "Infos: " .. infos)
	end
	if hints > 0 then
		table.insert(segments, "Hints: " .. hints)
	end

	local result = table.concat(segments, ", ")
	if result == "" then
		return ""
	end

	local vt = vim.diagnostic.config().virtual_text or {}
	local spacing = vt.spacing or 0
	local prefix = vt.prefix or ""

	if prefix ~= "" then
		return string.rep(" ", spacing) .. prefix .. " " .. result
	end
	return string.rep(" ", spacing) .. result
end

---@alias FocusFoldsSpec string|string[] Folds query string OR list of node type names

--- @class FocusFoldConfig
--- @field level? integer foldlevel (window-local)
--- @field levelStart? integer foldlevelstart (global)
--- @field open? string foldopen (global)
--- @field close? string foldclose (global)

--- @class FocusDiagnosticsConfig
--- @field enabled boolean
--- @field debounceMs integer
--- @field callback fun(errors: integer, warns: integer, infos: integer, hints: integer): string
--- @field hlGroup string

--- @class FocusConfig
--- @field languages table<string, FocusFoldsSpec> Map of filetype -> folds query OR list of node types
--- @field fallback FocusFoldsSpec? Fallback folds query OR list of node types
--- @field fold FocusFoldConfig
--- @field diagnostics FocusDiagnosticsConfig

--- @type FocusConfig
return {
	languages = {
		lua = { "function_declaration", "function_definition" },
	},

	-- Generic fallback is allowed, but will be validated per-language and skipped if invalid.
	fallback = { "function_definition" },

	fold = {
		level = 0,
		levelStart = 0,

		-- Cursor-centric behavior:
		-- open=""      => never auto-open folds (manual only)
		-- close="all"	=> auto-close folds you leave (re-applies foldlevel)
		open = "search,hor,jump,mark,undo",
		close = "all",
	},

	diagnostics = {
		enabled = true,
		debounceMs = 80,
		callback = defaultFormat,
		hlGroup = "NonText",
	},
}
