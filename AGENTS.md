# Notchline upgrades

- Treat every release as an in-place replacement of the existing `Notchline.app`. Keep the app bundle name, executable name, and bundle ID `local.notchline.personal` unchanged.
- Increase both `CFBundleShortVersionString` and `CFBundleVersion` for every release. Build with `bash scripts/build-app.sh release` and package with `bash scripts/package-dmg.sh`.
- Before delivering an upgrade, inspect the previous app's actual installation folder. Replace it there, whether it is `/Applications` or `~/Applications`, and check that no second Notchline app was installed.
- Verify the replacement runs, only one Notchline process remains, and existing preferences and hanging items survive. The shareable DMG's instructions must tell colleagues to quit the old app and choose Replace in its existing folder.

# Git commits

- This is a personal repository. Use ordinary local Git commands and the existing commit style. Do not apply company `git-workflow` rules, require a Jira ID, or add a company-specific AI trailer.
- Write a concise English imperative subject, such as `Add ...` or `Fix ...`. Add a body when the reason or scope needs explanation.
- Review the staged diff before committing. Commit only task-related files, and push only when explicitly requested.
