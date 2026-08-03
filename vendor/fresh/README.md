# fresh (vendored)

This is a vendored copy of [`fresh` 0.4.4](https://hex.pm/packages/fresh)
(the WebSocket client `Rvrb.WebSocket` is built on), MIT licensed - see
`LICENSE`.

It's vendored rather than pulled from Hex because `fresh` 0.4.4 (and its
unreleased `main` branch as of 2026-08) declares `elixirc_paths` as
charlists (`~c"lib"`) instead of strings. Elixir 1.20 made `mix compile`
enforce that `:elixirc_paths` must be a list of strings, so the upstream
package fails to compile there. The only change from upstream is that one
line in `mix.exs`; `lib/` is untouched.

Check upstream periodically - once a release fixes this, drop this
directory and switch `mix.exs` back to `{:fresh, "~> 0.x"}`.
