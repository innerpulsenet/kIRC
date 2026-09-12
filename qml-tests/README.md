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
* Slash commands: `tst_cmds.qml` (second stage of `run.sh`) drives the real
  dispatcher with the exact lines a user types and asserts the recorded bridge
  calls — one wire line per command, `/help` output, local lines, malformed
  argument rejection, and command tab-completion. `/version` with no argument
  is asserted as the server `VERSION` command; `/version <nick>` as the CTCP
  `VERSION` query (`send_message(<nick>, \x01VERSION\x01)`) plus the local
  "CTCP VERSION query sent to <nick>" line; `/ctcp <target> <message>` is
  unchanged.
* Filling the form and pressing Connect calls `bridge.connect_server(...)` and
  pushes `ChatPage`. The window hands the persisted CTCP VERSION auto-reply
  preference (`respondToCtcpVersion`, config double's default `true`) to the
  bridge BEFORE `connect_server`, and again on the reconnect path — the call
  order is asserted on the recording bridge double, so a drop can never
  silently revert to the bridge default.
* Messages arrive as `message_received` / `history_batch_received`, the model is
  reloaded, and `MessageDelegate` is created **from the model roles** (this is
  the check that catches role-name drift on the C++ side).
* CTCP lines render legibly: a CTCP VERSION request/reply seeded as the core
  writes it (event row, nick `"*"`) renders through the event path — `* `-marked,
  dim body (never the chat colour), no nick column, no hover state — with the
  remote client's string visible in the reply. An ordinary chat row is asserted
  as the contrast case.
* The settings pane's CTCP VERSION toggle (Connection section) exists, mirrors
  the persisted value, hides with its section, carries the "client name and
  version" hint and persists a change back through its config.
* The delegate renders one dense console line per row (no bubbles, no avatars,
  no grouping): every row is its own line and the highlight / self roles map
  through. Grouping (`continuesPrevious` / `continuesNext`, neighbour lookups,
  `settle()`) was removed with the bubbles — `tst_perf.qml` proves no delegate
  scans the view any more.
* Switching to `amber` and back to `tui` repaints the log in the terminal
  palettes (every built-in theme is a dense monospace palette).
* `disconnect_server()` / `state_changed(0)` falls back to the connection form.
* Theme engine units: built-in loading (the `tui` default and the rest of the
  terminal palettes), retired-id aliases (`oxygen`/`neon`/… resolve to `tui`),
  unknown-id errors, malformed JSON does not clobber the active theme, partial
  JSON merges over defaults, out-of-range knobs are clamped, nick-colour
  determinism/range/distinctness, dark-vs-light variance, the padded nick
  column, the font-family override, HTML escaping, linkifying, accent-tinted
  links and luminance detection.

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

## Command harness

`qml-tests/run.sh` runs two stages: the UI smoke flow (`tst_smoke.qml`) and the
slash-command contract (`tst_cmds.qml`). The command stage loads the real
`ChatPage.qml` against the recording `IrcBridge` double (`calls` / `callTrace()`,
cleared per case) and drives `runSlash()` with the lines a user types, asserting
the exact call sequence each one produces: the wire line for hand-built
commands, the bridge invokable (`send_message`, `join_channel`, `part_channel`,
`clear_buffer`, `request_history`, `mark_read`) where one exists. It also pins
`/help` (one row per command plus the header), local lines (`/echo`, usage
rejection, `/raw` newline rejection), and command tab-completion through both
`nextCompletion()` and the real composer (`tabComplete()`). Exit code 0 = every
stage passed.

## Perf harness

`qml-tests/perf.sh` runs `tst_perf.qml` through the same stub module and measures
the incremental message path: it loads a synthetic 2000-row transcript, then
compares N full `load_channel` reloads (what a live message used to trigger)
against N `append_message` inserts, counting the model's real
`rowsInserted` / `rowsRemoved` / `modelReset` emissions and the wall-clock cost
of each path. It also pins down `append_message`'s contract (no-op for a
non-loaded buffer, case-insensitive target match, correct insert into an empty
model and after a reload).

The same run exercises the render side — the channel-switch pause. A tall
`ListView` hosts the real `MessageDelegate` over a second model instance, every
row of a 500-row transcript is instantiated, and the harness reports the
wall-clock cost of `load_channel` + full delegate creation and the number of
`ListView.itemAtIndex()` calls the delegates made. `perf.sh` greps the delegate
for `itemAtIndex` call sites and instruments the throwaway copy with a counter
when any are found, so the same harness reports the pre-fix scan count (about
3.5 full view scans per delegate, i.e. O(n²)) and the current 0. It also checks
the model-computed `isEvent`/`isError`/`showDay`/`dayLabel` roles reach the
delegate — including a failing `473 ...` row rendered warn-coloured with a `!`
marker next to a dim MOTD row — that no delegate exposes the removed grouping
machinery, and that wrapped rows render from those roles. Exit code 0 = all
checks passed. The numbers it produced are
recorded in `.hermes/implementation/p3-render.md` (and `p2-perf.md` for the
incremental path).
