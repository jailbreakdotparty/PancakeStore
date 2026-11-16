# AnisetteKit

A high-performance, on-device Anisette Data generator and ADI emulation library for **iOS, macOS, tvOS, and visionOS** via Swift Package Manager.

---

## Background

`AnisetteKit` is built on top of foundational ideology behind **Sidestore's** `omnisette-server` and uses **unicorn-engine's** `linux elf64 emulation` to achieve self-contained on-device authentication:

- **[SideStore/omnisette-server](https://github.com/SideStore/omnisette-server)**: Originally demonstrated that ADI shared libraries (`libstoreservicescore.so` and `libCoreADI.so`) could be executed in an AArch64 Linux environment to provision and generate valid Anisette authentication data. However, `omnisette-server` required deploying and maintaining a remote Linux server or Docker container, introducing network latency, hosting overhead, and server dependencies.
- **[Unicorn Engine (TCI)](https://github.com/unicorn-engine/unicorn)**: A lightweight, multi-platform CPU emulator. By leveraging Unicorn compiled with the Tiny Code Interpreter (TCI) backend into multi-platform XCFrameworks, `AnisetteKit` executes the Linux AArch64 binaries inside an in-process virtual machine. This enables seamless, zero-server execution directly on iOS, tvOS, and visionOS without requiring JIT entitlements or debug servers.

---

## Features

- **Full On-Device Execution**: Runs entirely local on device.
- **NO Servers Required**: Completely eliminates the need for remote or external Anisette servers.
- **Custom TCI Engine for Unicorn**: Powered by our custom Tiny Code Interpreter (TCI) implementation added to Unicorn Engine (`-DUNICORN_ENABLE_TCI=ON`), enabling pure C bytecode interpretation of Linux AArch64 binaries across iOS, macOS, tvOS, and visionOS without JIT.
- **NO JIT-Entitlement / Debug-Server Required**: Runs on iOS, tvOS, and visionOS devices without requiring JIT entitlements, debug servers, or W^X kernel violations.
- **Native Host Execution on macOS**: Runs Linux AArch64 binaries directly on ARM64 host CPUs via in-process memory mapping for fastest header generation.

---

## Platforms Supported

| Platform                          | Runtime Mode              | JIT Required |
| :-------------------------------- | :------------------------ | :----------- |
| **iOS (Real Device)**             | TCI Bytecode Interpreter  | No           |
| **iOS Simulator**                 | TCI Bytecode Interpreter  | No           |
| **macOS (ARM64 & x86_64)**        | Native AArch64 / Emulated | No           |
| **tvOS (Device & Simulator)**     | TCI Bytecode Interpreter  | No           |
| **visionOS (Device & Simulator)** | TCI Bytecode Interpreter  | No           |

---

## Public API Reference

### `AnisetteClient` & `AnisetteClientProtocol`

#### `init(provisioningDir:clientInfo:provider:libraryDirectoryResolver:) throws`
* **When to use**: Initializes the client, attaches a provider, and conditionally resolves/validates the `.so` directory via closure for providers that require local binaries.
* **Parameters**:
  * `provisioningDir`: Directory `URL` where persistent device provisioning state (`adi.pb`) is saved.
  * `clientInfo`: Apple client identification string (defaults to `AnisetteConstants.defaultClientInfo`).
  * `provider`: Optional `any AnisetteDataProvider` (defaults to `NativeAnisetteDataProvider` on macOS, `UnicornAnisetteDataProvider` on other platforms).
  * `libraryDirectoryResolver`: Optional closure returning the directory `URL` containing required `.so` binaries (required when local providers are used).

#### `validateLibrariesExist(at:) -> Bool`
* **When to use**: Pre-flight validation before initialization to verify `libstoreservicescore.so` and `libCoreADI.so` exist in the specified directory `URL`.
* **Parameters**:
  * `directory`: Filesystem `URL` to inspect.

#### `getAnisetteData(identifier:storage:headers:) async throws -> (headers: [String: String], newBlob: Data?)`
* **When to use**: Core entrypoint for Anisette header generation with configurable provisioning storage and request headers.
* **Parameters**:
  * `identifier`: Persistent device `UUID`.
  * `storage`: `.disk` (default) or `.memory(existingBlob:)`.
  * `headers`: Optional `AnisetteRequestHeaders` object to customize client/device metadata.
* **Returns**: Tuple `(headers: [String: String], newBlob: Data?)` containing generated headers and newly provisioned blob if created.

---

### Low-Level Data Provider Protocol (`AnisetteDataProvider`)

* **`AnisetteDataProvider`**: Public protocol for ADI data providers (`requiresLocalLibraries`, `getAnisetteHeaders`, `startProvision`, `endProvision`).
* **`UnicornAnisetteDataProvider`**: Pure C Unicorn TCI emulation provider (available on all platforms).
* **`NativeAnisetteDataProvider`**: Direct host memory-mapped AArch64 execution provider (macOS only).

---

### Types & Constants

* **`LibraryDirectoryResolver`**: `@Sendable () throws -> URL` closure type for supplying runtime `.so` directory.
* **`AnisetteRequestHeaders`**: Structure representing Anisette request headers with full parameter customizability and fluent `.with { ... }` support.
* **`AnisetteDataResponse`**: Structure holding cryptographic output response headers (`oneTimePassword`, `machineID`).
* **`AnisetteError`**: Strongly-typed errors (`librariesNotFound`, `loaderFailed`, `symbolMissing`, `adiError`, `invalidArgument`, `httpError`, `invalidResponse`).
* **`AnisetteConstants`**: Contains default headers, routing code (`17106176`), URLs, and required binary names (`AnisetteConstants.Libraries.requiredNames`).

---

## Disclaimer

This project is provided for **educational and research purposes only**.

- `AnisetteKit` is an independent project and is not affiliated with, sponsored by, or endorsed by Apple Inc.
- Use of this software is entirely at your own risk. The author and contributors assume no responsibility or liability for any damages, locked accounts, account penalties/bans, or legal repercussions arising from the use or distribution of this code.
- By using this library, you agree to comply with all applicable terms, laws, and regulations.

---

## License & Terms

`AnisetteKit` is licensed under the **GNU Affero General Public License v3.0 (AGPLv3)**.

### Key Terms:

- **Strong Copyleft**: Any application, framework, or tool that compiles against, links against (statically or dynamically), or includes `AnisetteKit` is considered a combined/derivative work and **must be fully open-sourced under the AGPLv3** upon distribution.
- **Network / Cloud Trigger (AGPL Section 13)**: If you run `AnisetteKit` as part of any network service, cloud API, or server backend (e.g. hosting a remote Anisette server), you **must make the complete, corresponding source code of the entire service and all linked software available** to all users interacting with it over the network.
- **Closed-Source / Proprietary Use Prohibited**: Closed-source, commercial, or proprietary distribution without full source disclosure is **strictly prohibited** under the AGPLv3.
- **App Store Distribution Prohibited**: Inclusion in, linking against, or distribution through any App Store builds is **strictly prohibited**.

Copyright © 2026 Magesh K. All rights reserved.

Full license information can be found at [LICENSE](./LICENSE)
