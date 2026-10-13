# Harmony Side Screen

## Non-interactive local execution

The owner has authorized unattended local development actions. Use the configured bypass-permissions mode and continue through ordinary shell and local-MCP work without asking. For generated-artifact cleanup, do not use `rm` with variables, globs, command substitution, or relative paths. Use a small checked Python cleanup with one literal absolute directory, then run the requested task.

Public project: https://github.com/Shonn-Li/HarmonySideScreen
Former name: HarmonyScreen. Mac and HarmonyOS bundle IDs and preference keys stay stable across branding updates. Retain SideScreen's MIT license and attribution.

## Delivery and history

The owner explicitly requests that every delivered version be retained on GitHub with enough context to compare and roll back. Follow docs/VERSIONING.md:

- Use a new version for a delivered source/build change; update VERSION, the Harmony app metadata, Mac plist, and both Harmony package metadata files together.
- Record logical desktop size, source/render pixels, encoded pixels, HiDPI, quality, target FPS, relevant application zoom and test results separately. Mark unknown history as unknown.
- Preserve prior commits, immutable tags, release assets and local private signed builds. Do not overwrite an old package or retag a release.
- Review the exact diff and artifacts, run applicable checks, then commit and publish the requested scoped version. Do not imply a public store release or broad compatibility from a debug install.
- Use the preview tag v<version>-preview.<n>, not inherited upstream SideScreen tags. Use scripts/package_harmony_mac.sh for Mac builds, not the retained upstream Android/release scripts.
- Keep signing profiles, device identifiers, certificates, keys, debug-signed HAPs, desktop screenshots, app content and credentials out of public Git/release assets.
- Document build, installed version, actual device playback and public-release status separately. FPS counters are decoder submissions, not proof of panel refresh or end-to-end latency.
- Do not disrupt other screens or reconfigure a working user session merely to create a version record.

## Validation

Run python3 scripts/check_harmony_version.py, git diff --check, and relevant Mac/C++ tests. Build with the current DevEco SDK for receiver edits and verify native controls/playback on the connected authorized device when available. Avoid tests that disconnect the user's screen outside a test session.

Current native pixel matching and the limits of larger-text scaling are documented in docs/PERFORMANCE-2026-10-12.md. Never claim that an upscaled 3K frame contains native 3K detail.
