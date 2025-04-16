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

return {
	languages = {
		["lua"] = "(function_declaration) @func"
	},
	fallback = "(function_definition) @func",
	callback = defaultFormat,
	hlGroup = "NonText"
}
