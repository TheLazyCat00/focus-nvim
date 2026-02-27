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
	local result = ""
	for _, segment in ipairs(segments) do
		if result == "" then
			result = segment
			goto continue
		end
		result = result .. ", " .. segment
		::continue::
	end
	if result == "" then
		return ""
	end
	local virtualText = vim.diagnostic.config().virtual_text or {}
	result = string.rep(" ", virtualText.spacing) .. virtualText.prefix .. " " .. result
	return result
end

--- @class FocusConfig
--- @field languages table<string, string> Map of filetype to treesitter query string
--- @field fallback string Treesitter query string used when filetype has no entry in languages
--- @field callback fun(errors: integer, warns: integer, infos: integer, hints: integer): string Formats fold diagnostic virtual text
--- @field hlGroup string Highlight group for fold diagnostic virtual text
--- @field areaSearch integer Number of lines around cursor to check for changes
--- @field spreadSearch integer Step size for the spread change detection pass

--- @type FocusConfig
return {
	languages = {
		["lua"] = "(function_declaration) @func"
	},
	fallback = "(function_definition) @func",
	callback = defaultFormat,
	hlGroup = "NonText",
	areaSearch = 5,
	spreadSearch = 10,
}
