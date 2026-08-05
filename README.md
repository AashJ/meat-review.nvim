# meat-review.nvim

Review the current branch's open GitHub pull request or the current local commit in Neovim with a reading diff produced by
Meat. Meat is used only to abridge the diff; all inline comments are written by you.

## Requirements

- Neovim 0.10 or newer
- `git`
- Authenticated [`gh`](https://cli.github.com/)
- [`meat`](https://github.com/samplehc/meat)

No Lua dependencies or setup call are required.

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
  cmd = { 'MeatReview', 'MeatReviewCommit', 'MeatReviewOpenFile', 'MeatReviewSubmit', 'MeatReviewStatus' },
}
```

## Workflow

Run `:MeatReview` from a Neovim instance opened within the repository you want to review. The first invocation discovers
the current branch's open PR, fetches its GitHub diff, and runs Meat asynchronously. Neovim remains usable while this
happens. When the ready notification appears, run `:MeatReview` again to open the review in a new tab.

Every invocation resolves the current branch's GitHub PR and its base/head revisions before reusing a review. Switching
branches automatically activates the matching PR. Exact repository/PR/base/head revisions are cached in memory, so
returning to a branch during the same Neovim process restores its mapped review and drafts without running Meat again. A new
base or head SHA creates a fresh review revision; Meat may satisfy that run from its own persistent diff cache. Old inline
drafts remain attached only to their original revision and are never copied onto new coordinates.

Run `:MeatReviewCommit` to limit Meat's analysis to the current `HEAD` while submitting the resulting review to the current
branch's open PR. Local `HEAD` must match the PR head. The first invocation diffs `HEAD` against its first parent, validates
the aggregate PR diff, and runs Meat; the second opens the review. Root commits are diffed against an empty tree. Commit
reviews are cached by PR and commit coordinates and use the normal GitHub submission flow.

Only commit changes that also have an unambiguous location in the aggregate PR diff can receive inline comments. For
example, a line added earlier in the PR and then deleted by `HEAD` is still shown in the commit review, but cannot be
submitted as an inline PR comment because it does not exist in the aggregate PR diff.
Added lines are matched by their exact final-file line and content. Deleted lines are commentable only when the reviewed
commit's parent is the PR base, because GitHub's `LEFT` coordinates refer to that base rather than an intermediate commit.

Only exact added and deleted lines retained by Meat can receive comments. Drafts live only in the current Neovim process.
Press `S`, or run `:MeatReviewSubmit`, to open the editable “Finish your review” floating panel over the Meat review. Write
a top-level Markdown comment in the real buffer; inline drafts appear below as read-only virtual lines. Three visible
radio-style choices select Comment, Approve, or Request changes. Pressing `S` saves the body and opens a separate final
GitHub confirmation. The PR base and head SHAs are revalidated before all inline comments and the overall body are submitted
together.

Run `:MeatReviewStatus` at any time to see whether the session is idle, running, ready, or open. While running, it reports
the current phase and elapsed time; Meat does not provide percentage completion in JSON mode.

Run `:MeatReviewOpenFile`, or press `o` in the review, to open the complete base-to-head diff for the file under the cursor
in a vertical split. This uses the exact full diff already captured for the review and does not contact GitHub or rerun Git.

To hand file opening to another diff viewer, configure an optional callback:

```lua
require('meat-review').setup({
  open_file = function(context)
    -- context contains root, path, old_path, new_path, optional line/side,
    -- kind ('pr' or 'commit'), base_sha, and head_sha.
  end,
})
```

The callback owns its window layout, so it can open Diffview, Fugitive, a terminal viewer, or any custom split.

### Review mappings

| Mapping | Action |
| --- | --- |
| `a` | Add or edit a comment on the current changed line |
| `d` | Delete the comment on the current line |
| `[c` / `]c` | Previous or next draft comment |
| `[f` / `]f` | Previous or next file |
| `o` | Open the complete current-file diff, or invoke the configured file opener |
| `S` | Preview PR submission |
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
nvim --headless -u tests/minimal_init.lua -l tests/commit_flow_spec.lua
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
