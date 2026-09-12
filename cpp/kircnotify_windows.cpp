// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Windows notification backend (Phase 5): classic desktop toasts through the
// WinRT Windows.UI.Notifications API, driven with the Windows SDK's WRL
// templates.  No Windows App SDK, no NuGet package, no external helper
// process — the headers ship with the SDK kIRC already builds against.
//
// Delivery model:
//   * The process registers the AppUserModelID "org.kde.kirc" early in
//     main() (cpp/main.cpp, before QApplication exists) so Windows can
//     attribute the toast to kIRC.
//   * Reliable toast delivery additionally wants an installed Start-menu
//     shortcut carrying the same AUMID; the installer phase creates it.
//     When kIRC runs portable/development (no such shortcut registered
//     under that AUMID), toast creation fails — that failure is logged once
//     and the notification is dropped.  There is deliberately NO second
//     delivery channel (no tray balloon): it would duplicate the toast once
//     the shortcut exists, and Windows may suppress the balloon anyway.
//     A missed notification in an unregistered dev run is the accepted
//     limitation.
//   * Everything happens on the Qt GUI (main) thread: QApplication
//     initialized COM STA there (QWindowsContext OleInitializes on startup),
//     which is exactly the apartment the activation factories want.  No
//     extra threads, no marshalling.  The Activated/Dismissed/Failed events
//     are delivered to that same STA while the Qt event loop pumps COM
//     messages, so the handlers may touch Qt windows directly.
//
// Do-Not-Disturb / Focus Assist are honoured by Windows for ToastGeneric
// toasts; there is nothing for this backend to opt into.

#include "kircnotify.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <QCoreApplication>
#include <QGuiApplication>
#include <QQuickWindow>
#include <QTimer>

#include <roapi.h>
#include <windows.data.xml.dom.h>
#include <windows.ui.notifications.h>
#include <wrl/client.h>
#include <wrl/event.h>
#include <wrl/wrappers/corewrappers.h>

