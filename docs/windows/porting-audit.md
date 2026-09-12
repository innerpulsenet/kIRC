# kIRC Windows port — Linux-API audit (line-level)

Audit of branch `codex/windows-port` at commit `0378144` (identical to
`main`). Produced 2026-09-12 as input for the platform-backend refactor.
Scope: all of `cpp/`, `CMakeLists.txt`, `rust/` build files, QML tests,
packaging, CI. No files were modified by the audit.

Summary: there are exactly **four** Linux/KDE-only seams in the codebase —
KWallet (config secrets), KStatusNotifierItem + QDBus (tray), KNotification
(notifications), and build-system/packaging assumptions. No POSIX headers
(`unistd.h`, `sys/*`, `pthread`) and no `getenv`/`QProcess` appear anywhere
in `cpp/`. KConfig itself is portable and is kept for the Windows port.

## 1. Build-system Linux assumptions

| Location | Item | Windows problem | Fix direction |
|---|---|---|---|
| `CMakeLists.txt:32` | `find_package(Qt6 ... DBus ...)` | Qt DBus only used by the tray probe | Gate the component + link on the Linux backend |
| `CMakeLists.txt:49,57-65` | `find_package(KF6 ... Notifications StatusNotifierItem Wallet)` with `REQUIRED` fallbacks | Guaranteed configure failure on Windows | Per-platform component selection; fail clearly, not silently |
| `CMakeLists.txt:131,136-138` | links `Qt6::DBus`, `KF6::Notifications`, `KF6::StatusNotifierItem`, `KF6::Wallet` | Link failure once sources are guarded | Conditional link lists per backend |
| `CMakeLists.txt:78-87` | FetchContent of cxx-qt-cmake 0.10.0 (brings Corrosion) | Needs git on PATH at configure | Works; note for CI images |
| `CMakeLists.txt:91-94` | `find_program(KIRC_QMAKE_EXECUTABLE NAMES qmake6 qmake)` | Can pick an incompatible Qt; qmake usually not on PATH on Windows | Accept a cache/`-D` override; prefer Qt's imported location; print resolved path |
| `CMakeLists.txt:149` | install `cpp/kIRC.notifyrc` → `${DATADIR}/knotifications6` | Freedesktop-only | `if(UNIX)` guard |
| `CMakeLists.txt:155-162` | install `.desktop`, AppStream metainfo, hicolor icons | XDG-only | `if(UNIX)` guard; Windows uses embedded `.ico`/`.rc` instead |
| `.github/workflows/rpm-release.yml` (whole file) | Fedora container, dnf deps, rpmbuild, FHS path verification | No Windows leg | Add separate Windows jobs (engine, app build, package smoke) per port plan |
| `qml-tests/run.sh:16-44`, `perf.sh:23,58-76` | sh, `mktemp -d`, `/usr/lib64/qt6/bin/qml`, `QML2_IMPORT_PATH`, offscreen | Unix-only orchestration and Fedora paths | Portable Python runner + CTest targets |
| `qml-tests/glass-config-test.sh:16-39` | `moc6`/`g++`/`pkg-config`, `-I/usr/include/KF6`, `XDG_CONFIG_HOME`/null-D-Bus isolation | None exist on Windows | Build `tst_config_glass.cpp` via CMake AUTOMOC + injected config path (the C++ itself is portable) |
| `packaging/set-version.sh` | bash + GNU sed specifics | Release-versioning flow is Unix-only | Portable Python implementation with shell wrapper |
| `packaging/kirc.spec`, `packaging/kIRC.desktop`, metainfo | RPM/XDG metadata | Linux-only | Keep for Linux; Windows uses `.rc` version resource + NSIS |

## 2. C++ platform seams (backend-extraction surface)

### 2a. `cpp/kircconfig.{h,cpp}` — KConfig + KWallet

