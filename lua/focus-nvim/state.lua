--- @class FocusDiagPrefix
--- @field lineCount integer
--- @field err integer[]
--- @field warn integer[]
--- @field info integer[]
--- @field hint integer[]

local defaults = require("focus-nvim.defaults")

--- @class FocusState
--- @field ns integer?
--- @field diagsByBuf table<integer, vim.Diagnostic[]>
--- @field diagPrefixCache table<integer, FocusDiagPrefix>
--- @field pendingUpdate table<string, boolean>
--- @field config FocusConfig

--- @type FocusState
return {
	ns = nil,
	diagsByBuf = {},
	diagPrefixCache = {},
	pendingUpdate = {},
	config = defaults,
}
