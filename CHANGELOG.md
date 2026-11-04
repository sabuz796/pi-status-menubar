# Changelog

Versions are tags on this repository. Only released versions are listed here, newest first. The installed app is what each entry describes; build-internal work and documentation-only commits are left out unless they change what the app or its installer does.

## [0.0.3]

Security and privacy release.

- The state folder is private again. `~/.pi/statusbar` and `state.d` are created with mode 0700 by the app and the extension, and an existing folder is closed again on every write. Other accounts on a shared Mac can no longer read your session files, project and working-directory names, or the log. The fix applies to existing installs on the next app launch. (#10)
- Click-to-focus is safer. Terminals are raised by name from a fixed list (Terminal, iTerm, Warp, Visual Studio Code, Ghostty, Alacritty, WezTerm, Hyper); any other `term_program` value in a session file now leaves the row without a focus target instead of reaching `open -a`. (#8)
- The bundled extension is installed only while the app bundle still matches its code signature. A signature that fails to validate is treated as tampering: the app refuses to copy anything into Pi and logs `extension-install-refused`. An edited copy in `~/.pi/agent/extensions` is backed up to `.bak` before replacement, as before. (#8)
- CI verifies the app seal (`codesign --verify --deep --strict`) after every build, because the install guard fails closed. (#9)
- The focus refresh marker is written atomically, so the extension can no longer read a half-written one. (#10)
- Log rotation is one step in both writers, so two simultaneous rotations no longer delete the moved log generation. (#11)
- If the state folder disappears while the app runs, the dashboard cache save recreates it at 0700 instead of the umask default. (post-audit fix)
- CI runs with `permissions: contents: read`; the release job keeps its own write scope.

## [0.0.2]

- Fixed session row clicks: the click routes through the row, so rows activate reliably.
- First stable release (no longer a prerelease).

## [0.0.1]

- Initial release: menu bar item with live Pi session state, panel, click-to-focus, dashboard, Homebrew cask and DMG install.

[0.0.3]: https://github.com/sabuz796/pi-status-menubar/releases/tag/v0.0.3
[0.0.2]: https://github.com/sabuz796/pi-status-menubar/releases/tag/v0.0.2
[0.0.1]: https://github.com/sabuz796/pi-status-menubar/releases/tag/v0.0.1
