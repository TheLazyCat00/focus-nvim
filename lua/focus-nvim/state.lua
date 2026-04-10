--- @class FocusState
--- @field ns integer?
--- @field diagsByBuf table<integer, vim.Diagnostic[]>
--- @field pendingUpdate table<integer, boolean>
--- @field config FocusConfig?

--- @type FocusState
return {
	ns            = nil,
	diagsByBuf    = {},
	pendingUpdate = {},
	config        = nil,
}
