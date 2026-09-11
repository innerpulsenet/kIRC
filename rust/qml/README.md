# kIRC QML UI (`org.kde.kirc`)

Kirigami 6 / Qt 6 QML front end for kIRC. Everything here is pure QML/JS — no
IRC logic, no sockets, no file I/O. The Rust side owns protocol state and
exposes it through two cxx-qt QML elements; this module renders it.

The look is deliberately *modern chat client* (NeoChat/Telegram territory,
themed with Breeze) rather than retro IRC: nick-coloured avatars, message
grouping, rounded bubbles with the sender's own accent on the right, a rounded
card sidebar and a floating composer.

## Files

| File | Purpose |
| --- | --- |
| `main.qml` | `Kirigami.ApplicationWindow`. Owns the single `IrcBridge` instance, the single-column page stack (Connect → Chat), the custom header (context glyph + title, status pill, unread badge, nick chip, flat menu buttons) and app-wide bridge signal handling. |
| `ConnectPage.qml` | Hero connect card: app glyph, headline, labelled rounded fields with in-field icons, TLS and SASL switches (the SASL block animates open), wide accent Connect button with an in-flight spinner, inline error hint fed by `error_occurred`. Emits `connectRequested(...)`; it never calls the bridge to connect. |
| `ChatPage.qml` | Rounded sidebar (server entry + channel list with hash tiles, section headers, active pill, fit field), message `ListView` bound to `MessageListModel` with an empty-state placeholder and a slim overlay scrollbar, and the composer with its integrated accent send button. |
| `MessageDelegate.qml` | One message. Bubble mode (default) with avatar, name, grouped consecutive messages, highlight wash + accent bar, links tinted with the accent; dense mode (classic one-line IRC log) is the secondary style. |
| `ThemeEngine.qml` | `pragma Singleton` theme manager: active theme, flat bindable properties, `applyThemeJson()`, `applyBuiltinTheme()`, deterministic nick colours, avatar/link/alpha helpers, text escaping/linkifying, grouping helpers. |
| `Theme.js` | `.pragma library` — theme data (built-ins + defaults), djb2 hashing, HSL derivation, message grouping maths, HTML escaping/linkifying. No Qt globals available here. |
| `themes/*.json` | Built-in themes: `breeze.json` (the default), `breeze-classic.json`, `oxygen.json`, `neon.json`. Canonical schema (see below). |
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

    signal message_received(string target, string nick, string text, bool is_self, bool is_highlight)
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
    function load_channel(target)
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

Consecutive messages from the same sender are merged into one visual group:
one avatar and one name, tighter spacing, and the bubble corner facing the
neighbour flattened (the "connected tail").

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

## Theme engine

`themes/*.json` is the user-facing schema. The C++ side reads theme files and
pushes them into the singleton; QML itself cannot touch the filesystem.

```qml
// load ~/.config/kIRC/themes/mytheme.json (C++), then:
ThemeEngine.applyThemeJson(rawJsonText)   // or a parsed object
ThemeEngine.applyBuiltinTheme("breeze")   // "breeze" | "breeze-classic" | "oxygen" | "neon"
ThemeEngine.reset()
```

`applyThemeJson()` never throws: bad JSON or a non-object returns an error
string and leaves the active theme untouched (`ThemeEngine.configError`).
Missing keys fall back to the defaults, unknown keys are preserved, and the
numeric knobs are clamped to sane ranges so a bad theme file cannot make the
chat view unreadable.

Built-in themes are compiled into `Theme.js` (QML cannot read
`qml/themes/*.json` at runtime), so a change to the JSON must be mirrored
there — and vice versa. The JSON files stay the documented schema. The legacy
id `breeze-dark-default` is still accepted and resolves to `breeze`.

### Schema