namespace {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HString;
using Microsoft::WRL::Wrappers::HStringReference;

using ABI::Windows::Data::Xml::Dom::IXmlDocument;
using ABI::Windows::Data::Xml::Dom::IXmlDocumentIO;
using ABI::Windows::UI::Notifications::IToastNotification;
using ABI::Windows::UI::Notifications::IToastNotificationFactory;
using ABI::Windows::UI::Notifications::IToastNotificationManagerStatics;
using ABI::Windows::UI::Notifications::IToastNotifier;

// Must match SetCurrentProcessExplicitAppUserModelID in cpp/main.cpp and the
// Start-menu shortcut the installer phase creates.
constexpr wchar_t kAumid[] = L"org.kde.kirc";

// XML-escape notification text.  Headings and bodies are IRC-controlled, so
// they must NEVER reach the toast XML raw: a message containing "<image>"
// or "&amp;" would otherwise be interpreted as markup (or break the parse).
// Escapes all five XML special characters, covering both element content and
// any attribute use.
QString xmlEscape(const QString &text)
{
    QString escaped;
    escaped.reserve(text.size() + 8);
    for (const QChar ch : text) {
        switch (ch.unicode()) {
        case u'&':
            escaped += QStringLiteral("&amp;");
            break;
        case u'<':
            escaped += QStringLiteral("&lt;");
            break;
        case u'>':
            escaped += QStringLiteral("&gt;");
            break;
        case u'"':
            escaped += QStringLiteral("&quot;");
            break;
        case u'\'':
            escaped += QStringLiteral("&apos;");
            break;
        default:
            escaped += ch;
            break;
        }
    }
    return escaped;
}

// Click-to-show: find the top-level QQuickWindow and bring it back.  A failed
// requestActivate() (Windows' foreground lock may refuse to steal focus) is
// acceptable — the window is still restored and raised on the taskbar.
void showMainWindow()
{
    const QList<QWindow *> topLevel = QGuiApplication::topLevelWindows();
    for (QWindow *window : topLevel) {
        if (auto *quick = qobject_cast<QQuickWindow *>(window)) {
            if (!quick->isVisible()) {
                quick->show();
            }
            if (quick->windowStates() & Qt::WindowMinimized) {
                quick->showNormal();
            }
            quick->raise();
            quick->requestActivate();
            return;
        }
    }
}

// One qInfo line for any failure on the delivery path.  Per the design: no
// second channel, no retry — the notification is simply dropped when toasts
// are unavailable (expected in portable/dev runs without the AUMID shortcut).
void logToastFailure(const char *step, HRESULT hr)
{
    qInfo("kIRC: toast notification unavailable (%s: HRESULT 0x%08lX); notification dropped. "
          "Reliable delivery needs the installed Start-menu shortcut with AppUserModelID %ls.",
          step, static_cast<unsigned long>(hr), kAumid);
}

void showToast(const QString &heading, const QString &body)
{
    // Fixed ToastGeneric template; the two <text> elements carry the
    // escaped title and body.
    const QString xml = QStringLiteral(
        "<toast><visual><binding template=\"ToastGeneric\">"
        "<text>%1</text>"
        "<text>%2</text>"
        "</binding></visual></toast>")
                            .arg(xmlEscape(heading), xmlEscape(body));

    HRESULT hr = S_OK;

    // XmlDocument to parse the toast XML into.
    ComPtr<IXmlDocument> xmlDocument;
    {
        ComPtr<IInspectable> instance;
        hr = RoActivateInstance(
            HStringReference(RuntimeClass_Windows_Data_Xml_Dom_XmlDocument).Get(), &instance);
        if (FAILED(hr)) {
            logToastFailure("create XmlDocument", hr);
            return;
        }
        hr = instance.As(&xmlDocument);
        if (FAILED(hr)) {
            logToastFailure("query XmlDocument", hr);
            return;
        }
    }

    {
        HString xmlString;
        hr = xmlString.Set(reinterpret_cast<const wchar_t *>(xml.utf16()));
        if (FAILED(hr)) {
            logToastFailure("create XML string", hr);
            return;
        }
        // LoadXml lives on IXmlDocumentIO, which the XmlDocument instance
        // implements; the ABI header keeps it on the separate interface.
        ComPtr<IXmlDocumentIO> xmlDocumentIO;
        hr = xmlDocument.As(&xmlDocumentIO);
        if (SUCCEEDED(hr)) {
            hr = xmlDocumentIO->LoadXml(xmlString.Get());
        }
        if (FAILED(hr)) {
            logToastFailure("LoadXml", hr);
            return;
        }
    }

    // The notifier bound to our AUMID — the documented route for desktop
    // apps (as opposed to packaged/UWP apps, which omit the id).
    ComPtr<IToastNotificationManagerStatics> managerStatics;
    hr = RoGetActivationFactory(
        HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotificationManager).Get(),
        IID_PPV_ARGS(&managerStatics));
    if (FAILED(hr)) {
        logToastFailure("ToastNotificationManager factory", hr);
        return;
    }

    ComPtr<IToastNotifier> notifier;
    hr = managerStatics->CreateToastNotifierWithId(HStringReference(kAumid).Get(), &notifier);
    if (FAILED(hr)) {
        // This is the step that fails when no Start-menu shortcut registers
        // the AUMID (unregistered dev runs).
        logToastFailure("CreateToastNotifier", hr);
        return;
    }

