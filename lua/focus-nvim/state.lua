local defaults = require("focus-nvim.defaults")

--- @class FocusDiagPrefix
--- @field lineCount integer
--- @field err integer[]
--- @field warn integer[]
--- @field info integer[]
--- @field hint integer[]

--- @class FocusState
--- @field enabled boolean
--- @field ns integer?
--- @field diagsByBuf table<integer, vim.Diagnostic[]>
--- @field diagPrefixCache table<integer, FocusDiagPrefix>
--- @field pendingUpdate table<string, boolean> Debounce flags (keyed by "bufnr:winid")
--- @field predicatesRegistered boolean
--- @field config FocusConfig

--- @type FocusState
return {
	enabled = true,
	ns = nil,
	diagsByBuf = {},
	diagPrefixCache = {},
	pendingUpdate = {},
	predicatesRegistered = false,
	config = defaults,
}
