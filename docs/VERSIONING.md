# Version and configuration retention

The owner requested GitHub retention of every delivered Harmony Side Screen version on 2026-10-12. Product releases and display settings must be traceable together.

1. Choose a new semantic version. Update VERSION, MacHost/Info.plist, HarmonyClient/AppScope/app.json5 (including increasing versionCode), HarmonyClient/oh-package.json5 and HarmonyClient/entry/oh-package.json5.
2. Add docs/versions/<version>.json and a changelog entry. Separate observed settings, configured targets and measured results. Include the previous source commit and intended immutable tag; the tag itself identifies the final source commit.
3. Record physical viewport, logical desktop, source backing, encoded output, HiDPI, scaling mode, encoder quality, target FPS and any per-application zoom. Record the negotiated USB rate separately from measured payload/video rates. Do not export all user preferences or device metadata into public records.
4. Run the version check, relevant tests and build checks. Hash final artifacts after signing. Document installed-device checks separately from successful builds.
5. Review the staged files. Commit only the intended source/documentation. Create an immutable v<version>-preview.<n> tag at that commit and push the branch/tag to the owner's repository.
6. Create a GitHub prerelease with the reviewed public Mac DMG and SHA256SUMS. Retain old assets. Device-specific Huawei debug HAPs stay in private local storage; the record may include their checksum but not provisioning material.
7. Verify GitHub's source commit, tag, asset names and downloadable hashes. Installation and AppGallery publication are separate actions/evidence.

For configuration-only experiments between software releases, add a uniquely named dated profile record under docs/versions/profiles/ with source/build identifiers and actual settings; commit it before claiming that exact state is retained. Do not rebuild/reinstall merely to record a preference change. Preserve unknowns instead of inventing historical settings.

The inherited scripts/release.sh and scripts/bump-version.sh concern SideScreen/Android and are not the Harmony release route. Public source is MIT; signing material is never public.
