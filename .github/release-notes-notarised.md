Native macOS build of the Vegvisr seed map. The target is universal — the same
source builds for iOS — but an `.ipa` cannot be distributed this way, so only
the Mac app ships here.

Universal (Apple Silicon and Intel), signed with a Developer ID certificate,
notarised by Apple and stapled, so it opens by double-clicking with no
Gatekeeper warning and no `xattr` incantation.

Everything runs on your machine: no account, no upload, no network calls. The
world generator is a Swift port of the Rust one behind the web build, gated in
CI against it — `scripts/parity.py` records exactly which values are identical,
which differ, and by how much.