    ComPtr<IToastNotificationFactory> toastFactory;
    hr = RoGetActivationFactory(
        HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotification).Get(),
        IID_PPV_ARGS(&toastFactory));
    if (FAILED(hr)) {
        logToastFailure("ToastNotification factory", hr);
        return;
    }

    ComPtr<IToastNotification> toast;
    hr = toastFactory->CreateToastNotification(xmlDocument.Get(), &toast);
    if (FAILED(hr)) {
        logToastFailure("CreateToastNotification", hr);
        return;
    }

    // Events.  Registration is best-effort — a failure here must not abort
    // delivery, so each result is only logged (Activated) or ignored.
    //
    // Lifetime: WRL's com_ptr drops our references when this function
    // returns, but the notification platform holds its own reference to the
    // toast while it is displayed, and the toast keeps the event sinks
    // referenced in turn.  Everything releases once the toast goes away;
    // no explicit remove_* bookkeeping is needed.
    //
    // The Callback<>/lambda types follow the SDK's generated ABI: the
    // template argument is spelled with the runtime-class names
    // (ToastNotification*, ToastFailedEventArgs* — those are the
    // specializations windows.foundation.h emits), while Invoke receives the
    // default-interface ABI types (IToastNotification*,
    // IToastFailedEventArgs*).
    EventRegistrationToken token = {};
    auto activatedHandler = Callback<ABI::Windows::Foundation::ITypedEventHandler<
        ABI::Windows::UI::Notifications::ToastNotification *, IInspectable *>>(
        [](IToastNotification *, IInspectable *) -> HRESULT {
            showMainWindow();
            return S_OK;
        });
    hr = toast->add_Activated(activatedHandler.Get(), &token);
    if (FAILED(hr)) {
        qWarning("kIRC: toast Activated registration failed (HRESULT 0x%08lX); "
                 "click-to-show disabled for this toast",
                 static_cast<unsigned long>(hr));
    }

    auto dismissedHandler = Callback<ABI::Windows::Foundation::ITypedEventHandler<
        ABI::Windows::UI::Notifications::ToastNotification *,
        ABI::Windows::UI::Notifications::ToastDismissedEventArgs *>>(
        [](IToastNotification *, ABI::Windows::UI::Notifications::IToastDismissedEventArgs *)
            -> HRESULT { return S_OK; });
    hr = toast->add_Dismissed(dismissedHandler.Get(), &token);
    if (FAILED(hr)) {
        qWarning("kIRC: toast Dismissed registration failed (HRESULT 0x%08lX)",
                 static_cast<unsigned long>(hr));
    }

    auto failedHandler = Callback<ABI::Windows::Foundation::ITypedEventHandler<
        ABI::Windows::UI::Notifications::ToastNotification *,
        ABI::Windows::UI::Notifications::ToastFailedEventArgs *>>(
        [](IToastNotification *, ABI::Windows::UI::Notifications::IToastFailedEventArgs *)
            -> HRESULT {
            qWarning("kIRC: toast delivery failed (check notification settings / Focus Assist)");
            return S_OK;
        });
    hr = toast->add_Failed(failedHandler.Get(), &token);
    if (FAILED(hr)) {
        qWarning("kIRC: toast Failed registration failed (HRESULT 0x%08lX)",
                 static_cast<unsigned long>(hr));
    }

    hr = notifier->Show(toast.Get());
    if (FAILED(hr)) {
        logToastFailure("Show", hr);
    }
}

} // namespace

void kircPlatformNotify(const QString &heading, const QString &body)
{
    showToast(heading, body);
}

bool kircPlatformNotificationInitialize()
{
    const HRESULT hr = RoInitialize(RO_INIT_SINGLETHREADED);
    if (SUCCEEDED(hr)) {
        return true;
    }
    logToastFailure("RoInitialize", hr);
    return false;
}

void kircPlatformNotificationShutdown()
{
    RoUninitialize();
}

// ---------------------------------------------------------------------------
// DEV TRIGGER — never active in normal use.
//
// KIRC_TOAST_SELFTEST=1 fires one synthetic notification ("kIRC self-test" /
// "toast path check") three seconds after startup, so the whole toast path
// can be verified end to end on a real desktop without an IRC highlight.
// Product behaviour is untouched: without the variable this returns before
// doing anything, and even with it exactly one notification is sent.
// ---------------------------------------------------------------------------

void scheduleToastSelfTest()
{
    if (!qEnvironmentVariableIsSet("KIRC_TOAST_SELFTEST")) {
        return;
    }
    qInfo("kIRC: KIRC_TOAST_SELFTEST set, firing toast self-test in 3s");
    QTimer::singleShot(3000, nullptr, [] {
        // showToast() logs a failure line and returns before this if delivery
        // fails, so "dispatched" in the log means every WinRT call returned
        // S_OK and Show() was reached.
        kircPlatformNotify(QStringLiteral("kIRC self-test"), QStringLiteral("toast path check"));
        qInfo("kIRC: toast self-test dispatched");
    });
}

Q_COREAPP_STARTUP_FUNCTION(scheduleToastSelfTest)