KWallet constants: folder `"kIRC"`, keys `"nickserv-password"`,
`"server-password"` (`kircconfig.cpp:21-23`). Helpers:
`openKircWallet()` `:81-100` (synchronous `openWallet(LocalWallet(), 0,
Synchronous)` + folder setup), `walletReadPassword()` `:102-116`,
`walletWritePassword()` `:118-127`, `walletRemovePassword()` `:129-139`.

Wallet side effects (important for the Windows secrets backend):
- `load()`: reads `nickserv-password` `:941-948` (legacy `[Services]
  Password` fallback for one-time migration), reads `server-password`
  `:951-955`.
- `save()`: legacy plaintext scrub `services.deleteEntry("Password")`
  `:1067`; NickServ secret write-or-remove `:1068-1072`; server PASS
  write-or-remove `:1074-1078`. **Every QML `save()` call is a wallet-write
  trigger** (call sites: `main.qml:307,575,945,1625`,
  `SettingsPage.qml:698,1179`, `ChatPage.qml:3241,3259`).

QML-facing surface: context property `kircConfig` (`main.cpp:71`), ~40
`Q_PROPERTY`s (`kircconfig.h:67-111`), `save()`/`load()` slots. The
documented contract for the secrets backend is at `kircconfig.h:44-52`
(locked/unavailable → keep in memory, never plaintext).

Config path: `configFilePath()` `kircconfig.cpp:148-156` =
`QStandardPaths::GenericConfigLocation` + `/kIRC/kirc.conf` → on Windows
`%APPDATA%\kIRC\kirc.conf`. `KConfig(path, SimpleConfig)` `:818,:1009`
means no registry, no org mangling; INI schema (`[Connection]/[UI]/
[Services]`, constants `:16-31`) stays byte-identical if KConfig is kept.

### 2b. `cpp/kirctray.{h,cpp}` — KStatusNotifierItem + QDBus

D-Bus watcher: service `org.kde.StatusNotifierWatcher` `:43-45`;
`QDBusServiceWatcher` on sessionBus for registration/unregistration
`:112-118`; `refreshAvailability()` probes
`IsStatusNotifierHostRegistered` `:130-153` → feeds `Q_PROPERTY bool
available` (`kirctray.h:35`, consumed by `main.qml:143,539-545` to gate
hide-to-tray and recovery).

KStatusNotifierItem API used: ctor(title) `:79`, `setCategory(Communications)`
`:80`, `setStatus(Active|NeedsAttention)` `:81,204,208`, `setIconByName`
`:85`, `setTitle` `:86`, `setToolTip` `:87,228`,
`setStandardActionsEnabled(false)` `:91`, `contextMenu()` + QAction wiring
`:93-108`, `setOverlayIconByPixmap` badge `:203,207` (badge pixmap drawn at
`:48-71`, 22px), `setAssociatedWindow` `:163`.

Bridge wiring is string-based meta-object calls: `SIGNAL(unread_countChanged())`
/ `SIGNAL(state_changed(int))` `:173-174`; property reads
`connection_state`/`unread_count`/`connected_server` `:199-217`;
`invokeMethod` of `set_sasl_mechanism`, `set_server_password`,
`set_ctcp_version_reply`, `connect_server`, `disconnect_server` `:281-330`.
Public slots: `onShowHide/onConnect/onDisconnect/onQuit` (`kirctray.h:54-60`);
`attach(window, bridge)` called from `main.cpp:137`.

A `QSystemTrayIcon` Windows backend must reproduce: `available` semantics,
context menu + state enabling, composite unread badge (no overlay API on
QSystemTrayIcon — draw into the base pixmap), tooltip, activation →
show/restore, and the same meta-object bridge contract so shared action
logic stays identical.

### 2c. `cpp/kircnotify.{h,cpp}` — KNotification

