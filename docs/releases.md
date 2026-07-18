# Releases

This project uses semantic version tags with a `v` prefix. The repository
`VERSION` file contains the same version without the prefix and is the source of
truth for `agentctl --version`.

## 0.2 migration notes

Version 0.2 removes the deprecated `codexctl` wrapper. Use `agentctl` directly.
Codex image defaults move from `/etc/codexctl` to `/etc/agentctl/codex`, while
shared image guidance lives at `/etc/agentctl/image.md`. `agentctl refresh`
migrates existing managed containers, preserves their image guidance, and
removes the old managed paths.

## Release checklist

1. Choose the next semantic version based on user-visible compatibility:
   - patch for backward-compatible fixes
   - minor for backward-compatible features or newly supported runtimes
   - major for intentional breaking changes
2. Update `VERSION` on the release branch and include the change in its PR.
3. Run the repo-local suite:

   ```bash
   bash tests/run-unit-tests.sh
   ```

4. Run the complete host suite on macOS with Apple's supported `container`
   version:

   ```bash
   bash tests/run-tests.sh --tier full
   ```

5. Merge the PR through GitHub and update local `main` with `git pull
   --ff-only`.
6. Verify the release target and version before publishing:

   ```bash
   version="$(cat VERSION)"
   test "$(./agentctl --version)" = "agentctl $version"
   git status --short --branch
   git log -1 --oneline
   git ls-remote --exit-code --tags origin "refs/tags/v$version" && {
     echo "Tag v$version already exists" >&2
     exit 1
   }
   ```

7. Create and push an annotated tag for the merged `main` commit:

   ```bash
   git tag -a "v$version" -m "Release v$version" main
   git push origin "v$version"
   ```

8. Publish the GitHub release from that verified tag:

   ```bash
   gh release create "v$version" \
     --verify-tag \
     --title "v$version" \
     --generate-notes
   ```

9. Confirm the release and its tag point at the intended commit:

   ```bash
   gh release view "v$version"
   git ls-remote --tags origin "refs/tags/v$version"
   ```

Do not move or reuse a published version tag. Corrections after publication get
a new patch release.
