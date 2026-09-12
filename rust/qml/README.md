# kIRC QML UI (`org.kde.kirc`)

Kirigami 6 / Qt 6 QML front end for kIRC. Everything here is pure QML/JS — no
IRC logic, no sockets, no file I/O. The Rust side owns protocol state and
exposes it through two cxx-qt QML elements; this module renders it.

The look is deliberately *retro terminal*: monospace everywhere, one line per
message with a fixed time gutter and a padded nick column, flat square
surfaces, box-drawing rules, no avatars and no bubbles. Dense IRC rendering is
the only rendering (`mode` is always `dense`).

## Files

| File | Purpose |
| --- | --- |
| `main.qml` | `Kirigami.ApplicationWindow`. Owns the single `IrcBridge` instance, the single-column page stack (Connect → Chat), the custom header (context glyph + title, status pill, unread badge, nick chip, flat menu buttons) and app-wide bridge signal handling. |
| `ConnectPage.qml` | Hero connect card: app glyph, headline, labelled rounded fields with in-field icons, TLS and SASL switches (the SASL block animates open), wide accent Connect button with an in-flight spinner, inline error hint fed by `error_occurred`. Emits `connectRequested(...)`; it never calls the bridge to connect. |
| `ChatPage.qml` | Rounded sidebar (server entry + channel list with hash tiles, section headers, active pill, fit field), message `ListView` bound to `MessageListModel` with an empty-state placeholder and a slim overlay scrollbar, and the composer with its integrated accent send button. |
| `MessageDelegate.qml` | One message as a console line: fixed `[HH:MM]` gutter, nick column, dim `* …` events, day rules, accent highlight bar. Colours by kind via the model roles (`isEvent`/`isError`/`isPrivate`/`isNotice`/`isAction`/`isHighlight`/`isSelf`), never by inspecting the view. No bubbles, no grouping, no hover. |
| `GlassSurface.qml` | One reusable frosted-glass surface: translucency, a reflection sheen, a lit edge, grain and depth. Used by every chrome area (header, sidebar, log container, composer, people panel, pill, dialogs). Never blurs a scrolling view. |
| `ScanlineOverlay.qml` | The CRT effect layers above the whole window: scanlines, vignette, grain, flicker, hum bar and reflection, each behind its own `Loader` so an off effect costs no nodes. Parented to the window root (a page's `contentItem` cannot paint over the header). No shaders and never a `ShaderEffectSource` over the log. |
| `ThemeEngine.qml` | `pragma Singleton` theme manager: active theme, flat bindable properties, `applyThemeJson()`, `applyBuiltinTheme()`, deterministic nick colours, avatar/link/alpha helpers, text escaping/linkifying, grouping helpers. |
| `Theme.js` | `.pragma library` — theme data (built-ins + defaults), djb2 hashing, HSL derivation, message grouping maths, HTML escaping/linkifying. No Qt globals available here. |
| `themes/*.json` | Built-in themes: `tui.json` (the default), `bbs.json`, `c64.json`, `vt.json`, `ega.json`, `synthwave.json`, `ai-slop.json`, `crt.json`, `paper.json`, `gruvbox.json`, `phosphor.json`, `amber.json`, `ice.json`, `breeze.json`. Canonical schema (see below). |
| `qmldir` | Module registration for `qmllint`/`qmlls` and for the `ThemeEngine` singleton. |

`Theme.js` is the *only* JS module shipped next to the QML (see
`EXTRA_RESOURCES` in `rust/build.rs`), so every shared JS helper lives there —
adding another `.js` file would silently break the runtime resource lookup.

## Bridge contract consumed here

cxx-qt keeps **snake_case** ids in QML, so the names below are used verbatim.

```qml
IrcBridge {
    property int    connection_state   // 0 = Disconnected, 1 = Connecting, 2 = Connected
    property int    unread_count
    property string nickname
    property string connected_server

    // timestamp is the preformatted "HH:MM" string the log shows verbatim
    // (the same string the model's row carries).
    signal message_received(string target, string nick, string text, string timestamp, bool is_self, bool is_highlight)
    signal history_batch_received(string target)
    signal state_changed(int state)
    signal notification_fired(string title, string body)
    signal info(string text)
    signal error_occurred(string message)

    function connect_server(host, port, tls, nickname, sasl_user, sasl_pass)
    function disconnect_server()
    function send_message(target, text)
    function request_history(target, limit)
}

MessageListModel {          // QAbstractListModel
    // roleNames() MUST be exactly: nick, text, timestamp, isSelf, isHighlight
    function load_channel(target)                     // full reload (buffer switch / history batch)
    function append_message(target, nick, text, timestamp, is_self, is_highlight)
                                                      // one rowsInserted, only for the loaded buffer
}
```

### Hard requirements from the C++ side

1. **`MessageListModel` role names must be exactly**
   `nick`, `text`, `timestamp`, `isSelf`, `isHighlight` (that exact casing).
   `MessageDelegate` declares them as `required property`, which is how QML
   views initialise delegate properties from model roles. A mismatch makes
   delegate creation fail loudly (`Required property ... was not initialized`)
   instead of rendering blank rows.
2. **`timestamp` is displayed as-is** — send a preformatted local-time string
   (`12:34` / `12:34:56`). The UI does no date formatting; it only *parses* the
   string to decide whether two messages belong to one group (see below).
3. **`is_self` echoes**: `send_message()` is not locally echoed by the QML side.
   The bridge is expected to re-emit what the user sent through
   `message_received(target, nick, text, true, ...)`.
4. **Connectivity**: `ChatPage` reloads the channel when `state_changed(2)`
   arrives and falls back to `ConnectPage` on `state_changed(0)`.
5. **Not in the contract yet (guarded/TODO in QML)**: a `join_channel(target)`
   invokable (called defensively via `typeof bridge.join_channel === "function"`)
   and a channel join/part signal to drive the sidebar. Until then the sidebar
   starts with `#kirc` and appends whatever the user types in the join field.

## Layout notes

* **One page at a time.** `pageStack.defaultColumnWidth` is pinned to the
  window width so `Kirigami.PageRow` never shows the connection form next to the
  chat log, and `pageStack.globalToolBar.style` is `None` because the window
  draws its own header (otherwise PageRow adds a second toolbar underneath it).
* **The sidebar does not use `index`.** It renders `page.buffers`, a derived JS
  array whose entries already carry `target`, `isServer`, `sectionTitle` and
  `sectionStart`, so the delegate never has to look at a neighbouring row.
* **No delegate reads `index`.** On Qt 6.11 a delegate cannot read its own row
  position: a declared `required property int index` stays `undefined` both
  inside the delegate and from outside, and `onIndexChanged` cannot be declared
  for it. `MessageDelegate` therefore resolves its position by identity
  (`viewIndex()` scans `ListView.itemAtIndex()` for itself) and reacts to
  recycling through the role change signals, which are available.

## Message grouping

Dense rendering shows one line per message, so nothing is merged: the grouping
helpers survive for the harnesses and for the day-boundary maths, but the
delegate does not hide a repeated sender any more.

* A group continues while the next row has the same nick (case-insensitive),
  the same `isSelf` side, and a timestamp no more than
  `grouping.windowMinutes` later.
* Only time-of-day is available, so a timestamp that goes *backwards* (a day
  rollover) and any unparseable timestamp end the group. A wrong avatar is
  worse than a duplicated one.
* Grouping is computed once per delegate (creation + role changes), never per
  frame, and never from a per-frame JS loop.

## Compose box

`Enter` sends, `Shift+Enter` inserts a newline. The field grows with the
content up to `5` lines (`FontMetrics.lineSpacing`) and then scrolls. It is
disabled, with a "connect first" placeholder, while the bridge is not in state
2. Sending is not echoed locally (see contract note 3).

## Effects (global, not themed)

Display effects are a property of the **window**, not of a palette, so they live in KConfig
`[UI]` rather than in `themes/*.json` — which is why adding them needed no theme-schema bump.
They come in two families and are controlled from the `[effects]` toolbar popup (one
`[*]`/`[ ]` toggle each) with the per-effect amounts in the Settings Effects section:

| Family | Effects | Keys |
| --- | --- | --- |
| Glass | frost/blur, sheen, edges, reflection | `GlassEffects`, `GlassIntensity`, `GlassBlur`, `GlassSheen`, `GlassEdges`, `Reflection`, `ReflectionAmount` |
| CRT | scanlines, vignette, grain, flicker, hum bar | `Scanlines`, `Vignette`, `Grain`, `Flicker`, `HumBar` (+ `*Amount` 1..100 each) |

Glass is on by default; every other effect defaults off, since an effect that sits over text
should be opt-in. Toggling a glass row while the master is off turns the master on, so no row
in the popup is ever a dead toggle. The `crt` theme is the palette *designed to pair with* the
scanline effect rather than one that switches it on.

Two rules decide whether an effect ships at all. It must need **no shader and no capture of the
content** — a static tile, one animated rectangle, or an opacity animation; a
`ShaderEffectSource` over the scrolling log is the performance trap this codebase has paid for
twice, and `qml-tests/perf.sh` is what keeps it out. And with every effect off the window must
be pixel-identical to a build without them.

## Theme engine

`themes/*.json` is the user-facing schema. The C++ side reads theme files and
pushes them into the singleton; QML itself cannot touch the filesystem.

```qml
// load ~/.config/kIRC/themes/mytheme.json (C++), then:
ThemeEngine.applyThemeJson(rawJsonText)   // or a parsed object
ThemeEngine.applyBuiltinTheme("tui")      // "tui" | "bbs" | "c64" | "vt" | "ega"
                                          // | "synthwave" | "ai-slop" | "crt"
                                          // | "paper" | "gruvbox" | "phosphor"
                                          // | "amber" | "ice" | "breeze"
ThemeEngine.reset()
```

`applyThemeJson()` never throws: bad JSON or a non-object returns an error
string and leaves the active theme untouched (`ThemeEngine.configError`).
Missing keys fall back to the defaults, unknown keys are preserved, and the
numeric knobs are clamped to sane ranges so a bad theme file cannot make the
chat view unreadable — a theme file written against the old bubble schema
still loads, it just inherits the dense geometry.

### Terminal look (schema 4)

Bubbles are cancelled: the output is a console. Every built-in theme is
`mode: "dense"` — one monospace line per message with a fixed `[HH:MM]` time
gutter, a padded nick column and flat surfaces. `ThemeEngine.mode` can never
return `"bubble"` any more (the merge coerces it), and the delegate has no
bubble branch.

| Id | Look |
| --- | --- |
| `tui` | **default** — near-black log, grey text, cyan accent |
| `bbs` | dial-up board: ANSI lime, grey and cyan on black |
| `c64` | Commodore 64: light blue on the VIC-II blue |
| `vt` | DEC-style phosphor, yellow-green |
| `ega` | grey on black with DOS-blue panels |
| `synthwave` | neon pink and cyan on deep purple |
| `ai-slop` | self-aware neon indigo — indigo field (cooled away from `synthwave`'s purple), lavender-white text, electric blue-violet accent. Neon magenta is reserved for actions, highlights and the unread badge, so it accents the window instead of tinting the field |
| `crt` | colour CRT: near-black tube, warm off-white text, worn NTSC colour-bar accents (yellow, cyan, green, magenta, red, blue pulled slightly toward each other). The theme the scanline filter was asked for — it *pairs* with that effect, it does not carry it (see below) |
| `paper` | **the only light theme** — teletype paper and two-colour ribbon ink: warm off-white field, near-black text, ribbon red for failures, ribbon blue for NOTICEs |
| `gruvbox` | warm dark brown and cream with the palette's signature orange, red, yellow and aqua |
| `phosphor` | green on black (P1 tube) |
| `amber` | amber on black (classic CRT) |
| `ice` | cold light-on-blue |
| `breeze` | dense geometry with **empty colour tokens**: every colour follows `Kirigami.Theme`, so it matches Breeze Light / Breeze Dark / a custom scheme |

**CRT scanlines are not a theme token.** The scanline / vignette amount is a
global `[UI]` setting (read from KConfig and drawn by the window-wide scanline
overlay), not part of this schema — a theme no longer describes it. `crt` is
the palette built to *pair* with that effect rather than a theme that switches
it on, and it is the only theme tuned with the overlay in mind (its off-white
text and worn colour bars are what survive a scanline pass).

**Per-kind colour (schema 4).** Seven `terminal.*` tokens — `fgEvent`,
`fgMessage`, `fgPrivate`, `fgNotice`, `fgAction`, `fgHighlight`, `fgSelf` —
let a theme colour each kind of line separately, so a notice, a private
message and a channel line are all distinguishable at a glance. The delegate
picks one by precedence `error > event > highlight > notice > action >
private > self > channel`, branching on **model roles only**: it never
inspects the view, and `qml-tests/perf.sh` asserts it has zero `itemAtIndex`
call sites, which is what fixed the channel-switch stall. `breeze` leaves all
seven empty and follows `Kirigami.Theme` per kind instead.

Schema 3 added `[UI] FontFamily` (a monospace family; empty = the theme's
own default) and `[UI] ThemeSchemaVersion` is now **4**. `KircConfig::load()`
migrates a config below version 4 exactly once: ids that used to be built-in
bubble/glass themes (`breeze`, `breeze-classic`, `oxygen`, `neon`, `fluent`,
`fluent-light`) are rewritten to `tui` — including a config already stamped
version 2, which is how the phase-2 `oxygen` config finally migrated — while
any other id, whether a user's own theme file or a current built-in such as
`bbs`, is left alone with only the version stamped. The bump matters even
though the migration is a no-op for current ids: without it a config stamped
at an older version would never re-examine the new token set. Retired ids
also alias to `tui` at runtime, so a stale config can never leave the window
unstyled.

`qml-tests/check-theme-tokens.py` (stage 0 of `qml-tests/run.sh`) enumerates
the token table against every theme file and fails on a missing **or extra**
token, a JSON-to-`Theme.js` drift, a stale schema stamp, or contrast/ΔE below
the floors. A theme that ships a token the engine reads but never defines is
silent and ugly, so the gate exists to make it loud.

Built-in themes are compiled into `Theme.js` (QML cannot read
`qml/themes/*.json` at runtime), so a change to the JSON must be mirrored
there — and vice versa. The JSON files stay the documented schema. The legacy
id `breeze-dark-default` is still accepted and resolves to `breeze`.

### Schema

```json
{
    "id": "tui",
    "name": "TUI",
    "mode": "dense",
    "bubble": { "radius": 0, "spacing": 0, "groupSpacing": 0, "tailRadius": 0,
                "maxWidthFraction": 1.0, "selfColor": "", "otherColor": "" },
    "dense": { "lineSpacing": 2 },
    "avatar": { "enabled": false, "size": 0 },
    "grouping": { "enabled": true, "windowMinutes": 5 },
    "motion": { "enabled": true, "duration": 90 },
    "sidebar": { "width": 0 },
    "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
    "colors": {
        "nickSatMin": 0.50,
        "nickSatMax": 0.80,
        "nickLightnessDark": 0.70,
        "nickLightnessLight": 0.34,
        "linkify": true,
        "highlightIsBold": true,
        "linkColor": ""
    },
    "surfaces": {
        "surface": "#0b0d0f", "surfaceAlt": "#101417", "sidebarSurface": "#0e1215",
        "cardBackground": "#101417", "cardBorder": "#262e34",
        "cardRadius": 0, "cardPadding": 8, "rowRadius": 0,
        "rowHover": "#171d22", "rowSelected": "#1e272e", "rowHeight": 24,
        "accent": "#4cc9dd", "accentText": "#0b0d0f", "mutedText": "#7c858c",
        "sectionHeader": "#7c858c", "sectionHeaderSize": 0,
        "eventText": "#7c858c", "eventSize": 0,
        "statusOnline": "#63c47a", "statusAway": "#d8b25e", "statusOffline": "#6d757b",
        "unreadBadge": "#4cc9dd", "unreadBadgeText": "#0b0d0f",
        "inputRadius": 0, "shadowOpacity": 0, "headerHeight": 40
    },
    "terminal": {
        "fontFamily": "monospace",
        "gutterWidth": 64,
        "nickColumn": 9,
        "ruleColor": "#2b3238",
        "fgPrimary": "#c9ced3",
        "fgDim": "#7c858c",
        "fgAccent": "#4cc9dd",
        "fgWarn": "#ff6b5f",
        "bgPanel": "#101417",
        "bgLog": "#0b0d0f",
        "bgInput": "#0e1215"
    }
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `id` | string | `"tui"` | Stable identifier; also what `ThemeEngine.themeId` exposes. |
| `name` | string | `"TUI"` | Human label (theme menu). |
| `mode` | string | `"dense"` | Frozen to dense; anything else (including `"bubble"`) is coerced. |
| `terminal.fontFamily` | string | `"monospace"` | Monospace family for every surface. The user's `[UI] FontFamily` overrides it (`ThemeEngine.fontFamilyOverride`). |
| `terminal.gutterWidth` | number | `64` | Fixed px width of the `[HH:MM]` time gutter; `0` = derive from the font metrics (`ThemeEngine.resolveGutterWidth()`). |
| `terminal.nickColumn` | number | `9` | Characters to pad the nick to (`ThemeEngine.paddedNick(nick)`); the nick column itself. `0` = no padding. |
| `terminal.ruleColor` | color | `"#2b3238"` | Box-drawing / separator rules. |
| `terminal.fgPrimary` | color | `"#c9ced3"` | Main text. |
| `terminal.fgDim` | color | `"#7c858c"` | Timestamps, events, secondary text. |
| `terminal.fgAccent` | color | `"#4cc9dd"` | Highlights, selection marker, prompt. |
| `terminal.fgWarn` | color | `"#ff6b5f"` | Errors, join failures, disconnects. |
| `terminal.bgPanel` | color | `"#101417"` | Sidebar / people panel surface. |
| `terminal.bgLog` | color | `"#0b0d0f"` | Message log surface (and the page background). |
| `terminal.bgInput` | color | `"#0e1215"` | Input bar / field surface. |
| `dense.lineSpacing` | number | `2` | Extra gap between lines. |
| `bubble.*` | — | flat | Legacy bubble knobs. Kept, clamped, and never rendered (no bubble branch exists); old theme files must still load. |
| `avatar.enabled` | bool | `false` | Avatars are gone with the bubbles; kept so old files load. |
| `grouping.*` | — | `true` / `5` | Kept for the harness helpers; dense rendering shows one line per message. |
| `motion.enabled` | bool | `true` | Allow the UI's short transitions. |
| `motion.duration` | number | `90` | Base transition length (ms); `0` disables animation. |
| `sidebar.width` | number | `0` | Sidebar width in px. `0` = `Kirigami.Units.gridUnit * 13`. |
| `fonts.messageSize` | int | `0` | Absolute point size for message text. `0` (or negative) = inherit `Kirigami.Theme.defaultFont.pointSize`. |
| `fonts.timestampSize` | int | `0` | Same, for timestamps (default inherits one point smaller). |
| `fonts.nickSize` | int | `0` | Same, for the sender name. |
| `colors.nickSatMin` | number 0–1 | `0.55` | Lower bound of the nick-colour saturation range. |
| `colors.nickSatMax` | number 0–1 | `0.70` | Upper bound (swapped automatically if `max < min`). |
| `colors.nickLightnessDark` | number 0–1 | `0.62` | Nick lightness on dark backgrounds. |
| `colors.nickLightnessLight` | number 0–1 | `0.35` | Nick lightness on light backgrounds. |
| `colors.linkify` | bool | `true` | Wrap `http(s)://…` in anchors. **No link previews are ever fetched** — QML makes no network requests. HTML in messages is always escaped first, so `<b>` renders literally. |
| `colors.highlightIsBold` | bool | `true` | Bold text for highlight (nick mention) messages. |
| `colors.linkColor` | string | `""` | Link colour. Empty = `Kirigami.Theme.highlightColor`, baked into the rich-text anchor so it works on every widget. |

### Nick colours

Deterministic, no state: `hue = djb2(nick.toLowerCase()) % 360`, saturation
drawn deterministically from `[nickSatMin, nickSatMax]`, lightness picked from
`nickLightnessDark` / `nickLightnessLight` depending on whether
`Kirigami.Theme.backgroundColor` is dark (luminance < 0.5). Returned as
`Qt.hsla(...)`, so it follows the colour scheme automatically:

```qml
readonly property bool darkTheme: ThemeEngine.isDark(Kirigami.Theme.backgroundColor)
readonly property color nickColor: ThemeEngine.nickColor(nick, darkTheme)
```

Avatar circles went away with the bubbles; `ThemeEngine.initial(nick)` and
`ThemeEngine.contrastingTextColor(color)` stay because the channel tiles and
the person panel still draw a glyph with them.

Other helpers used across the UI: `ThemeEngine.withAlpha(color, a)`,
`ThemeEngine.cssColor(color)` → `"#rrggbb"` (for rich text),
`ThemeEngine.avatarSizeFor(gridUnit)`, `ThemeEngine.sidebarWidthFor(gridUnit)`,
`ThemeEngine.formatMessage(text, linkCss)`, `ThemeEngine.paddedNick(nick)`,
`ThemeEngine.monospaceFamilies()` (the settings font-family list).

Every terminal token has a resolver that takes the caller's `Kirigami.Theme`
fallback, so a theme with empty colours (`breeze`) still follows the desktop:
`ThemeEngine.fgPrimaryColor(fallback)`, `fgDimColor`, `fgAccentColor`,
`fgWarnColor`, `bgPanelColor`, `bgLogColor`, `bgInputColor`, `ruleColorValue`,
`resolveGutterWidth(fallback)`.

Custom themes are applied by the C++ side; to make them appear in the window's
theme menu, extend `ThemeEngine.availableThemeIds` (the menu builds itself from
that list via an `Instantiator` and calls `ThemeEngine.applyBuiltinTheme(id)`).

## Colours

Every colour comes from `Kirigami.Theme` (accent / text / disabled / alternate
background / highlighted text) or is derived from one with `withAlpha`, so the
UI is correct in Breeze Light and Breeze Dark. Verified by screenshotting the
harness twice with `XDG_CONFIG_HOME` pointing at a `kdeglobals` that selects
`BreezeDark` / `BreezeLight`.

> Screenshot harness gotcha: without a window manager the window is never
> *active*, and Kirigami then swaps `Kirigami.Theme.highlightColor` for its
> dimmed inactive variant — every accent element looks wrong. Run the harness
> under `openbox` (or any WM) inside Xvfb before trusting a screenshot.

## Configuration persistence

Deliberately **not** implemented in QML. Connection fields are plain,
session-only values; last-host/nick/SASL are meant to be persisted by the C++
side in `~/.config/kIRC/kirc.conf` (KConfig) and pushed back into `ConnectPage`
through its `host` / `port` / `tls` / `nickname` / `saslUser` / `saslPass`
aliases. `Kirigami.Settings` is intentionally not used.

## Notes / known issues

* **Code blocks**: syntax highlighting is out of scope for this pass — see the
  `TODO(code-highlight)` markers in `ChatPage.qml` / `MessageDelegate.qml`.
  It needs a `KSyntaxHighlighting` bridge on the C++ side.
* **`index` is unreadable in delegates** (Qt 6.11): see "Layout notes". The
  grouping therefore has one soft edge — when a group is cut by the top of the
  viewport, the first *visible* row of that group draws its avatar, because
  `ListView.itemAtIndex()` only reports instantiated rows.
* **`pageStack.push()` warning**: on Qt 6.11 the runtime logs
  `Created graphical object was not placed in the graphics scene` when a page is
  added with `Kirigami.PageRow.push()`. It is a Kirigami/Qt artifact — a bare
  `Kirigami.Page` pushed the same way reproduces it — and it is purely cosmetic.
  Pages set as `initialPage` do not trigger it.
* **Import style**: `org.kde.kirc` *is* imported in `main.qml`/`ChatPage.qml`
  (they use the `ThemeEngine` singleton and the `IrcBridge` type).
* `ChatPage.qml`, `MessageDelegate.qml` and `main.qml` use
  `pragma ComponentBehavior: Bound`.

## Validating

`qmllint` needs the cxx-qt types to resolve. It uses the `qmldir` of the
directory the file lives in, which shadows anything passed with `-I`, so lint a
copy of the module that also contains the test doubles:

```sh
tmp=$(mktemp -d); mkdir -p "$tmp/org/kde/kirc"
cp qml/*.qml qml/Theme.js "$tmp/org/kde/kirc/"
cp qml-tests/IrcBridge.qml qml-tests/MessageListModel.qml "$tmp/org/kde/kirc/"
printf 'module org.kde.kirc\nsingleton ThemeEngine 1.0 ThemeEngine.qml\nIrcBridge 1.0 IrcBridge.qml\nMessageListModel 1.0 MessageListModel.qml\nConnectPage 1.0 ConnectPage.qml\nChatPage 1.0 ChatPage.qml\nMessageDelegate 1.0 MessageDelegate.qml\n' \
    > "$tmp/org/kde/kirc/qmldir"
cd "$tmp/org/kde/kirc"
qmllint main.qml ConnectPage.qml ChatPage.qml MessageDelegate.qml ThemeEngine.qml
```

`main.qml` reports two `unqualified` **infos** on the `typeof kircConfig` /
`typeof kircTray` probes — those names are C++ context properties by design
(the guards are what make the window work in harnesses), so the hints are
expected and the exit status is 0.

`qml-tests/` (outside this module directory, so it is never compiled into it)
contains a real runtime smoke test with doubles for `IrcBridge` and
`MessageListModel`; `qml-tests/run.sh` builds the stub module and runs it
headless. It exercises connect → chat → delegate creation → terminal theme switches →
disconnect, and unit-checks the theme engine (terminal tokens, retired-id
migration aliases, clamping, font-family override).

> `qml-tests/` is development tooling only. Exclude it from the CMake target
> (or delete it) when wiring the build.
