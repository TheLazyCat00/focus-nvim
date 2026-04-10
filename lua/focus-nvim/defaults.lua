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

--- @class FocusFoldConfig
--- @field level? integer
--- @field levelStart? integer
--- @field open? string
--- @field close? string
--- @field startClosed? boolean

--- @class FocusDiagnosticsConfig
--- @field enabled boolean
--- @field debounceMs integer
--- @field callback fun(errors: integer, warns: integer, infos: integer, hints: integer): string
--- @field hlGroup string

--- @class FocusConfig
--- @field languages table<string, string|table> Map of filetype -> folds query string OR list of node types
--- @field fallback string|table Fallback folds query string OR list of node types
--- @field fold FocusFoldConfig
--- @field diagnostics FocusDiagnosticsConfig

--- @type FocusConfig
return {
	languages = {
		lua = { "function_declaration", "function_definition" },
	},
	fallback = { "function_definition" },

	fold = {
		level = 0,
		levelStart = 0,
		startClosed = true,

		-- Cursor-centric behavior (set open="" if you want manual-open-only)
		open = "",
		close = "all",
	},

	diagnostics = {
		enabled = true,
		debounceMs = 80,
		callback = defaultFormat,
		hlGroup = "NonText",
	},
}
