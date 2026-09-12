// SPDX-License-Identifier: MIT OR Apache-2.0
// Installer helper for an unpackaged desktop application's toast identity.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <propsys.h>
#include <propkey.h>
#include <propvarutil.h>

#include <string>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR commandLine, int)
{
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc != 4) {
        if (argv) LocalFree(argv);
        return 2;
    }

    const HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(init)) {
        LocalFree(argv);
        return 3;
    }

    IShellLinkW *link = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&link));
    if (SUCCEEDED(hr)) hr = link->SetPath(argv[2]);
    if (SUCCEEDED(hr)) hr = link->SetIconLocation(argv[3], 0);
    if (SUCCEEDED(hr)) {
        IPropertyStore *store = nullptr;
        hr = link->QueryInterface(IID_PPV_ARGS(&store));
        if (SUCCEEDED(hr)) {
            PROPVARIANT value;
            hr = InitPropVariantFromString(L"org.kde.kirc", &value);
            if (SUCCEEDED(hr)) hr = store->SetValue(PKEY_AppUserModel_ID, value);
            if (SUCCEEDED(hr)) hr = store->Commit();
            PropVariantClear(&value);
            store->Release();
        }
    }
    if (SUCCEEDED(hr)) {
        IPersistFile *file = nullptr;
        hr = link->QueryInterface(IID_PPV_ARGS(&file));
        if (SUCCEEDED(hr)) {
            hr = file->Save(argv[1], TRUE);
            file->Release();
        }
    }

    if (link) link->Release();
    CoUninitialize();
    LocalFree(argv);
    return SUCCEEDED(hr) ? 0 : 1;
}
