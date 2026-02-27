--- @class FocusState
--- @field config FocusConfig | nil Plugin configuration, set by setup()
--- @field lastLine integer | nil The last cursor line seen by foldAround()
--- @field diags vim.Diagnostic[] | nil Diagnostics for the current buffer
--- @field lastContent table<integer, string[]> Map of bufnr to last known buffer lines

--- @type FocusState
return {
	config = nil,
	lastLine = nil,
	diags = nil,
	lastContent = {},
}
