//! Build script for the `kirc` CXX-Qt bridge crate.
//!
//! Responsibilities:
//!   * Run the CXX-Qt code generator over every Rust file that contains a
//!     `#[cxx_qt::bridge]` (currently only `src/bridge.rs`).
//!   * Register the `org.kde.kirc` QML module from the `*.qml` files in this
//!     crate's `qml/` directory, so QML can `import org.kde.kirc` and
//!     instantiate `IrcBridge` / `MessageListModel`.

use std::path::PathBuf;

use cxx_qt_build::{CxxQtBuilder, QResource, QResources, QmlFile, QmlModule};

/// QML files that declare `pragma Singleton` and therefore need a `singleton`
/// entry in the generated `qmldir`.
const SINGLETONS: &[&str] = &["ThemeEngine.qml"];

/// Non-QML files that QML resolves relative to itself and that must therefore
/// live in the compiled resource next to the QML files.
///
/// `Theme.js` is a `.pragma library` JS module: `ThemeEngine.qml` does
/// `import "Theme.js" as Theme`, which only resolves at runtime if the file is
/// in the same resource directory as the importing QML file.
///
/// The `themes/*.json` files are *not* shipped in the resource — the QML side
/// states it cannot read them at runtime and keeps the built-in themes inside
/// `Theme.js`.
const EXTRA_RESOURCES: &[&str] = &["qml/Theme.js"];

fn main() {
    let crate_dir =
        PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is set"));
    let qml_dir = crate_dir.join("qml");

    // ---------------------------------------------------------------------
    // QML module contents.
    //
    // The paths handed to `QmlFile` MUST be relative to this crate's
    // `Cargo.toml` and the files MUST live inside this crate: cxx-qt uses the
    // relative path verbatim as the resource alias under
    //   qrc:/qt/qml/org/kde/kirc/<relative path>
    // and rejects anything that canonicalises outside the module directory.
    //
    // => The UI lives in `rust/qml/`, NOT in a `qml/` directory at the
    //    repository root.  A file at `<repo>/qml/main.qml` cannot be wired up
    //    from here; it has to be `rust/qml/main.qml`.
    // ---------------------------------------------------------------------
    let mut qml_files: Vec<QmlFile> = Vec::new();
    match std::fs::read_dir(&qml_dir) {
        Ok(entries) => {
            let mut paths: Vec<PathBuf> = entries
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "qml"))
                .collect();
            paths.sort();

            qml_files = paths
                .into_iter()
                .map(|path| {
                    let name = path
                        .file_name()
                        .expect("QML file to have a name")
                        .to_string_lossy()
                        .into_owned();
                    let singleton = SINGLETONS.contains(&name.as_str());
                    QmlFile::from(format!("qml/{name}")).singleton(singleton)
                })
                .collect();
        }
        Err(err) => {
            println!("cargo::warning=kirc: cannot read {}: {err}", qml_dir.display());
        }
    }

    assert!(
        !qml_files.is_empty(),
        "kirc: no QML files in {} — the org.kde.kirc QML module needs at least a main.qml",
        qml_dir.display()
    );

    // Files inside the resource prefix.  `QResource`'s alias is set explicitly
    // so the resource path matches the QML file's own relative path.
    let mut resource = QResource::new().prefix("/qt/qml/org/kde/kirc");
    let mut has_extra_resources = false;
    for relative in EXTRA_RESOURCES {
        let absolute = crate_dir.join(relative);
        if absolute.is_file() {
            resource = resource.file(
                qt_build_utils::QResourceFile::new(absolute).alias((*relative).to_string()),
            );
            has_extra_resources = true;
        }
    }

    let mut builder = CxxQtBuilder::new_qml_module(
        QmlModule::new("org.kde.kirc").qml_files(qml_files),
    )
    // Qt modules the generated C++ needs in order to compile.
    .qt_module("Qml")
    .qt_module("Quick")
    .qt_module("QuickControls2")
    // Every Rust source file containing a `#[cxx_qt::bridge]`.
    .files(["src/bridge.rs"]);

    if has_extra_resources {
        builder = builder.qrc_resources(QResources::new().resource(resource));
    }

    builder.build();
}
