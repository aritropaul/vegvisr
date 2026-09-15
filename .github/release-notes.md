Native macOS build of the Vegvisr seed map. The target is universal — the same
source builds for iOS — but an `.ipa` cannot be distributed without a signing
identity, so only the Mac app ships here.

**This build is ad-hoc signed, not notarised.** macOS will refuse to open it on
first launch. Either right-click the app and choose *Open*, or clear the
quarantine flag:

```
xattr -dr com.apple.quarantine /Applications/Vegvisr.app
```

Everything runs on your machine: no account, no upload, no network calls. The
world generator is a Swift port of the Rust one behind the web build, gated in
CI against it — `scripts/parity.py` records exactly which values are identical,
which differ, and by how much.
