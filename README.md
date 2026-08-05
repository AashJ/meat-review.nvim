# meat-review.nvim

Review the current branch's open GitHub pull request in Neovim with a reading diff produced by Meat. Meat is used only to
abridge the diff; all inline comments are written by you.

## Requirements

- Neovim 0.10 or newer
- `git`
- Authenticated [`gh`](https://cli.github.com/)
- [`meat`](https://github.com/samplehc/meat)

No Lua dependencies or setup function are required.

### Plugin-scoped OpenAI key

To avoid exporting `OPENAI_API_KEY` generally, set `MEAT_OPENAI_API_KEY` in the environment that launches Neovim. The
plugin maps it to `OPENAI_API_KEY` only for its Meat subprocess and does not modify Neovim's environment. For example, a
private `.envrc` can contain:

```sh
export MEAT_OPENAI_API_KEY='sk-...'
```

The standard `OPENAI_API_KEY` remains supported through Meat's normal environment handling when the plugin-specific alias
is unset.

## Development installation

```lua
{
  dir = '/Users/aash/Developer/Personal/meat-review.nvim',
  name = 'meat-review.nvim',
  cmd = { 'MeatReview', 'MeatReviewSubmit', 'MeatReviewStatus' },
}
```

## Workflow

Run `:MeatReview` from a Neovim instance opened within the repository you want to review. The first invocation discovers
the current branch's open PR, fetches its GitHub diff, and runs Meat asynchronously. Neovim remains usable while this
happens. When the ready notification appears, run `:MeatReview` again to open the review in a new tab.

Every invocation checks the repository, local branch, and head revision before reusing a review. Switching branches
automatically activates the matching PR. Exact repository/PR/head revisions are cached in memory, so returning to a branch
during the same Neovim process restores its mapped review and drafts without running Meat again. A new head SHA creates a
fresh review revision; Meat may satisfy that run from its own persistent diff cache. Old inline drafts remain attached only
to their original revision and are never copied onto new coordinates.

Only exact added and deleted lines retained by Meat can receive comments. Drafts live only in the current Neovim process.
Press `S`, or run `:MeatReviewSubmit`, to open the editable “Finish your review” floating panel over the Meat review. Write
a top-level Markdown comment in the real buffer; inline drafts appear below as read-only virtual lines. Three visible
radio-style choices select Comment, Approve, or Request changes. Pressing `S` saves the body and opens a separate final
GitHub confirmation. The PR head SHA is revalidated before all inline comments and the overall body are submitted together.

Run `:MeatReviewStatus` at any time to see whether the session is idle, running, ready, or open. While running, it reports
the current phase and elapsed time; Meat does not provide percentage completion in JSON mode.

### Review mappings

| Mapping | Action |
| --- | --- |
| `a` | Add or edit a comment on the current changed line |
| `d` | Delete the comment on the current line |
| `[c` / `]c` | Previous or next draft comment |
| `[f` / `]f` | Previous or next file |
| `S` | Preview submission |
| `q` | Close the review tab |

The inline comment editor saves with the normal `:write` command or `<C-s>`, and closes without saving with `q`.

The submission editor supports normal Markdown editing and these controls:

| Mapping | Action |
| --- | --- |
| `<Tab>` / `<S-Tab>` | Cycle Comment, Approve, and Request changes |
| `1` / `2` / `3` | Select Comment, Approve, or Request changes directly |
| `:write` | Save the overall review body and selected action |
| `S` | Save and open the final confirmation |
| `q` | Save the draft and close without submitting |
| `D` | Discard the top-level body and action; keep inline drafts |

## Tests

Run the pure diff-mapping suite headlessly:

```sh
nvim --headless -u tests/minimal_init.lua -l tests/diff_spec.lua
nvim --headless -u tests/minimal_init.lua -l tests/flow_spec.lua
```

Format the Lua sources with:

```sh
stylua lua plugin tests
```

## MVP limitations

- One visible active review with dormant per-revision sessions in memory; plugin drafts do not persist after exit
- Unified reading view only; no side-by-side diff
- Single-line anchors on exact retained additions or deletions only
- No range annotations or replies
- Quoted or otherwise unsupported Git paths are displayed but cannot be annotated
- No generated-comment feature
