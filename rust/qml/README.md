# kIRC QML UI (`org.kde.kirc`)

Kirigami 6 / Qt 6 QML front end for kIRC. Everything here is pure QML/JS — no
IRC logic, no sockets, no file I/O. The Rust side owns protocol state and
exposes it through two cxx-qt QML elements; this module renders it.

## Files

| File | Purpose |
| --- | --- |
| `main.qml` | `Kirigami.ApplicationWindow`. Owns the single `IrcBridge` instance, the page stack (Connect → Chat), the header (connection state / nick / unread / theme menu) and app-wide bridge signal handling. |
| `ConnectPage.qml` | Connection form: host, port, TLS, nickname, optional SASL user/password. Emits `connectRequested(...)`; it never calls the bridge itself. |
| `ChatPage.qml` | Channel sidebar (hardcoded `#kirc` + joins), message `ListView` bound to `MessageListModel`, status strip, message input. |
| `MessageDelegate.qml` | One message, dual mode (dense IRC line / bubble). Highlighted messages get an accent stripe; own messages are right-aligned in bubble mode. |
| `ThemeEngine.qml` | `pragma Singleton` theme manager: active theme, flat bindable properties, `applyThemeJson()`, deterministic nick colours, text escaping/linkifying. |
| `Theme.js` | `.pragma library` — theme data (built-ins + defaults), djb2 hashing, HSL derivation, HTML escaping/linkifying. No Qt globals available here. |
| `themes/*.json` | Built-in themes: `breeze.json`, `oxygen.json`, `neon.json`. Canonical schema (see below). |
| `qmldir` | Module registration for `qmllint`/`qmlls` and for the `ThemeEngine` singleton. |

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
   (`12:34` / `12:34:56`). The UI does no date formatting.
3. **`is_self` echoes**: `send_message()` is not locally echoed by the QML side.
   The bridge is expected to re-emit what the user sent through
   `message_received(target, nick, text, true, ...)`.
4. **Connectivity**: `ChatPage` reloads the channel when `state_changed(2)`
   arrives and falls back to `ConnectPage` on `state_changed(0)`.
5. **Not in the contract yet (guarded/TODO in QML)**: a `join_channel(target)`
   invokable (called defensively via `typeof bridge.join_channel === "function"`)
   and a channel join/part signal to drive the sidebar. Until then the sidebar
   starts with `#kirc` and appends whatever the user types in the join field.

## Theme engine

`themes/*.json` is the user-facing schema. The C++ side reads theme files and
pushes them into the singleton; QML itself cannot touch the filesystem.

```qml
// load ~/.config/kIRC/themes/mytheme.json (C++), then:
ThemeEngine.applyThemeJson(rawJsonText)   // or a parsed object
ThemeEngine.applyBuiltinTheme("neon")     // "breeze-dark-default" | "oxygen" | "neon"
ThemeEngine.reset()
```

`applyThemeJson()` never throws: bad JSON or a non-object returns an error
string and leaves the active theme untouched (`ThemeEngine.configError`).
Missing keys fall back to the defaults; unknown keys are preserved.

Built-in themes are compiled into `Theme.js` (QML cannot read
`qml/themes/*.json` at runtime), so a change to the JSON must be mirrored
there — and vice versa. The JSON files stay the documented schema.

### Schema

```json
{
    "id": "breeze-dark-default",
    "name": "Breeze Dark",
    "mode": "dense",
    "bubble": {
        "radius": 8,
        "spacing": 4,
        "selfColor": "",
        "otherColor": ""
    },
    "dense": { "lineSpacing": 2 },
    "fonts": { "messageSize": 0, "timestampSize": 0 },
    "colors": {
        "nickSatMin": 0.55,
        "nickSatMax": 0.70,
        "nickLightnessDark": 0.62,
        "nickLightnessLight": 0.35,
        "linkify": true,
        "highlightIsBold": true
    }
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `id` | string | `"breeze-dark-default"` | Stable identifier; also what `ThemeEngine.themeId` exposes. |
| `name` | string | `"Breeze Dark"` | Human label (theme menu). |
| `mode` | `"dense"` \| `"bubble"` | `"dense"` | Anything else falls back to `dense`. Drives `MessageDelegate.styleMode`. |
| `bubble.radius` | number | `8` | Bubble corner radius (px). |
| `bubble.spacing` | number | `4` | Vertical gap between messages in bubble mode. |
| `bubble.selfColor` | string | `""` | Own-message bubble background. Empty = `Kirigami.Theme.highlightColor` (keeps the KDE palette coherent). |
| `bubble.otherColor` | string | `""` | Others' bubble background. Empty = `Kirigami.Theme.alternateBackgroundColor`. |
| `dense.lineSpacing` | number | `2` | Vertical gap between lines in dense mode. |
| `fonts.messageSize` | int | `0` | Absolute point size for message text. `0` (or negative) = inherit `Kirigami.Theme.defaultFont.pointSize`. |
| `fonts.timestampSize` | int | `0` | Same, for timestamps. |
| `colors.nickSatMin` | number 0–1 | `0.55` | Lower bound of the nick-colour saturation range. |
| `colors.nickSatMax` | number 0–1 | `0.70` | Upper bound (swapped automatically if `max < min`). |
| `colors.nickLightnessDark` | number 0–1 | `0.62` | Nick lightness on dark backgrounds. Baseline in the code is `0.45`; the shipped themes brighten it for readability. |
| `colors.nickLightnessLight` | number 0–1 | `0.35` | Nick lightness on light backgrounds. |
| `colors.linkify` | bool | `true` | Wrap `http(s)://…` in anchors. **No link previews are ever fetched** — QML makes no network requests. HTML in messages is always escaped first, so `<b>` renders literally. |
| `colors.highlightIsBold` | bool | `true` | Bold text for highlight (nick mention) messages. |

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

Custom themes are applied by the C++ side; to make them appear in the window's
theme menu, extend `ThemeEngine.availableThemeIds` (the menu builds itself from
that list via an `Instantiator` and calls `ThemeEngine.applyBuiltinTheme(id)`).

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
* **`pageStack.push()` warning**: on Qt 6.11 the runtime logs
  `Created graphical object was not placed in the graphics scene` when a page is
  added with `Kirigami.PageRow.push()`. It is a Kirigami/Qt artifact — a bare
  `Kirigami.Page` pushed the same way reproduces it — and it is purely cosmetic.
  Pages set as `initialPage` do not trigger it.
* **Import style**: `org.kde.kirc` is *not* imported in these files. Sibling
  components in the same module are resolved directly; importing the module from
  inside itself is unnecessary and makes `qmllint` unhappy.
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

Current status: **zero warnings/errors** for all five files (Qt 6.11.2).

Without the doubles the expected output is `IrcBridge was not found` /
`MessageListModel was not found` plus unresolved-type noise — that is the module
being built elsewhere, not a defect in these files.

`qml-tests/` (outside this module directory, so it is never compiled into it)
contains a real runtime smoke test with doubles for `IrcBridge` and
`MessageListModel`; `qml-tests/run.sh` builds the stub module and runs it
headless. It exercises connect → chat → delegate creation → theme switch →
disconnect and unit-checks the theme engine.

> `qml-tests/` is development tooling only. Exclude it from the CMake target
> (or delete it) when wiring the build.
