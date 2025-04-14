# focus-nvim

focus-nvim is a Neovim plugin that makes your code less distracting. It utilizes Treesitter to automatically fold regions in your code and provides smart folding by using language-specific queries to detect foldable function definitions and structures, making your code more navigable and less cluttered.

## Features

- Automatically folds functions and methods when a buffer is read.
- Dynamically opens folds under the cursor on movement.
- Uses flexible, language-specific Treesitter queries.
- Provides a fallback query when no specific language configuration is found.

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
    },
}
```

## opts

- **languages:** A table associating filetypes with Treesitter queries for identifying foldable code blocks.
- **fallback:** A fallback Treesitter query if no language-specific option exists.

## Usage

When a file is opened, focus-nvim:
- Automatically unfolds all folds.
- Applies language-specific folding rules to fold functions and methods.
- Continuously adjusts folds around the cursor, ensuring only the relevant code remains unfurled.

This plugin operates silently in the background, requiring no additional commands.
