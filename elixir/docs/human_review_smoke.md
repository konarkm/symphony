# Human Review Smoke Recipe

Use this recipe after changing the Linear review loop. Keep smoke tickets out of
the active queue when the run is done.

## Talking Comment

1. Create a Linear issue in the configured Symphony project.
2. Move it to `Human Review`.
3. Wait for Symphony to initialize or update the `## Symphony Status` comment.
4. Add a human comment asking a direct question or requesting a short reply.
5. Confirm Symphony adds an eyes reaction to the human comment.
6. Confirm Symphony replies as a child comment with `parentId` set to the
   triggering comment id.
7. Confirm the issue remains in `Human Review`.

## Work Comment

1. Create a second Linear issue in the configured Symphony project.
2. Move it to `Human Review`.
3. Wait for Symphony to initialize or update the `## Symphony Status` comment.
4. Add a human comment requesting a small, verifiable repo or workspace change.
5. Confirm Symphony adds an eyes reaction to the human comment.
6. Confirm Symphony moves the issue to `Rework`, performs the work, validates
   it, updates the compact status comment, and returns the issue to
   `Human Review`.
7. Confirm natural approval-like wording did not move the issue to `Merging`.

## Cleanup

After recording the result, add a short operator note and move smoke issues to
`Canceled`.
