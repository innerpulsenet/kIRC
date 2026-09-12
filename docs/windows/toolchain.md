# kIRC Windows port — pinned toolchain and dependency record

Recorded 2026-09-12 on the Windows development machine (Windows 11 24H2,
build 26100, x64). This is the validated Phase 1 toolchain for the Windows
port. Everything lives outside the repository on the `E:` drive and is
referenced by absolute path in build instructions.

## Native toolchain

| Component | Version | Location |
|---|---|---|
| Visual Studio 2022 Build Tools | 17.14.40 | `E:\BuildTools` |
| MSVC toolset | 14.44.35207 (`cl` x64) | `E:\BuildTools\VC\Tools\MSVC\14.44.35207` |
| Windows SDK | 10.0.26100.0 | `C:\Program Files (x86)\Windows Kits\10` (shared with VS 2026) |
| Rust | 1.98.1 (`x86_64-pc-windows-msvc`) | `%USERPROFILE%\.cargo` |
| CMake | 4.4.3 | `E:\Tools\cmake-4.4.3-windows-x86_64` |
| Ninja | 1.13.2 | `E:\Tools\ninja` |
| Git | 2.55.0.windows.3 | system |
| NASM | 2.16.03 | `E:\Tools\nasm-2.16.03` (precaution for `ring`/rustls asm builds on MSVC) |
| Python (Craft) | 3.12.10 + pip 25.0.1 | `E:\Tools\python312` (official NuGet zip; MSI installers are not used on this machine) |

Visual Studio 2026 (18.8.1) is also installed on this machine but is
deliberately NOT part of this toolchain: KDE Craft does not yet support or
test MSVC 2026, and all cached Windows packages are built with the msvc2022
ABI. Do not build any part of the stack with VS 2026.

## KDE Craft

| Setting | Value |
|---|---|
| Craft root | `E:\CraftRoot` |
| craft-core revision | master @ `fc650854d5709dae65a7c06480e0ed82e820faf4` |
| craft-blueprints-kde revision | master @ `d0e26c2ec9f1d6cac3cfea0211f6b6cf13def925` |
| ABI | `windows-cl-msvc2022-x86_64` |
| Binary cache | `https://files.kde.org/craft/Qt6/26.05/windows/cl/msvc2022/x86_64` |
| Build type | RelWithDebInfo (cache artifacts) |
| Craft Python | `E:\Tools\python312` |

Craft is invoked without sourcing `craftenv` by running, with a PATH that
does not contain Git-for-Windows `usr\bin` (Craft rejects `sh.exe` on PATH):

```
E:\Tools\python312\python.exe E:\CraftRoot\craft\bin\craft.py <packages>
```

## Qt / KF6 dependency set (installed via Craft, from the binary cache)

| Package | Version |
|---|---|
| qtbase | 6.11.1 |
| qtdeclarative (Quick/Controls/**Effects**/Layouts) | 6.11.1 |
| qtsvg / qttools / qtshadertools / qttranslations | 6.11.1 |
| Kirigami (incl. `org.kde.kirigami.layouts`) | 6.30.0 |
| KConfig | 6.30.0 |
| extra-cmake-modules | 6.30.0 |

Notable transitive dependencies delivered by the cache: dbus, glib, harfbuzz,
icu (via llvm), pcre2, freetype, libpng, cairo, brotli, zstd.

Key layout facts for builds:

- Qt prefix for `CMAKE_PREFIX_PATH`: `E:\CraftRoot`
- qmake: `E:\CraftRoot\bin\qmake.exe` (also `qmake6.exe`)
- QML import root: `E:\CraftRoot\qml` (`qmake -query QT_INSTALL_QML`);
  contains `QtQuick/Effects` (required by `GlassSurface.qml`),
  `QtQuick/Controls`, `org/kde/kirigami` and `org/kde/kirigami/layouts`
- Craft's own git (used for CMake FetchContent in sandboxed environments):
  `E:\CraftRoot\dev-utils\bin\git.exe`

## Reproducing this setup

1. Install VS2022 Build Tools (C++ workload, MSVC v143, Windows 11 SDK
   26100) to `E:\BuildTools`.
2. Unzip portable CMake + Ninja releases under `E:\Tools`.
3. Unpack the Python NuGet package (`python/<version>` from nuget.org) to
   `E:\Tools\python312` and run `python -m ensurepip --default-pip`.
4. Bootstrap Craft:
   `E:\Tools\python312\python.exe CraftBootstrap.py --prefix E:\CraftRoot --branch master --use-defaults`
   (from `https://raw.githubusercontent.com/KDE/craft/master/setup/CraftBootstrap.py`),
   then complete the shelf step:
   `craft.py --unshelve E:\CraftRoot\etc\bootstrap.shelf`.
5. Install the dependency set:
   `craft.py libs/qt6/qtbase libs/qt6/qtdeclarative libs/qt6/qtsvg kirigami kconfig extra-cmake-modules`

Blueprint names are category-qualified (`libs/qt6/qtbase`, not `qt-base`):
there are Qt5-era `libs/qt/*` blueprints with clashing short names.

## Toolchain validation status

- Rust engine suite (`cargo test --locked --manifest-path rust/core/Cargo.toml`):
  94/94 passed on this machine (2026-09-12), identical to the Linux baseline
  recorded in the port plan (50 unit + 8 API + 11 parser + 24 loopback + 1 doc).
- CXX-Qt 0.10 + Kirigami spike (MSVC + Rust staticlib + Qt 6.11.1 from Craft,
  `org.kde.kirigami` + `org.kde.kirigami.layouts` + Basic style):
  **PASS** — clean build and 6-second offscreen run verified 2026-09-12.
  One spike-only pitfall recorded: a bridge that passes only plain integers
  across the CXX boundary lets rustc dead-strip `cxx-qt-lib` from the
  staticlib while the generated initializer still calls into it
  (`LNK2019: cxx_qt_init_crate_cxx_qt_lib`); the real kIRC bridge uses
  cxx-qt-lib types (QString/QHash/QModelIndex) everywhere and is immune.
- Full kIRC application on Windows (Phase 2 platform split): builds with
  Ninja Release (MSVC 14.44, Rust 1.98.1, Qt 6.11.1/KF6 6.30.0 from Craft)
  and survives an offscreen 8-second smoke run with the real QML UI loaded
  (2026-09-12). Known environment noise in offscreen runs: Craft's Qt has no
  `lib/fonts` directory (deployment bundles fonts later).
- Windows-specific build findings recorded for future reference:
  - Craft's `clang++.exe` on PATH can hijack CMake's compiler probe under
    Ninja; the project pins `CMAKE_CXX_COMPILER` to `cl.exe` on WIN32 before
    `project()`.
  - The exe's MSVC import library (`kIRC.lib`) collides case-insensitively
    with corrosion's copied Rust staticlib (`kirc.lib`); the import library
    is redirected to a `kIRC-implib/` subdirectory.
  - Qt 6's `qt_add_resources(<target> ...)` target form has no `QRC`
    keyword: a `QRC <file>` call is silently dropped (empty `FILES` makes
    `_qt_internal_process_resource` return without error) and produces no
    resources. The embedded Windows icons therefore use target-local
    `AUTORCC` with `cpp/kirc-windows.qrc` in `target_sources()`.
- Linux build of the refactored tree: not yet re-verified on this Windows-only
  machine; covered by the RPM CI workflow when the port branch merges, and on
  this branch itself by the Linux CI workflow (`.github/workflows/linux-ci.yml`).
