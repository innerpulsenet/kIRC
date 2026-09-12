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
* **Theme token completeness (stage 0, `check-theme-tokens.py`):** the token
  table in `Theme.js` (`THEME_TOKENS`) is enumerated against every
  `themes/*.json` AND every `Theme.js` builtin — a missing token, an extra
  token, a JSON/JS value drift, a stale `schema`, or a palette below the
  contrast / kind-distinguishability floors all fail the run, before any QML
  starts. This is the regression test for the "new token never reached a
  shipped theme" failure mode.
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
  palettes (every built-in theme is a dense monospace palette). Schema 4 adds
  the per-kind tokens: the smoke run asserts that every per-kind token is set
  and distinct (and that a stored config naming any built-in, legacy or
  retired id resolves to a schema-4 theme), and that the delegate renders a
  NOTICE (with the `- ` marker and the notice colour), a `/me` action (action
  colour) and a query row (private colour) from the roles alone.
* The settings theme list offers all ten built-ins and its live search finds
  the retro set by id, name and keyword (`c64`, `commodore`, `bbs`, `dial-up`,
  `dos`, `outrun`); the picker filters down to the matching theme row.

* `disconnect_server()` / `state_changed(0)` falls back to the connection form.
* Navigation: `[back]` is hidden while a session is live (it is redundant with
  Disconnect and must not offer a route out of a live session), stays offered
  on the settings pane (where it pops back to the live chat), and the
  `ensureChatVisible()` guard re-opens the chat page whenever a connect-state
  transition to "connected" finds the stack on the connection form (the tray's
  connect path can establish a session without the UI pushing ChatPage).
* Header identity + menu consolidation (p9): the window title carries the
  buffer as it is typed — `#kirc — kIRC` for a channel, no `#` for a query,
  `Server` for the console; the header shows the nick exactly once (the
  identity line `nick @ server`, with the status tag immediately beside it and
  no nick repeated inside the tag); and the single `[menu]` control holds
  exactly Search, Settings, Theme, Help, —, Disconnect, Exit — no
  `[join]`/`[settings]`/`[disconnect]`/`[theme]` controls are left in the
  header.
* Glass surfacing (`tst_glass.qml`): the ThemeEngine defaults (on / 60 / all
  sub-effects), a usable derived colour set on every built-in theme, the
  intensity clamp at both ends (0/5000 → 1/100, and `clampGlassIntensity`),
  intensity scaling the fill/blur/sheen, every main area carrying a
  `GlassSurface` with its host's theme colour, the master toggle off leaving
  host geometry and colours byte-identical (and every sheet rendering
  nothing), the sub-toggles gating their layer (frost/sheen/edges), and the
  settings round trip: control → ThemeEngine → config object, back into the
  controls (seeded off/25/off, then toggled on, slider moved to 65). It also
  proves the log's ListView and a real delegate are never *inside* a sheet.
* The KircConfig half (`glass-config-test.sh` → `tst_config_glass.cpp`,
  stage "glass-config"): defaults, clamping at both ends, the NOTIFY signals
  the QML sync binds to, a real save()/load() round trip through kirc.conf,
  and a hand-edited out-of-range value clamping on load.
* Follow-the-tail autoscroll (`tst_scroll.qml`): position-based assertions
  that the log stays pinned at the end while following — no cumulative
  drift across K live appends, including a tall wrapped row whose delegate
  height resolves after insertion — that an append never moves a
  scrolled-up view (and raises the "[ new messages ]" pill), that clicking
  the pill / a manual return / a buffer switch / a disconnect reset recover
  following, and that a real kinetic `flick()` away stops it.
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

`qml-tests/run.sh` runs a token-completeness stage (`check-theme-tokens.py`,
no QML runtime needed) and then five more stages: the UI smoke flow
(`tst_smoke.qml`), the slash-command contract (`tst_cmds.qml`), the
follow-the-tail autoscroll contract (`tst_scroll.qml`), the glass surfacing
contract (`tst_glass.qml`) and the C++ glass-config contract
(`glass-config-test.sh`, no QML runtime needed). The command stage
loads the real
`ChatPage.qml` against the recording `IrcBridge` double (`calls` / `callTrace()`,
cleared per case) and drives `runSlash()` with the lines a user types, asserting
the exact call sequence each one produces: the wire line for hand-built
commands, the bridge invokable (`send_message`, `join_channel`, `part_channel`,
`clear_buffer`, `request_history`, `mark_read`) where one exists. It also pins
`/help` (one row per command plus the header), local lines (`/echo`, usage
rejection, `/raw` newline rejection), and command tab-completion through both
`nextCompletion()` and the real composer (`tabComplete()`). Exit code 0 = every
stage passed.

## Scroll harness

`tst_scroll.qml` (third stage of `run.sh`) loads the real `ChatPage.qml` into a
sized item and drives live traffic through the real `message_received` signal,
then asserts on POSITIONS, never on appearances. The metric is the *tail gap* —
`(lastDelegate.y + lastDelegate.height) - (contentY + view.height)` — i.e. how
far the last row's bottom edge sits below the viewport bottom (0 = flush with
the end; the bug's signature is a gap that grows by a row height per message).

It proves:

1. **Following** — after opening a long buffer, eight appends each leave the
   view flush (gap ~0, never accumulating); a tall wrapped row, whose real
   height resolves a frame after insertion, also lands flush and is followed.
2. **Scrolled up** — moving the view up stops following; an append leaves
   `contentY` byte-identical and shows the `[ new messages ]` pill. A real
   kinetic `flick()` gesture away gets the same assertions.
3. **Recovery** — clicking the pill, and scrolling back to the end manually,
   both re-arm following; the next append moves the view and lands flush.
4. **Buffer switch + reset** — opening another buffer lands at the bottom with
   following re-armed (its appends follow); a disconnect resets to the server
   console and follows again; our own echo still pins and resumes following.

Settling: every assertion runs after a poll that requires `contentY`,
`contentHeight`, the view height, the row count *and* the flickable's
`moving`/`flicking` flags to be unchanged for four consecutive frames, so
deferred delegate-height resolution is included rather than raced. A watchdog
fails the run loudly instead of hanging, and a settle that never comes to rest
is itself reported as a failure.

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
`ListView.itemAtIndex()` calls the delegates made. The canned snapshot the
delegate checks run on has 12 rows (the theme-schema-4 addition: a NOTICE, a
`/me` action and a query row). `perf.sh` greps the delegate
for `itemAtIndex` call sites and instruments the throwaway copy with a counter
when any are found, so the same harness reports the pre-fix scan count (about
3.5 full view scans per delegate, i.e. O(n²)) and the current 0. It also greps
the glass constraint (p8): `MessageDelegate.qml` must contain **zero**
`MultiEffect`/`ShaderEffect` nodes and `GlassSurface.qml` must contain **zero**
`ListView`/`itemAtIndex` references, so a blur can never capture the scrolling
view — the gate fails the run if either drifts. It also checks
the model-computed `isEvent`/`isError`/`showDay`/`dayLabel` roles reach the
delegate — including a failing `473 ...` row rendered warn-coloured with a `!`
marker next to a dim MOTD row — that no delegate exposes the removed grouping
machinery, and that wrapped rows render from those roles. Exit code 0 = all
checks passed. The numbers it produced are
recorded in `.hermes/implementation/p3-render.md` (and `p2-perf.md` for the
incremental path).
