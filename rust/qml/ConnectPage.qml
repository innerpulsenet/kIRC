// SPDX-License-Identifier: GPL-2.0-or-later
//
// ConnectPage — first-run / reconnect form, terminal style.
//
// Flat fields on the input surface, square corners, monospace labels in a
// fixed column so the controls line up; no rounded hero card, no icon circles.
//
// Pure UI: it never touches IrcBridge itself. It emits connectRequested() and
// main.qml calls the bridge. It *does* listen to `error_occurred` so a failed
// attempt shows an inline hint right where the user is looking.
//
// The fields are prefilled from the persisted profile through the `kircConfig`
// context property (a KircConfig, see cpp/kircconfig.cpp).  That property only
// exists in the real application: standalone/offline harnesses instantiate
// this page without it, so the prefill is guarded on null and the page keeps
// working with its built-in defaults.
//
// LAYOUT NOTE: the form must never be positioned against its direct `parent`.
// Inside a ScrollView that parent is the flickable's *content item*, whose
// width is the content's own implicit width (a couple of hundred pixels), so
// centring a ~500px form in it put the form at a negative x and clipped every
// label and field off the left edge.  The layout below therefore sizes an
// explicit viewport item from the ScrollView itself and anchors the form
// inside that, with no absolute coordinates.

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

import org.kde.kirc

// Delegates reference the page's properties; bound component behaviour
// resolves those statically instead of through the dynamic context.
pragma ComponentBehavior: Bound

