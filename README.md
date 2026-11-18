# diff-review

Neovim plugin for reading a review diff and its `.answer` file. It pins the current file and hunk at the top of the window, and jumps between inline `AI #n` / `Disagreement #n` notes and the summary at the bottom.

## Install with lazy.nvim

```lua
{
  "GalLalouche/diff-review",
  opts = {},
}
```

`opts` is optional. With no `opts` and no `config` function, the plugin calls `setup()` with its defaults. This spec loads the plugin at startup, so `.answer` is registered before you open a file.

### Lazy-load on the diff filetype

`ft = "diff"` waits to load the plugin until a buffer's filetype is `diff`. Neovim already does that for `*.diff` and `*.patch`. A `*.answer` file becomes `diff` only because this plugin registers the extension, and that registration is inside `setup()`, which runs after the plugin loads. Put the registration in `init`, which lazy runs at startup while the plugin is still unloaded:

```lua
{
  "GalLalouche/diff-review",
  ft = "diff",
  init = function()
    vim.filetype.add({ extension = { answer = "diff" } })
  end,
  opts = {},
}
```

Opening `foo.answer` then sets the filetype to `diff`, and lazy loads the plugin.

## Keys

These apply in `diff` buffers, including `.answer` files.

| Key | Action |
| --- | --- |
| `gd` | Jump between an inline `AI #n` or `Disagreement #n` and its summary entry |
| `]f` / `[f` | Next / previous file |
| `]a` / `[a` | Next / previous inline action item |

`:DiffReview` toggles the sticky file and hunk header.

Pass `opts` to change the keys. Omitted keys keep their defaults.

```lua
opts = {
  keymaps = {
    goto_link = "gd",
    next_file = "]f",
    prev_file = "[f",
    next_action_item = "]a",
    prev_action_item = "[a",
  },
}
```
