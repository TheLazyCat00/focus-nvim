# focus-nvim

focus-nvim is a Neovim plugin that makes your code less distracting. It utilizes Treesitter to automatically fold regions in your code and provides smart folding by using language-specific queries to detect foldable function definitions and structures, making your code more navigable and less cluttered.

[Demo](https://github.com/user-attachments/assets/7a749d29-6e01-4e69-bbf9-75d207711c2d)

## Features

- Automatically folds functions and methods when a buffer is read.
- Continuously closes folds when the cursor moves.
- Uses flexible, language-specific Treesitter queries.
- Provides a fallback query when no specific language configuration is found.

> [!WARNING]
> This plugin overwrites the `vim.api.foldmethod` value and sets it to `"manual"`. This is the only possible way to handle complex folding logic and could have negative side effects if you use folds for other things as well.

## Installation and configuration

> [!TIP]
> Do `:InspectTree` to see all the available nodes in the current buffer

```lua
{
    "TheLazyCat00/focus-nvim",
    event = "BufReadPre",

    -- these are also the defaults
    opts = {
        languages = {
            -- add your languages here
            -- NOTE: you have to set a capture group
            -- the name of the group can be anything
            -- here it's @func
            ["lua"] = "(function_declaration) @func"
        },

        -- fallback for when the language is not set in languages
        -- NOTE: also set a capture group here
        fallback = "(function_definition) @func",

        -- function whose return value is used as a display text
        -- used for diagnostics inside the fold which cannot be seen
        -- this example would simply display the amount of errors
        -- the default function for this is defined  1 section further below

        callback = function(errors, warns, infos, hints)
            -- consider taking a look at:
                vim.diagnostic.config().virtual_text
            ----------------------------------------

            return errors
        end,

        -- the highlight-group for the diagnostic message
        hlGroup = "NonText"
    },
}
```

<details>
    <summary>
        Default formatting function
    </summary>

```lua
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
```
</details>

Take a look at the [`defaults`](lua/focus-nvim/defaults.lua) file for the options that are actually being used in the [`init.lua`](lua/focus-nvim/init.lua).

### opts

- **languages:** A table associating filetypes with Treesitter queries for identifying foldable code blocks.
- **fallback:** A fallback Treesitter query if no language-specific option exists.
- **callback**: A function whose return value is used as a display text.
- **hlGroup**: The highlight-group which is used for the diagnostics message.

## Usage

When a file is opened, focus-nvim:
- Automatically unfolds all folds.
- Applies language-specific folding rules to fold functions and methods.
- Continuously adjusts folds, ensuring only the relevant code remains unfurled.

This plugin operates silently in the background, requiring no additional commands.
