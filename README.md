# focus-nvim

focus-nvim provides a "spotlight" folding experience for Neovim. It uses Tree-sitter to automatically fold code structures and ensures that only the area around your cursor remains unfolded, keeping your workspace clean and focused.

[Demo](https://github.com/user-attachments/assets/7a749d29-6e01-4e69-bbf9-75d207711c2d)

## Features

- **Contextual folding**: Folds follow your cursor. As you move into a region, it opens; as you move away, it closes.
- **Tree-sitter powered**: Define exactly which nodes (functions, classes, etc.) should be foldable using simple lists or full queries.
- **Folded diagnostics**: Displays error and warning counts for closed regions as inline virtual text and signs.
- **Performance**: Leverages Neovim's built-in Tree-sitter folding engine (`foldmethod=expr`) rather than manual range calculations.
- **Clean defaults**: Disables default runtime Tree-sitter folds (like Markdown sections) so that only the structures you care about are folded.

> [!NOTE]
> This plugin manages `foldmethod`, `foldexpr`, `foldopen`, and `foldclose`. It is designed for users who want an automated, cursor-centric folding workflow.

## Installation and configuration

Run `:InspectTree` to discover the node names for your specific language.

```lua
return {
	"TheLazyCat00/focus-nvim",
	event = "BufReadPost",
	opts = {},
}
```

The default options are at [lua/focus-nvim/defaults.lua](./lua/focus-nvim/defaults.lua).

## Options

### languages
A table mapping filetypes to either a list of node type strings or a raw Tree-sitter query. If a node list is provided, the plugin automatically filters out nodes that do not exist in that specific language grammar.

### fallback
The default folding rule used when the current filetype is not present in the `languages` table.

### fold
- **level**: Sets `foldlevel`. 0 ensures everything outside your cursor context is folded.
- **levelStart**: Sets the global `foldlevelstart`.
- **open**: Maps to the Neovim option `'foldopen'`. This controls which commands open a closed fold. Common values include `"all"`, `"search"`, `"undo"`, and `"jump"`. For a full list of supported triggers, see `:h 'foldopen'`. Note that standard vertical motions like `j` and `k` are not included in `foldopen`.
- **close**: Maps to the Neovim option `'foldclose'`. Set this to `"all"` to enable automatic re-folding when the cursor leaves a region. See `:h 'foldclose'` for more details.

### diagnostics
- **enabled**: Toggles the display of diagnostic counts on folded lines.
- **callback**: A function that formats the diagnostic counts into a string for the virtual text.
- **hlGroup**: The highlight group applied to the diagnostic virtual text.

## Usage

Once configured, focus-nvim operates automatically:
1. When you enter a buffer, it overrides the `folds` query for that language to match your configuration.
2. It sets the window to use Tree-sitter folding.
3. As you move the cursor, folds will adapt based on your `fold.open` and `fold.close` settings.
4. Closed folds will display a summary of any diagnostics (Errors, Warnings, etc.) contained within that hidden region.

The `require("focus-nvim").open(fallback)` can be used to add additional keys for opening folds and afterwards doing their normal action. It is not required to add movement keys (like `l` or `h`) since the plugin already includes `hor` in the open field in the options.