Kirigami.Page {
    id: page

    // Set by main.qml. Only used to reflect connection state (e.g. disable
    // the button while a connection attempt is in flight); all actions go out
    // through the connectRequested signal.
    property var bridge: null

    // Persisted connection profile (KircConfig). Null in standalone harnesses.
    property var kircConfig: null

    property alias host: hostField.text
    property alias nickname: nickField.text
    property alias tls: tlsSwitch.checked
    property alias port: portField.text           // kept as text: unvalidated user input
    property alias saslEnabled: saslSwitch.checked
    property alias saslUser: saslUserField.text
    property alias saslPass: saslPassField.text

    // SASL mechanism id, same mapping as IrcBridge::set_sasl_mechanism and
    // KircConfig.saslMechanism: 0 = Auto, 1 = PLAIN, 2 = EXTERNAL.
    // (SCRAM-SHA-256-only is "Auto".)
    property int saslMechanism: 0

    function saslMechanismLabel(id)
    {
        switch (id) {
        case 1: return qsTr("PLAIN")
        case 2: return qsTr("EXTERNAL (client certificate)")
        }
        return qsTr("Auto")
    }

    // Last error pushed by the bridge, shown as an inline hint until the user
    // tries again.
    property string lastError: ""

    readonly property int parsedPort: {
        var p = parseInt(portField.text, 10)
        return isNaN(p) ? 0 : p
    }
    readonly property bool connecting: page.bridge !== null && page.bridge.connection_state === 1
    readonly property bool formValid: hostField.text.length > 0
                                      && nickField.text.length > 0
                                      && parsedPort > 0 && parsedPort <= 65535
                                      && (!saslSwitch.checked || saslUserField.text.length > 0)

    // --- terminal type scale + colours (theme tokens, Kirigami fallbacks) ---
    readonly property string mono: ThemeEngine.fontFamily
    readonly property int pt: Math.max(7, Kirigami.Theme.defaultFont.pointSize)
    readonly property int ptSmall: Math.max(7, page.pt - 1)
    readonly property int labelCol: Math.round(Kirigami.Units.gridUnit * 7)
    readonly property int rowGap: Math.round(Kirigami.Units.gridUnit * 1.6)

    function fgMain() { return ThemeEngine.fgPrimaryColor(Kirigami.Theme.textColor) }
    function fgDim() { return ThemeEngine.fgDimColor(Kirigami.Theme.disabledTextColor) }
    function fgAccent() { return ThemeEngine.fgAccentColor(Kirigami.Theme.highlightColor) }
    function fgWarn() { return ThemeEngine.fgWarnColor(Kirigami.Theme.negativeTextColor) }
    function bgLogC() { return ThemeEngine.bgLogColor(Kirigami.Theme.backgroundColor) }
    function bgPanelC() { return ThemeEngine.bgPanelColor(Kirigami.Theme.alternateBackgroundColor) }
    function bgInputC() { return ThemeEngine.bgInputColor(Kirigami.Theme.alternateBackgroundColor) }
    function ruleC() { return ThemeEngine.ruleColorValue(ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.20)) }
    function selC() { return ThemeEngine.rowSelectedColor(ThemeEngine.withAlpha(Kirigami.Theme.highlightColor, 0.20)) }
    function hoverC() { return ThemeEngine.rowHoverColor(ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.07)) }

    signal connectRequested(string host, int port, bool tls, string nickname, string saslUser, string saslPass, int saslMechanism)

    Connections {
        target: page.bridge

        function onError_occurred(message) {
            page.lastError = message
        }
    }

    title: qsTr("Connect to IRC")

    // The terminal surface owns its own margins.
    padding: 0

    // Page surface: the theme's log colour. A theme with empty colours
    // (`breeze`) falls back to the desktop background, so it still matches the
    // user's scheme; the fixed palettes stop floating on a white page.
    background: Rectangle {
        color: page.bgLogC()
    }

    // ---------------------------------------------------------------------- //
    // Inline components — flat, monospace, square. (A nested Repeater inside a
    // control's custom contentItem SIGSEGVs Qt 6.11; these keep it plain.)
    // ---------------------------------------------------------------------- //

    component TermLabel: Text {
        Layout.preferredWidth: page.labelCol
        Layout.alignment: Qt.AlignVCenter
        color: page.fgDim()
        font.family: page.mono
        font.pointSize: page.ptSmall
        elide: Text.ElideRight
    }

    component TermField: Controls.TextField {
        id: termField

        Layout.fillWidth: true
        font.family: page.mono
        font.pointSize: page.ptSmall
        color: page.fgMain()
        placeholderTextColor: page.fgDim()
        selectionColor: page.fgAccent()
        selectedTextColor: page.bgLogC()
        leftPadding: 6
        rightPadding: 6

        background: Rectangle {
            implicitWidth: 100
            implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.6)
            radius: 0
            color: page.bgInputC()
            border.width: 1
            border.color: termField.activeFocus ? page.fgAccent() : page.ruleC()
        }
    }

    component TermToggle: Controls.CheckBox {
        id: termToggle

        Layout.fillWidth: true
        font.family: page.mono
        font.pointSize: page.ptSmall
        spacing: 8
        rightPadding: 0

        indicator: Text {
            x: termToggle.leftPadding
            y: termToggle.topPadding + (termToggle.availableHeight - height) / 2
            text: termToggle.checked ? "[x]" : "[ ]"
            color: termToggle.checked ? page.fgAccent() : page.fgDim()
            font.family: page.mono
            font.pointSize: page.ptSmall
        }

        contentItem: Text {
            leftPadding: termToggle.leftPadding + termToggle.indicator.width + termToggle.spacing
            text: termToggle.text
            color: termToggle.enabled ? page.fgMain() : page.fgDim()
            font.family: page.mono
            font.pointSize: page.ptSmall
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }

    component TermButton: Controls.Button {
        id: termButton

        property string prompt: ""

        font.family: page.mono
        font.pointSize: page.ptSmall
        implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.6)
        implicitWidth: contentItem.implicitWidth + 16
        text: termButton.prompt

        background: Rectangle {
            radius: 0
            color: termButton.down ? page.selC() : (termButton.hovered ? page.hoverC() : page.bgInputC())
            border.width: 1
            border.color: termButton.enabled ? page.ruleC() : page.bgInputC()
        }

        contentItem: Text {
            text: termButton.text
            color: termButton.enabled ? page.fgMain() : page.fgDim()
            font.family: page.mono
            font.pointSize: page.ptSmall
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    /// Flat square combo box.  The text and the arrow are drawn inside the flat
    /// background on purpose: the desktop style draws a non-editable combo's
    /// text in its StyleItem background, and its contentItem (an invisible
    /// TextField) is what the style's mobile-cursor binding targets — replacing
    /// either used to log a TypeError and hide the selected text.
    component TermCombo: Controls.ComboBox {
        id: termCombo

        font.family: page.mono
        font.pointSize: page.ptSmall

        background: Rectangle {
            implicitWidth: 80
            implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.6)
            radius: 0
            color: page.bgInputC()
            border.width: 1
            border.color: (termCombo.activeFocus || termCombo.popup.visible) ? page.fgAccent() : page.ruleC()

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 6
                anchors.right: comboArrow.left
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                text: termCombo.displayText
                color: page.fgMain()
                font.family: page.mono
                font.pointSize: page.ptSmall
                elide: Text.ElideRight
            }

            Text {
                id: comboArrow
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: "▾"
                color: page.fgDim()
                font.family: page.mono
                font.pointSize: page.ptSmall
            }
        }

        delegate: Controls.ItemDelegate {
            id: termComboItem

            required property var modelData
            required property int index

            width: termCombo.width
            highlighted: termCombo.highlightedIndex === termComboItem.index

            contentItem: Text {
                leftPadding: 6
                text: page.saslMechanismLabel(termComboItem.modelData)
                color: page.fgMain()
                font.family: page.mono
                font.pointSize: page.ptSmall
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }

            background: Rectangle {
                radius: 0
                color: termComboItem.highlighted ? page.selC() : page.bgInputC()
            }
        }
    }

    // Prefill from the persisted profile once every field exists.  The SASL
    // password is never persisted (see cpp/kircconfig.h), so it stays empty.
    Component.onCompleted: {
        if (page.kircConfig === null || page.kircConfig === undefined) {
            return
        }
        var cfg = page.kircConfig
        if (cfg.host.length > 0) {
            page.host = cfg.host
        }
        if (cfg.port > 0 && cfg.port <= 65535) {
            page.port = String(cfg.port)
        }
        page.tls = cfg.tls
        if (cfg.nickname.length > 0) {
            page.nickname = cfg.nickname
        }
        if (cfg.saslUser.length > 0) {
            page.saslEnabled = true
            page.saslUser = cfg.saslUser
        }
        if (cfg.saslMechanism !== undefined && cfg.saslMechanism >= 0 && cfg.saslMechanism <= 2) {
            page.saslMechanism = cfg.saslMechanism
        }
    }

    Controls.ScrollView {
        id: scroll
        anchors.fill: parent
        // Vertical scrolling only: the form is width-constrained below, so
        // there is nothing to scroll horizontally.
        contentWidth: availableWidth
        Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff

        // Sizes itself from the ScrollView (i.e. the real viewport) rather
        // than from the flickable's content item — see the layout note above.
        Item {
            id: viewport
            width: scroll.availableWidth
            implicitHeight: form.implicitHeight + Kirigami.Units.largeSpacing * 2
            height: form.implicitHeight + Kirigami.Units.largeSpacing * 2

            ColumnLayout {
                id: form
                // Capped for readability, but never wider than the viewport,
                // so the centring below can never push the form off-screen.
                width: Math.min(viewport.width, Kirigami.Units.gridUnit * 26)
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6

                Item { Layout.preferredHeight: Kirigami.Units.largeSpacing }

                // ---------------- header ----------------
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    spacing: 0

                    Text {
                        text: "── " + qsTr("connect") + " "
                        color: page.fgAccent()
                        font.family: page.mono
                        font.pointSize: page.ptSmall
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        implicitHeight: 1
                        color: page.ruleC()
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    Layout.bottomMargin: 4
                    text: qsTr("TLS, SASL and IRCv3 included")
                    color: page.fgDim()
                    font.family: page.mono
                    font.pointSize: page.ptSmall
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                // ---------------- host ----------------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    TermLabel {
                        text: qsTr("host:")
                    }

                    TermField {
                        id: hostField
                        text: "irc.libera.chat"
                        placeholderText: qsTr("irc.example.org")
                        onAccepted: page.tryConnect()
                        onTextEdited: page.lastError = ""
                    }
                }

                // ---------------- port + TLS ----------------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    TermLabel {
                        text: qsTr("port:")
                    }

                    TermField {
                        id: portField
                        Layout.fillWidth: false
                        Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 5)
                        text: "6697"
                        inputMethodHints: Qt.ImhDigitsOnly
                        validator: IntValidator { bottom: 1; top: 65535 }
                        onAccepted: page.tryConnect()
                        onTextEdited: page.lastError = ""
                    }

                    Item { Layout.fillWidth: true }

                    TermToggle {
                        id: tlsSwitch
                        Layout.fillWidth: false
                        text: qsTr("TLS")
                        checked: true

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: qsTr("Encrypt the connection with TLS")
                    }
                }

                // ---------------- nickname ----------------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    TermLabel {
                        text: qsTr("nick:")
                    }

                    TermField {
                        id: nickField
                        text: "kircuser"
                        placeholderText: qsTr("yournick")
                        onAccepted: page.tryConnect()
                        onTextEdited: page.lastError = ""
                    }
                }

                // ---------------- SASL ----------------
                TermToggle {
                    id: saslSwitch
                    Layout.topMargin: 4
                    text: qsTr("authenticate with SASL")

                    Controls.ToolTip.visible: hovered
                    Controls.ToolTip.text: qsTr("Send SASL credentials when connecting")
                }

                // Expands instead of popping in.
                Item {
                    Layout.fillWidth: true
                    clip: true
                    implicitHeight: saslSwitch.checked ? saslColumn.implicitHeight : 0
                    opacity: saslSwitch.checked ? 1 : 0
                    Behavior on implicitHeight {
                        NumberAnimation {
                            duration: ThemeEngine.motionDuration * 2
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on opacity {
                        NumberAnimation { duration: ThemeEngine.motionDuration * 2 }
                    }

                    ColumnLayout {
                        id: saslColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        spacing: 6

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            TermLabel {
                                text: qsTr("user:")
                            }

                            TermField {
                                id: saslUserField
                                placeholderText: qsTr("SASL account name")
                                onAccepted: page.tryConnect()
                                onTextEdited: page.lastError = ""
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            TermLabel {
                                text: qsTr("pass:")
                            }

                            TermField {
                                id: saslPassField
                                // Never written to disk: kirc.conf is plaintext.
                                placeholderText: qsTr("SASL password (not saved)")
                                echoMode: showSaslPass.checked ? TextInput.Normal : TextInput.Password
                                onAccepted: page.tryConnect()
                                onTextEdited: page.lastError = ""
                            }

                            TermButton {
                                id: showSaslPass
                                checkable: true
                                prompt: checked ? qsTr("[hide]") : qsTr("[show]")

                                Controls.ToolTip.visible: hovered
                                Controls.ToolTip.text: checked ? qsTr("Hide password") : qsTr("Show password")
                            }
                        }

                        // ---- SASL mechanism ----
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            TermLabel {
                                text: qsTr("mech:")
                            }

                            TermCombo {
                                id: saslMechBox
                                Layout.fillWidth: false
                                implicitWidth: Math.round(Kirigami.Units.gridUnit * 13)
                                model: [0, 1, 2]
                                currentIndex: Math.max(0, Math.min(2, page.saslMechanism))
                                textRole: ""
                                displayText: page.saslMechanismLabel(currentValue !== undefined ? currentValue : page.saslMechanism)
                                onActivated: (index) => {
                                    page.saslMechanism = model[index]
                                }

                                Controls.ToolTip.visible: hovered
                                Controls.ToolTip.text: qsTr("Auto negotiates SCRAM-SHA-256 when advertised, else PLAIN")
                            }
                        }
                    }
                }

                // ---------------- flat hints ----------------
                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    visible: page.lastError.length > 0
                    text: "! " + page.lastError
                    color: page.fgWarn()
                    font.family: page.mono
                    font.pointSize: page.ptSmall
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    visible: portField.text.length > 0 && page.parsedPort === 0
                    text: qsTr("! port must be a number between 1 and 65535")
                    color: page.fgWarn()
                    font.family: page.mono
                    font.pointSize: page.ptSmall
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    visible: !page.formValid && !page.connecting && page.parsedPort !== 0
                    text: qsTr("! enter a server host and a nickname to continue")
                    color: page.fgDim()
                    font.family: page.mono
                    font.pointSize: page.ptSmall
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                // ---------------- primary action ----------------
                Controls.Button {
                    id: connectButton
                    text: page.connecting ? qsTr("cancel") : qsTr("connect")
                    enabled: page.connecting || page.formValid
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    implicitHeight: Math.round(Kirigami.Units.gridUnit * 2)
                    onClicked: {
                        if (page.connecting) {
                            var win = applicationWindow()
                            if (win && win.userDisconnect !== undefined) {
                                win.userDisconnect = true
                            }
                            if (page.bridge !== null) {
                                page.bridge.disconnect_server()
                            }
                            return
                        }
                        page.tryConnect()
                    }

                    background: Rectangle {
                        radius: 0
                        color: !connectButton.enabled
                            ? page.bgInputC()
                            : (connectButton.down ? page.selC()
                               : (connectButton.hovered ? page.hoverC() : page.bgPanelC()))
                        border.width: 1
                        border.color: connectButton.enabled ? page.fgAccent() : page.ruleC()
                    }

                    contentItem: Text {
                        text: page.connecting ? qsTr("[ cancel ]") : qsTr("[ connect ]")
                        color: connectButton.enabled ? page.fgAccent() : page.fgDim()
                        font.family: page.mono
                        font.pointSize: page.pt
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    Layout.topMargin: 2
                    visible: page.connecting
                    text: qsTr("connecting…")
                    color: page.fgDim()
                    font.family: page.mono
                    font.pointSize: page.ptSmall
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                Item { Layout.preferredHeight: Kirigami.Units.largeSpacing }
            }
        }
    }

    function tryConnect()
    {
        if (!page.formValid || page.connecting) {
            return
        }
        page.lastError = ""
        page.connectRequested(hostField.text,
                              page.parsedPort,
                              tlsSwitch.checked,
                              nickField.text,
                              saslSwitch.checked ? saslUserField.text : "",
                              saslSwitch.checked ? saslPassField.text : "",
                              saslSwitch.checked ? page.saslMechanism : 0)
    }
}
