# Overnight Dogfood Report - 2026-04-30

Disposable Linear issue: `KM-16` (`8dc659df-b1a9-46e8-bc13-f34619155a0e`)
Workspace/project: `km-symphony` / `Symphony`
Cleanup: moved to `Canceled` at the end of the smoke.

## Commands

- `symphony status`: pass. Replied with compact status.
- `symphony pause`: pass. Persisted `paused: true` in the hidden status marker.
- Paused non-command comment: pass. Comment was acknowledged and the marker advanced without starting a worker.
- `symphony resume`: pass after marker fix. Replied once and restored `paused: false`.
- `symphony cancel`: pass. Replied once, left workspace intact, and persisted paused runtime state.

## Review Loop

- Non-command Human Review comment: pass. Symphony started a Review Run, replied in-thread with `Saw this comment. Leaving KM-16 in Human Review.`, and left the issue in `Human Review`.
- Runtime visibility: pass. The TUI distinguished the run as `Review Run`, and the API exposed comment polling health.

## File Tools

- `linear_upload_file`: pass. Uploaded `dogfood-artifact.txt` from a temporary local workspace, created a threaded reply, and attached a Linear upload URL.
- `linear_download_file`: pass. Downloaded the uploaded asset back into a temporary local workspace and reported 65 bytes.
- Launch caveat: use `mix run --no-start -e 'SymphonyElixir.CLI.main(...)'` or the escript for smoke runs. Plain `mix run -e` starts the app before CLI options can apply the workflow/port override.

## Issues Found And Fixed

- Duplicate command replies: live smoke showed `status`/`pause` could replay because Linear updates comment `updatedAt` after the eyes reaction. Fixed by treating the last-seen comment id as consumed and by using comment creation time for ordering when available.
- Verification hazard: one early smoke check accidentally used plain `mix run -e`, which started an additional app instance. Subsequent verification used the Linear MCP, direct API checks, and `mix run --no-start` for isolated dynamic-tool calls.

## Recommended Next Work

- Add a small launch doc for local smoke commands so future runs use `--no-start` with `mix run`.
- Consider storing an explicit `last_seen_comment_created_at` marker field in a later migration; current behavior remains backward-compatible with the existing marker key.
- Add a tiny CLI smoke helper that creates a disposable issue, runs the command sequence, and cleans it up.
