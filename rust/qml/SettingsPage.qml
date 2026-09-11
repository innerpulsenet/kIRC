// SPDX-License-Identifier: GPL-2.0-or-later
//
// SettingsPage — appearance, identity extras, autojoin, reconnect.

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.kirc

Kirigami.ScrollablePage {
    id: page

    property var kircConfig: null

    title: qsTr("Settings")

    function persist()
    {
        if (page.kircConfig === null) {
            return
        }
        page.kircConfig.themeId = ThemeEngine.themeId
        page.kircConfig.fontDelta = ThemeEngine.fontDelta
        page.kircConfig.autojoin = autojoinField.text
        page.kircConfig.reconnect = reconnectSwitch.checked
        page.kircConfig.minimizeToTray = traySwitch.checked
        page.kircConfig.identifyOnConnect = identifySwitch.checked
        page.kircConfig.nickservNick = nickservNickField.text
        page.kircConfig.nickservPassword = nickservPassField.text
        page.kircConfig.save()
    }

    Component.onCompleted: {
        if (page.kircConfig !== null) {
            autojoinField.text = page.kircConfig.autojoin
            reconnectSwitch.checked = page.kircConfig.reconnect
            traySwitch.checked = page.kircConfig.minimizeToTray
            fontSlider.value = page.kircConfig.fontDelta
            identifySwitch.checked = page.kircConfig.identifyOnConnect
            nickservNickField.text = page.kircConfig.nickservNick
            nickservPassField.text = page.kircConfig.nickservPassword
        }
    }

    Kirigami.FormLayout {
        wideMode: true

        Kirigami.Separator {
            Kirigami.FormData.label: qsTr("Appearance")
            Kirigami.FormData.isSection: true
        }

        Controls.ComboBox {
            id: themeBox
            Kirigami.FormData.label: qsTr("Theme")
            model: ThemeEngine.availableThemeIds
            textRole: ""
            displayText: ThemeEngine.themeDisplayName(currentText)
            currentIndex: Math.max(0, ThemeEngine.availableThemeIds.indexOf(ThemeEngine.themeId))
            onActivated: {
                ThemeEngine.applyBuiltinTheme(currentText)
                page.persist()
            }
            delegate: Controls.ItemDelegate {
                required property var modelData
                width: themeBox.width
                text: ThemeEngine.themeDisplayName(modelData)
                highlighted: themeBox.currentText === modelData
            }
        }

        Controls.ButtonGroup {
            id: layoutGroup
        }

        RowLayout {
            Kirigami.FormData.label: qsTr("Message layout")
            spacing: Kirigami.Units.smallSpacing

            Controls.RadioButton {
                text: qsTr("Bubbles")
                checked: ThemeEngine.mode === "bubble"
                Controls.ButtonGroup.group: layoutGroup
                onClicked: {
                    ThemeEngine.applyBuiltinTheme("breeze")
                    themeBox.currentIndex = ThemeEngine.availableThemeIds.indexOf("breeze")
                    page.persist()
                }
            }
            Controls.RadioButton {
                text: qsTr("Compact")
                checked: ThemeEngine.mode === "dense"
                Controls.ButtonGroup.group: layoutGroup
                onClicked: {
                    ThemeEngine.applyBuiltinTheme("breeze-classic")
                    themeBox.currentIndex = ThemeEngine.availableThemeIds.indexOf("breeze-classic")
                    page.persist()
                }
            }
        }

        Controls.Slider {
            id: fontSlider
            Kirigami.FormData.label: qsTr("Font size")
            from: -2
            to: 6
            stepSize: 1
            value: ThemeEngine.fontDelta
            onMoved: {
                ThemeEngine.fontDelta = value
                page.persist()
            }
        }

        Kirigami.Separator {
            Kirigami.FormData.label: qsTr("Connection")
            Kirigami.FormData.isSection: true
        }

        Controls.TextField {
            id: autojoinField
            Kirigami.FormData.label: qsTr("Autojoin")
            placeholderText: qsTr("#channel, #another")
            onEditingFinished: page.persist()
        }

        Kirigami.Separator {
            Kirigami.FormData.label: qsTr("NickServ")
            Kirigami.FormData.isSection: true
        }

        Controls.Switch {
            id: identifySwitch
            Kirigami.FormData.label: qsTr("Identify")
            text: qsTr("Identify on connect, then autojoin")
            onToggled: page.persist()
        }

        Controls.TextField {
            id: nickservNickField
            Kirigami.FormData.label: qsTr("Account")
            placeholderText: qsTr("Registered account (not your current nick)")
            onEditingFinished: page.persist()
        }

        Controls.TextField {
            id: nickservPassField
            Kirigami.FormData.label: qsTr("Password")
            echoMode: Controls.TextInput.Password
            placeholderText: qsTr("Stored in KWallet, never in kirc.conf")
            onEditingFinished: page.persist()
        }

        Controls.Switch {
            id: reconnectSwitch
            Kirigami.FormData.label: qsTr("Reconnect")
            text: qsTr("Reconnect automatically if dropped")
            checked: true
            onToggled: page.persist()
        }

        Controls.Switch {
            id: traySwitch
            Kirigami.FormData.label: qsTr("System tray")
            text: qsTr("Minimize to tray on close")
            onToggled: page.persist()
        }
    }
}
