# qml-tests — development-only harness

Not part of the `org.kde.kirc` QML module. **Exclude it from the CMake target
(or delete the directory) when wiring the build.**

The C++/cxx-qt side of the module does not exist in a standalone QML runtime, so
`qmllint` and the QML runtime cannot resolve `IrcBridge` / `MessageListModel`.
This directory supplies test doubles with the exact contract (same ids, same
snake_case names) and a headless smoke test that drives the real `qml/` files.

```sh
qml-tests/run.sh          # headless (offscreen), exit 0 = all checks passed
QPA=xcb qml-tests/run.sh  # actually watch it run
```

What it covers:

* `main.qml` instantiates; the page stack starts on `ConnectPage`; header state
  text follows `connection_state`.
* Filling the form and pressing Connect calls `bridge.connect_server(...)` and
  pushes `ChatPage`.
* Messages arrive as `message_received` / `history_batch_received`, the model is
  reloaded, and `MessageDelegate` is created **from the model roles** (this is
  the check that catches role-name drift on the C++ side).
* The delegate defaults to bubble mode, maps the highlight / self roles, and
  **groups two consecutive messages from the same nick** — the neighbour's
  `continuesNext` and the follower's `continuesPrevious` must both be set
  (regression guard: this silently failed while the delegate resolved its row
  position through the view's `index`, which Qt 6.11 does not expose).
* Switching to `breeze-classic` flips the delegate to dense rendering, switching
  to `neon` flips it back to bubble.
* `disconnect_server()` / `state_changed(0)` falls back to the connection form.
* Theme engine units: built-in loading (bubble default, dense classic, neon),
  the legacy `breeze-dark-default` id alias, unknown-id errors, malformed JSON
  does not clobber the active theme, partial JSON merges over defaults,
  out-of-range knobs are clamped, nick-colour determinism/range/distinctness,
  dark-vs-light variance, avatar initial / contrasting colour / grid-derived
  sizes, the grouping window (including day rollover and unparseable
  timestamps), HTML escaping, linkifying, accent-tinted links and luminance
  detection.

Caveats:

* `console.log`/`print` output is dropped by the `qml` runtime here, so the
  harness reports through `console.error` and `QT_FORCE_STDERR_LOGGING=1`.
* `Kirigami.PageRow.push()` logs
  `Created graphical object was not placed in the graphics scene` on Qt 6.11.
  It is a Kirigami/Qt artifact (a bare `Kirigami.Page` pushed by URL reproduces
  it) and is unrelated to this UI's code.
* The doubles are intentionally *not* the screenshot-harness doubles: these rows
  are the minimal set the assertions need. The richer visual harness lives
  outside the repository (it never ships).