Event id `"message"` (`:22`, declared in `cpp/kIRC.notifyrc:6`), icon
`"kirc"` with theme fallback `:23-24`, component `"kIRC"` `:25` (matches
`applicationName` `main.cpp:37`, which is what resolves `kIRC.notifyrc`).
`messageEventIsConfigured()` probes
`knotifications6/kIRC.notifyrc` via `QStandardPaths::locate` `:38,56`; if
absent it falls back to the generic event `:77-84`. Entry point: slot
`notify(QString,QString)` `kircnotify.h:30`, connected in `main.cpp:126-129`
to the bridge's string-based `SIGNAL(notification_fired(QString, QString))`
(declared `rust/src/bridge.rs:505`, emitted `:1086`).

Windows replacement keeps the same `notify()` slot; eligibility logic stays
in the Rust bridge.

### 2d. `cpp/main.cpp` — assembly point

Startup order: org/app/version naming `:35-38`; window icon via theme with
embedded fallback `:47-51`; `setDesktopFileName` `:54`; **style
`org.kde.desktop` `:58`** (requires `qqc2-desktop-style` — must become
platform-conditional); `KircConfig::load()` `:62-63`; `KircTray` ctor `:68`;
context properties `kircConfig`/`kircTray` `:71-72`; warning pump `:75-83`;
qrc `main.qml` load `:85-96`; ThemeEngine font override injection
`:105-110`; bridge lookup by `objectName == "ircBridge"` `:116-119`;
notifier connect `:121-129`; `tray.attach` `:137`.

## 3. Unix APIs / paths (tests, docs, scripts only)

- `cpp/kircnotify.cpp:38,56` — `.notifyrc` lookup will never exist on
  Windows → always the fallback branch; shimmed away with 2c.
- Doc comments still describe `~/.config` (`kircconfig.h:31`,
  `rust/qml/README.md:153,371`) — update when Windows paths land.
- `cpp/kIRC.notifyrc:3` — `DesktopEntry=org.kde.kIRC` vs installed
  `kIRC.desktop`: pre-existing Linux-side inconsistency, harmless.
- `cpp/main.cpp:54` — `setDesktopFileName("kIRC")` is a harmless no-op on
  Windows.
- No runtime user-theme loading exists; themes are baked into `Theme.js`
  (`rust/build.rs:24-27` — the JSON files are dev mirrors only).

## 4. Already portable — do not churn

- **Rust core** (`rust/core`): no `std::os::unix`, no libc;
  `unix_now()` is `std::time`-based (`session.rs:1680-1681`);
  `rustls-native-certs 0.8` reads the Windows certificate store natively.
- **Rust bridge** (`rust/src/bridge.rs`): no Unix APIs/env/fs; tokio
  multi-thread `:191-196`; Qt-thread hop via `cxx_qt::Threading`.
- **Rust build** (`rust/build.rs`): env/fs via portable `std` only;
  forward-slash qrc aliases are correct regardless of OS.
- **Cargo**: `staticlib` links under MSVC via cxx-qt. `rustls` `ring`
  feature: engine suite compiled and passed on the Windows box without
  extra steps; NASM 2.16.03 is installed at `E:\Tools\nasm-2.16.03` as a
  precaution for `ring` builds.
- **QML UI**: no Linux paths/D-Bus/X11; context-property access is guarded
  so the UI loads with or without the C++ integrations; hide-to-tray keys
  off `trayAvailable`.
- **Fonts**: no font files loaded; default family is the `monospace`
  generic (`ThemeEngine.qml:100-102`, `Theme.js` passim); picker filters
  `Qt.fontFamilies()` and already includes `Cascadia Mono` and
  `Courier New` (`ThemeEngine.qml:341-366`); unknown stored families are
  preserved (`:361-364`). Cosmetic follow-up: add `Consolas` to the list.
- **KConfig schema**: all group/key constants and round-trips
  (`kircconfig.cpp:16-31, 820-892, 1011-1078`) are a platform-neutral INI
  contract.
- **`qml-tests/tst_config_glass.cpp`**: portable Qt-only test logic; only
  its shell wrapper is Linux-specific.
