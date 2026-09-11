# Packaging kIRC

RPM packaging for **kIRC**, the KDE Kirigami IRCv3 client.

Everything needed to produce a Fedora RPM lives in this directory:

| File | Purpose |
| --- | --- |
| `kirc.spec` | Fedora spec — offline-capable build (vendored cargo + vendored cxx-qt-cmake) |
| `kIRC.desktop` | Desktop entry installed to `/usr/share/applications` |
| `org.kde.kirc.metainfo.xml` | AppStream metadata installed to `/usr/share/metainfo` |
| `kirc.svg` | Source icon (Breeze-style flat speech bubble with a `#`) |
| `icons/hicolor/<size>x<size>/apps/kirc.png` | Pre-rendered hicolor PNGs (16–256 px) |
| `README.md` | This file |

The spec carries no patches: the application's own `CMakeLists.txt` already has
`install(TARGETS kIRC ...)`, so a plain `%cmake`/`%cmake_install` is enough.

## Why two vendored sources?

kIRC is a CXX-Qt hybrid, and both halves of the build normally reach the
network:

1. **CMake / cxx-qt-cmake.** `CMakeLists.txt` `FetchContent`s
   [cxx-qt-cmake](https://github.com/kdab/cxx-qt-cmake) 0.10.0 from GitHub at
   *configure* time. The spec ships it as `Source1` and passes
   `-DFETCHCONTENT_SOURCE_DIR_CXXQT=...`, which makes CMake use the unpacked
   copy and skip the download entirely.
2. **Cargo / crates.io.** The Rust workspace (`rust/Cargo.toml`) pulls
   tokio, rustls, cxx-qt and friends. The spec ships a `cargo vendor` tree as
   `Source2` and points `CARGO_HOME` at a generated config that replaces
   `crates-io` with the local directory and sets `[net] offline = true`.

With `Source1` and `Source2` in `SOURCES/`, `rpmbuild -ba` succeeds with the
network unplugged (verified locally). This is the Koji/COPR-friendly path.

## Regenerating the source tarball (Source0)

`rust/Cargo.lock` is **git-ignored**, so `git archive` alone will not include
it — but the lockfile must be shipped so the vendored build is reproducible.
Generate `Source0` from a clean checkout like this:

```sh
ver=0.1.0
# rust/Cargo.lock must exist (run `cargo generate-lockfile` in rust/ if not).
git -C /path/to/kIRC archive --format=tar HEAD | tar -x -C /tmp
mv /tmp/kirc-$(...) /tmp/kirc-$ver 2>/dev/null || true
cp /path/to/kIRC/rust/Cargo.lock /tmp/kirc-$ver/rust/Cargo.lock
# packaging/ is tracked, so it is already inside the archive.
tar -czf kirc-$ver.tar.gz -C /tmp kirc-$ver
```

(An even simpler equivalent, and what the spec's `%setup` expects, is a single
top-level `kirc-<version>/` directory containing the full tree, the lockfile
and this `packaging/` directory.)

> **Note for whoever maintains the git tree:** consider un-ignoring (committing)
> `rust/Cargo.lock`. Application crates should ship their lockfile; that would
> let `git archive` produce a complete `Source0` with no manual step. The
> `.gitignore` currently has a bare `Cargo.lock` line — removing it (or adding
> `!rust/Cargo.lock`) is a one-line change in a file this packaging work does
> not own.
>
> Suggested `.gitignore` additions for the packaging workflow (not applied —
> `.gitignore` is owned elsewhere):
>
> ```gitignore
> # Keep the application lockfile under version control (see packaging/README.md)
> !rust/Cargo.lock
> # Build inputs / generated packaging artifacts are never committed
> vendor/
> rust/vendor/
> packaging/*.tar.gz
> packaging/icons/**/*.png.orig
> ```

## Regenerating the vendor tarball (Source2)

Do this whenever the dependency set changes (i.e. whenever `Cargo.lock` is
regenerated), and always from the **same lockfile** you ship in `Source0`:

```sh
cd rust
cargo vendor vendor                 # writes rust/vendor/ + prints a config snippet
tar -czf ../kirc-vendor-0.1.0.tar.gz vendor   # top-level `vendor/` directory
```

The vendor tree is ~166 MB uncompressed / ~22 MB gzipped; it is deliberately
**not** committed to git (keep `vendor/` in `.gitignore`). It is a build input,
not source.

## Regenerating the cxx-qt-cmake tarball (Source1)

Only needed if the `GIT_TAG` in `CMakeLists.txt` changes; keep the version in
the spec's `%global cxxqt_dir` and the `Source1` filename in sync:

```sh
curl -L -o cxx-qt-cmake-0.10.0.tar.gz \
  https://github.com/kdab/cxx-qt-cmake/archive/refs/tags/0.10.0.tar.gz
```

## Regenerating the icons

`kirc.svg` is the source of truth; the PNGs are pre-rendered so the RPM build
needs no SVG rasteriser as a `BuildRequires`:

```sh
cd packaging
for s in 16 22 32 48 64 128 256; do
  mkdir -p icons/hicolor/${s}x${s}/apps
  rsvg-convert -w $s -h $s -o icons/hicolor/${s}x${s}/apps/kirc.png kirc.svg
done
```

(`rsvg-convert` comes from `librsvg2-tools`; ImageMagick's `convert` or
Inkscape work too.)

## Building locally with rpmbuild

```sh
sudo dnf install rpm-build rpmdevtools \
  gcc-c++ cmake cargo qt6-qtbase-devel qt6-qtdeclarative-devel \
  kf6-kirigami-devel kf6-kconfig-devel kf6-knotifications-devel \
  desktop-file-utils libappstream-glib
rpmdev-setuptree

cp kirc-0.1.0.tar.gz cxx-qt-cmake-0.10.0.tar.gz kirc-vendor-0.1.0.tar.gz \
   ~/rpmbuild/SOURCES/
cp kirc.spec ~/rpmbuild/SPECS/

rpmbuild -ba ~/rpmbuild/SPECS/kirc.spec
sudo dnf install ~/rpmbuild/RPMS/x86_64/kirc-0.1.0-1.fc44.x86_64.rpm
```

If you use **rustup**, make sure the build uses the *system* cargo/rustc that
the spec `BuildRequires`, not the rustup shims: `CARGO_HOME` is redirected to a
temporary directory (so a vendored build is hermetic), and a rustup `cargo` in
`PATH` cannot find its toolchain once `CARGO_HOME` is moved. Run the build with
a clean `PATH`, e.g.

```sh
env PATH=/usr/bin:/bin rpmbuild -ba ~/rpmbuild/SPECS/kirc.spec
```

`mock` does this for you; if `mock` is configured on the machine, prefer it.

## Validate the metadata

```sh
desktop-file-validate kIRC.desktop
appstream-util validate-relax org.kde.kirc.metainfo.xml
```

## COPR notes

* COPR builds run in a network-isolated chroot, so the vendored
  `Source1`/`Source2` sources are mandatory — a plain `FetchContent` /
  `crates.io` build will fail there.
* `cargo vendor` + `CARGO_HOME` works without `rust-packaging`; Fedora 44 no
  longer ships `rust-packaging`, so the spec intentionally uses plain
  `BuildRequires: cargo` and manual vendoring rather than the
  `%cargo_build`/`%generate_buildrequires` macros.
* Upload all three archives as the COPR "sources" for the package, or point
  COPR at a lookaside cache populated with them.

## Known gaps / follow-ups

* **No `LICENSE` file in the tree.** The RPM therefore has no `%license`
  payload and `rpmlint` will warn about it. The licensing is mixed
  (`GPL-2.0-or-later` for QML, `MIT OR Apache-2.0` for Rust/C++), which is why
  the spec's `License:` field is the combined SPDX expression. Adding proper
  `LICENSE`/`LICENSES/` files (e.g. reuse-tool style) to the repo root and a
  `%license` line to the spec is the clean fix.
* No man page (`rpmlint`: `no-manual-page-for-binary`).
* The desktop entry / metainfo / icons are installed by the *spec*, not by the
  application's `CMakeLists.txt`. If upstream later adds `install()` rules for
  them, drop the corresponding `%install` lines to avoid double-installing.