```json
{
    "id": "breeze",
    "name": "Breeze",
    "mode": "bubble",
    "bubble": {
        "radius": 12,
        "spacing": 6,
        "groupSpacing": 2,
        "tailRadius": 5,
        "maxWidthFraction": 0.78,
        "selfColor": "",
        "otherColor": ""
    },
    "dense": { "lineSpacing": 3 },
    "avatar": { "enabled": true, "size": 0 },
    "grouping": { "enabled": true, "windowMinutes": 5 },
    "motion": { "enabled": true, "duration": 140 },
    "sidebar": { "width": 0 },
    "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
    "colors": {
        "nickSatMin": 0.55,
        "nickSatMax": 0.70,
        "nickLightnessDark": 0.62,
        "nickLightnessLight": 0.35,
        "linkify": true,
        "highlightIsBold": true,
        "linkColor": ""
    }
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `id` | string | `"breeze"` | Stable identifier; also what `ThemeEngine.themeId` exposes. |
| `name` | string | `"Breeze"` | Human label (theme menu). |
| `mode` | `"bubble"` \| `"dense"` | `"bubble"` | Anything else falls back to `bubble`. Drives `MessageDelegate.styleMode`. |
| `bubble.radius` | number | `12` | Bubble corner radius (px), clamped 0–64. |
| `bubble.spacing` | number | `6` | Vertical gap between *groups*, clamped 0–64. |
| `bubble.groupSpacing` | number | `2` | Vertical gap *inside* a group, clamped 0–64. |
| `bubble.tailRadius` | number | `5` | Radius of the corner(s) joined to a grouped neighbour, clamped 0–64. |
| `bubble.maxWidthFraction` | number | `0.78` | Widest a bubble may get, as a fraction of the log width, clamped 0.3–1.0. |
| `bubble.selfColor` | string | `""` | Own-message bubble background. Empty = `Kirigami.Theme.highlightColor` (keeps the KDE palette coherent, and inverts correctly with the colour scheme). |
| `bubble.otherColor` | string | `""` | Others' bubble background. Empty = `Kirigami.Theme.alternateBackgroundColor`. |
| `dense.lineSpacing` | number | `3` | Extra gap between lines in dense mode. |
| `avatar.enabled` | bool | `true` | Show nick-coloured initial avatars (`false` for the dense/classic themes). |
| `avatar.size` | number | `0` | Avatar diameter in px. `0` = derived from `Kirigami.Units.gridUnit` (~1.9×). |
| `grouping.enabled` | bool | `true` | Merge consecutive same-sender messages. |
| `grouping.windowMinutes` | number | `5` | Longest gap (minutes) that still counts as one group. |
| `motion.enabled` | bool | `true` | Allow the UI's short transitions. |
| `motion.duration` | number | `140` | Base transition length (ms); `0` disables animation. |
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

### Nick colours and avatars

Deterministic, no state: `hue = djb2(nick.toLowerCase()) % 360`, saturation
drawn deterministically from `[nickSatMin, nickSatMax]`, lightness picked from
`nickLightnessDark` / `nickLightnessLight` depending on whether
`Kirigami.Theme.backgroundColor` is dark (luminance < 0.5). Returned as
`Qt.hsla(...)`, so it follows the colour scheme automatically:

```qml
readonly property bool darkTheme: ThemeEngine.isDark(Kirigami.Theme.backgroundColor)
readonly property color nickColor: ThemeEngine.nickColor(nick, darkTheme)
```

The avatar circle painted from that colour uses
`ThemeEngine.contrastingTextColor(color)` for its initial, so the letter stays
readable in both schemes. `ThemeEngine.initial(nick)` returns the first
letter/uppercase digit (or `"?"`).

Other helpers used across the UI: `ThemeEngine.withAlpha(color, a)`,
`ThemeEngine.cssColor(color)` → `"#rrggbb"` (for rich text),
`ThemeEngine.avatarSizeFor(gridUnit)`, `ThemeEngine.sidebarWidthFor(gridUnit)`,
`ThemeEngine.formatMessage(text, linkCss)`.

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
headless. It exercises connect → chat → delegate creation → grouping → dense
theme switch → bubble theme switch → disconnect, and unit-checks the theme
engine (including the grouping window).

> `qml-tests/` is development tooling only. Exclude it from the CMake target
> (or delete it) when wiring the build.
