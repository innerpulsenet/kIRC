# kIRC licensing

kIRC is a mixed-license project; the license follows the layer:

| Layer | Path | License |
|---|---|---|
| QML UI | `rust/qml/**` | GPL-2.0-or-later (per file SPDX headers) |
| C++ shell | `cpp/**` | MIT OR Apache-2.0 |
| CXX-Qt bridge crate | `rust/src/**`, `rust/Cargo.toml`, `rust/build.rs` | MIT OR Apache-2.0 |
| Protocol engine crate | `rust/core/**` | MIT OR Apache-2.0 |
| Build orchestration | `CMakeLists.txt` | MIT OR Apache-2.0 |
| Packaging | `packaging/**` | MIT OR Apache-2.0 |

Consequently the combined binary is distributed under:
`GPL-2.0-or-later AND MIT AND Apache-2.0` (as recorded in `packaging/kirc.spec`).

Full license texts for MIT and Apache-2.0 are available at
https://opensource.org/license/mit and
https://www.apache.org/licenses/LICENSE-2.0; the GPL-2.0 text at
https://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
