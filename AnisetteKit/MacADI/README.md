Mac CoreADI for AnisetteKit
============================

`src/{lib,adi,vm,macho,capi}.rs` are vendored from sacca97/os-findmy-e
commit 374d83854f657a7fdca45f813387d99d491db0e2, as used by
Jimpactor's `crates/omnisette/src/mac_anisette.rs`. The code is MIT licensed
(see LICENSE). It emulates a pinned x86_64 Mac CoreADI under Unicorn and
exposes the original C ABI. It does not include Apple's CoreADI binary.

`SourcesMac/MacAnisetteKit.swift` ports Jimpactor's `mac_libraries.rs`
(range-fetch and validate iTunes 12.8.3's CoreADI) and `mac_anisette.rs`
(persist identity/store, GrandSlam machine provisioning, fresh MID/OTP).
The user's Apple account data is not in the CoreADI store.

`Binaries/MacADICore.xcframework` is a static arm64-iOS-device framework.
It includes the vendored Rust implementation and mahee96/unicorn's x86 guest
engine, built with the Tiny Code Interpreter (no JIT). Rebuild it from source
on this Linux host with `MacADI/build-ios.sh`. The build script downloads the
pinned Unicorn fork; it does not download Apple's CoreADI binary. The app
fetches CoreADI itself on first run and checks both payload and binary SHA-256.
The build target is arm64 iOS device only; simulator is not supported.

Machine anisette is not the Store SAP action signature. `MacAnisetteKit`
provides X-Apple-I-MD/-M; the App Store native login also needs the separately
SAP-signed request body. Jimpactor's mac_anisette.rs does not implement SAP.
Apple can still return HTTP 204 for unsigned Store auth requests. Store-specific
SP provisioning and FairPlay keybag handling are also not implemented here.

Smoke test on Linux (after `cargo build --release`, with a local Unicorn
archive and an independently obtained, hash-checked CoreADI image):

    cc -I include tests/smoke.c target/release/libmac_adi_ios.a \
      /path/to/linux/libunicorn.a -ldl -lpthread -lm -o smoke
    ./smoke /path/to/CoreADI-x86_64

Expected for a fresh machine: `adi_headers(-2): -2 (machine is not provisioned)`.
This test makes no network calls or provisioning requests.

Provisioning must discard `STORE_DIR/adi.pb` after `adi_provisioning_finish`:
that legacy whole-machine blob masks the new per-user store and otherwise
`adi_headers(-2)` immediately returns `-2` even after Apple accepted the
provisioning exchange. The C ABI performs this step before the Swift layer
exports and saves the store (matching Jimpactor's mac_anisette.rs).
