+++
date = '2026-05-14T00:09:20+07:00'
draft = false
title = 'Actually Profiling WebGPU in Chrome With Vendor Profilers on Windows'
+++

# Context
Profiling WebGPU workload in Chrome is historically not that easy. There are ways to capture frames with PIX and RenderDoc (see Toji's blog: [PIX](https://toji.dev/webgpu-profiling/pix.html) [RenderDoc](https://toji.dev/webgpu-profiling/renderdoc). Those are great tools, but sometimes you need just a little more information that a hardware vendor profiler would have provided. And there *was* a way to use those developed by [François](https://frguthmann.github.io/posts/profiling_webgpu/) and involving a shimmed `d3d12.dll` to force a present event. [His blog post](https://frguthmann.github.io/posts/shimming_d3d12/) explains all the details if you're interested. Regrettably, on March 11 17:43:48 2025 this hack stopped working. Why would it happen on that time, you ask? Because that's when [this commit](https://dawn.googlesource.com/dawn/+/cf3899ffab5d4e2e015c56e72bb48fa0209559fe%5E%21) was created. It forced loading libraries from system32 to avoid DLL search path attacks. Oh well, it was a hacky solution and those tend to break over time.

And what a better way to fix a broken hack than adding another hack on top of that? I managed to reliably launch Chrome through another .exe to hijack its library load order and make it see the shiny shimmed `d3d12.dll` lying nearby. Thus allowing us to use vendor profilers once again.

Just using [DLL Redirection](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-redirection) did not seem to work - Chrome processes just crashed on me. Maybe I was holding it wrong?
# Instructions
> **Please remember that this is a hacky solution and that you should not browse the open web with those DLLs attached. They should only be used for a GPU profiling session and removed afterwards. Original d3d12 shim also conflicts with PIX, so you should remove it before attempting to take a capture. I would recommend adding files to a specific flavor of Chrome ( Dev, Canary, etc. ) that you would only use for GPU profiling.** 
- Download `chrome_launcher.exe`, `apihook.dll` and `d3d12.dll` from the release section of [this repository](https://github.com/TheBlek/d3d12_webgpu_shim).
    - Place files into the `\Google\Chrome\Application` folder.
- On AMD, download `WinPixEventRuntime.dll` from the release section of [that repository](https://github.com/frguthmann/PixEventsAMD).
    - Place it into the `\Google\Chrome\Application\<Version Number>` folder.
- Launch `chrome_launcher.exe`
- Use your favorite profiler as usual.
# How it's done?

Here's the diff of [the commit](https://dawn.googlesource.com/dawn/+/cf3899ffab5d4e2e015c56e72bb48fa0209559fe%5E%21):
```diff
+#if DAWN_PLATFORM_IS(WINDOWS) && !DAWN_PLATFORM_IS(WINUWP)
+bool DynamicLib::OpenSystemLibrary(std::wstring_view filename, std::string* error) {
+    // Force LOAD_LIBRARY_SEARCH_SYSTEM32 for system libraries to avoid DLL search path
+    // attacks.
+    mHandle = ::LoadLibraryExW(filename.data(), nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
+    if (mHandle == nullptr && error != nullptr) {
+        *error = "Windows Error: " + std::to_string(GetLastError());
+    }
+    return mHandle != nullptr;
+}
+#endif
+
```

If only we could get rid of that `LOAD_LIBRARY_SEARCH_SYSTEM32` flag... But how would we go about doing that?

One could apply a patch to the dawn source code removing the flag and build a browser for profiling. However the idea of compiling a new chromium even once, let alone on each update, is debilitating.
How can I, the owner of the machine, force the program running on it to do exactly what I want? Windows' library calls would need to be *intercepted* and modified somehow. [Detours](https://github.com/microsoft/detours) allows us to do just that!
It is able to start a new process and immediately load a DLL into it:

```cpp
BOOL DetourCreateProcessWithDllEx(
    _In_opt_    LPCTSTR lpApplicationName,
    _Inout_opt_ LPTSTR lpCommandLine,
    _In_opt_    LPSECURITY_ATTRIBUTES lpProcessAttributes,
    _In_opt_    LPSECURITY_ATTRIBUTES lpThreadAttributes,
    _In_        BOOL bInheritHandles,
    _In_        DWORD dwCreationFlags,
    _In_opt_    LPVOID lpEnvironment,
    _In_opt_    LPCTSTR lpCurrentDirectory,
    _In_        LPSTARTUPINFOW lpStartupInfo,
    _Out_       LPPROCESS_INFORMATION lpProcessInformation,
    _In_        LPCSTR lpDllName,
    _In_opt_    PDETOUR_CREATE_PROCESS_ROUTINEW pfCreateProcessW
);
```

And in that DLL it allows us to basically replace any library call with our own:

```cpp
LONG DetourAttach(
    _Inout_ PVOID * ppPointer,
    _In_    PVOID pDetour
);
```

So the plan is:
Launch Chrome using Detours, loading into it a DLL:

```cpp
BOOL success = DetourCreateProcessWithDllEx(
	chromePath.c_str(),
	&commandLine[0],
	NULL,
	NULL,
	FALSE,
	CREATE_DEFAULT_ERROR_MODE | CREATE_SUSPENDED,
	NULL,
	NULL,
	&startupInfo,
	&processInfo,
	hookDllPath.string().c_str(),
	NULL
);
```

In that DLL, define custom `LoadLibraryW` and `LoadLibraryExW` functions that disable the `LOAD_LIBRARY_SEARCH_SYSTEM32` on `d3d12.dll` load:

```cpp
HMODULE WINAPI My_LoadLibraryExW(LPCWSTR lpLibFileName, HANDLE hFile, DWORD dwFlags)
{
    if (lpLibFileName != nullptr)
    {
        std::wstring name(lpLibFileName);
        std::wstring lowerName = name;
        for (auto& c : lowerName) c = towlower(c);

        if (lowerName.find(L"d3d12") != std::wstring::npos)
        {
            if (dwFlags & LOAD_LIBRARY_SEARCH_SYSTEM32)
            {
                dwFlags &= ~LOAD_LIBRARY_SEARCH_SYSTEM32;
            }
        }
    }

    return Real_LoadLibraryExW(lpLibFileName, hFile, dwFlags);
}

HMODULE WINAPI My_LoadLibraryW(LPCWSTR lpLibFileName)
{
    return My_LoadLibraryExW(lpLibFileName, NULL, 0);
}
```

Save pointers to original functions and replace them with defined above:

```cpp
static HMODULE(WINAPI* Real_LoadLibraryExW)(LPCWSTR, HANDLE, DWORD) = LoadLibraryExW;
static HMODULE(WINAPI* Real_LoadLibraryW)(LPCWSTR) = LoadLibraryW;

...

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        DetourRestoreAfterWith();

        DetourTransactionBegin();
        DetourUpdateThread(GetCurrentThread());
        DetourAttach(&(PVOID&)Real_LoadLibraryExW, My_LoadLibraryExW);
        DetourAttach(&(PVOID&)Real_LoadLibraryW, My_LoadLibraryW);
        DetourTransactionCommit();
    }
    else if (reason == DLL_PROCESS_DETACH)
    {
        DetourTransactionBegin();
        DetourUpdateThread(GetCurrentThread());
        DetourDetach(&(PVOID&)Real_LoadLibraryExW, My_LoadLibraryExW);
        DetourDetach(&(PVOID&)Real_LoadLibraryW, My_LoadLibraryW);
        DetourTransactionCommit();
    }

    return TRUE;
}
```

Does that work? Almost. We also need to remember that Chrome launches a lot of processes, one of which handles the GPU - exactly the one loading `d3d12.dll`. So to hijack `LoadLibrary(Ex)W` calls there we need to infect other processes with our DLL :)

```cpp
static std::string GetSelfPath()
{
    char path[MAX_PATH];
    GetModuleFileNameA(GetModuleHandleA("apihook.dll"), path, MAX_PATH);
    return std::string(path);
}

...

static BOOL(WINAPI* Real_CreateProcessW)(
    LPCWSTR, LPWSTR, LPSECURITY_ATTRIBUTES, LPSECURITY_ATTRIBUTES,
    BOOL, DWORD, LPVOID, LPCWSTR, LPSTARTUPINFOW, LPPROCESS_INFORMATION
) = CreateProcessW;

...

BOOL WINAPI My_CreateProcessW(
    LPCWSTR lpApplicationName,
    LPWSTR lpCommandLine,
    LPSECURITY_ATTRIBUTES lpProcessAttributes,
    LPSECURITY_ATTRIBUTES lpThreadAttributes,
    BOOL bInheritHandles,
    DWORD dwCreationFlags,
    LPVOID lpEnvironment,
    LPCWSTR lpCurrentDirectory,
    LPSTARTUPINFOW lpStartupInfo,
    LPPROCESS_INFORMATION lpProcessInformation
)
{
    if (lpCommandLine && wcsstr(lpCommandLine, L"--type=gpu-process"))
    {
        PROCESS_INFORMATION pi = {};

        BOOL result = Real_CreateProcessW(
            lpApplicationName, lpCommandLine,
            lpProcessAttributes, lpThreadAttributes,
            bInheritHandles, dwCreationFlags | CREATE_SUSPENDED,
            lpEnvironment, lpCurrentDirectory,
            lpStartupInfo, &pi
        );

        if (!result)
        {
            return FALSE;
        }

        std::string dllPath = GetSelfPath();
        LPCSTR dllName = dllPath.c_str();
        BOOL injectOk = DetourUpdateProcessWithDll(pi.hProcess, &dllName, 1);

        if (!injectOk)
        {
            TerminateProcess(pi.hProcess, 1);
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
            return FALSE;
        }

        if (!(dwCreationFlags & CREATE_SUSPENDED))
        {
            ResumeThread(pi.hThread);
        }

        if (lpProcessInformation)
        {
            *lpProcessInformation = pi;
        }

        return TRUE;
    }

    return Real_CreateProcessW(
        lpApplicationName, lpCommandLine,
        lpProcessAttributes, lpThreadAttributes,
        bInheritHandles, dwCreationFlags,
        lpEnvironment, lpCurrentDirectory,
        lpStartupInfo, lpProcessInformation
    );
}

...

DetourAttach(&(PVOID&)Real_CreateProcessW, My_CreateProcessW);
```

Is this a good idea? Probably not. Is this a hacky solution? Certainly. But it is a solution.

Launching chrome with our infectious DLL causes GPU process to remove the `LOAD_LIBRARY_SEARCH_SYSTEM32` flag and find shimmed `d3d12.dll` lying around. The AMD Radeon Graphics Profiler now just works and not once a chromium was built in the process. Nvidia Nsight should work too, but I am unable to verify.
# Epilogue
This was truly an experience that opened my eyes on how much one is actually in control of the software running on their computer. You can do practically anything with it.
Regarding WebGPU tooling: it is sad to see that the ability to use amazing tools is being restricted in vain of security. And there is no option turn this off in development mode either. Let's hope this hacky solution lives another year, like did the first one.
