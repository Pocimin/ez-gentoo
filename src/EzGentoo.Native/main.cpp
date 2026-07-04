#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>
#include <shlobj.h>
#include <shellapi.h>
#include <urlmon.h>
#include <wincrypt.h>
#include <winsock2.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "urlmon.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "comctl32.lib")

static constexpr UINT WM_APP_LOG = WM_APP + 1;

enum ControlId
{
    IdVmName = 100,
    IdInstallDir,
    IdImageSource,
    IdRam,
    IdCpu,
    IdDisk,
    IdBrowse,
    IdPickImage,
    IdInstall,
    IdConnect,
    IdStop,
    IdProgress,
    IdStatus,
    IdLog
};

static std::wstring Utf8ToWide(const std::string& s)
{
    if (s.empty()) return {};
    int len = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring out(len, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), len);
    return out;
}

static std::string WideToUtf8(const std::wstring& s)
{
    if (s.empty()) return {};
    int len = WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    std::string out(len, 0);
    WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), len, nullptr, nullptr);
    return out;
}

static std::wstring PsQuote(const std::wstring& s)
{
    std::wstring out = L"'";
    for (wchar_t c : s) out += c == L'\'' ? L"''" : std::wstring(1, c);
    out += L"'";
    return out;
}

static std::wstring Base64Utf16(const std::wstring& s)
{
    DWORD needed = 0;
    CryptBinaryToStringW((const BYTE*)s.data(), (DWORD)(s.size() * sizeof(wchar_t)),
        CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &needed);
    std::wstring out(needed, 0);
    CryptBinaryToStringW((const BYTE*)s.data(), (DWORD)(s.size() * sizeof(wchar_t)),
        CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, out.data(), &needed);
    if (!out.empty() && out.back() == L'\0') out.pop_back();
    return out;
}

struct CommandResult
{
    DWORD code = 1;
    std::string output;
};

static CommandResult RunHidden(const std::wstring& file, const std::wstring& args)
{
    SECURITY_ATTRIBUTES sa{ sizeof(sa) };
    sa.bInheritHandle = TRUE;

    HANDLE readPipe = nullptr, writePipe = nullptr;
    CreatePipe(&readPipe, &writePipe, &sa, 0);
    SetHandleInformation(readPipe, HANDLE_FLAG_INHERIT, 0);

    std::wstring cmd = L"\"" + file + L"\" " + args;
    STARTUPINFOW si{ sizeof(si) };
    si.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
    si.wShowWindow = SW_HIDE;
    si.hStdOutput = writePipe;
    si.hStdError = writePipe;

    PROCESS_INFORMATION pi{};
    BOOL ok = CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
    CloseHandle(writePipe);

    CommandResult result;
    if (!ok)
    {
        CloseHandle(readPipe);
        result.output = "failed to start process";
        return result;
    }

    char buffer[4096];
    DWORD read = 0;
    while (ReadFile(readPipe, buffer, sizeof(buffer), &read, nullptr) && read > 0)
        result.output.append(buffer, buffer + read);

    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &result.code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    CloseHandle(readPipe);
    return result;
}

static CommandResult PowerShell(const std::wstring& script)
{
    std::wstring prefix = L"$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::UTF8; ";
    return RunHidden(L"powershell.exe", L"-NoProfile -ExecutionPolicy Bypass -EncodedCommand " + Base64Utf16(prefix + script));
}

static std::wstring DefaultInstallDir()
{
    wchar_t* local = nullptr;
    SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local);
    std::wstring out = std::wstring(local ? local : L".") + L"\\EzGentoo";
    CoTaskMemFree(local);
    return out;
}

static bool FileExists(const std::wstring& path)
{
    return std::filesystem::exists(std::filesystem::path(path));
}

static bool StartsWithHttp(const std::wstring& s)
{
    return s.rfind(L"http://", 0) == 0 || s.rfind(L"https://", 0) == 0;
}

static bool VmExists(const std::wstring& vm)
{
    auto r = PowerShell(L"if (Get-VM -Name " + PsQuote(vm) + L" -ErrorAction SilentlyContinue) { 'yes' }");
    return r.output.find("yes") != std::string::npos;
}

static std::wstring FindDefaultVmName()
{
    auto r = PowerShell(
        L"$vms = Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'gentoo' } | "
        L"Sort-Object @{ Expression = { if ($_.Name -eq 'GentooReady') { 0 } elseif ($_.Name -eq 'Gentoo') { 1 } else { 2 } } }, Name | "
        L"Select-Object -First 1 -ExpandProperty Name; $vms");
    std::string s = r.output;
    s.erase(std::remove(s.begin(), s.end(), '\r'), s.end());
    s.erase(std::remove(s.begin(), s.end(), '\n'), s.end());
    return s.empty() ? L"EzGentoo" : Utf8ToWide(s);
}

struct AppState
{
    HWND hwnd = nullptr;
    HWND vmName = nullptr;
    HWND installDir = nullptr;
    HWND imageSource = nullptr;
    HWND ram = nullptr;
    HWND cpu = nullptr;
    HWND disk = nullptr;
    HWND status = nullptr;
    HWND progress = nullptr;
    HWND log = nullptr;
    std::mutex mutex;
    bool busy = false;
    int vncDisplay = 1;
    int vncPort = 5901;
    std::string currentIp;
};

static AppState g_app;
static HFONT g_titleFont = nullptr;
static HFONT g_uiFont = nullptr;

static std::wstring GetText(HWND hwnd)
{
    int len = GetWindowTextLengthW(hwnd);
    std::wstring out(len + 1, 0);
    GetWindowTextW(hwnd, out.data(), (int)out.size());
    out.resize(len);
    return out;
}

static int GetInt(HWND hwnd, int fallback)
{
    BOOL ok = FALSE;
    int value = GetDlgItemInt(GetParent(hwnd), GetDlgCtrlID(hwnd), &ok, FALSE);
    return ok ? value : fallback;
}

static void SetBusy(bool busy)
{
    g_app.busy = busy;
    EnableWindow(g_app.vmName, !busy);
    EnableWindow(g_app.installDir, !busy);
    EnableWindow(g_app.imageSource, !busy);
    EnableWindow(g_app.ram, !busy);
    EnableWindow(g_app.cpu, !busy);
    EnableWindow(g_app.disk, !busy);
    EnableWindow(GetDlgItem(g_app.hwnd, IdBrowse), !busy);
    EnableWindow(GetDlgItem(g_app.hwnd, IdPickImage), !busy);
    EnableWindow(GetDlgItem(g_app.hwnd, IdInstall), !busy);
    EnableWindow(GetDlgItem(g_app.hwnd, IdConnect), !busy);
    EnableWindow(GetDlgItem(g_app.hwnd, IdStop), !busy);
}

static void AddLogLine(const std::wstring& line)
{
    SendMessageW(g_app.log, LB_ADDSTRING, 0, (LPARAM)line.c_str());
    int count = (int)SendMessageW(g_app.log, LB_GETCOUNT, 0, 0);
    if (count > 500) SendMessageW(g_app.log, LB_DELETESTRING, 0, 0);
    SendMessageW(g_app.log, LB_SETTOPINDEX, max(0, count - 1), 0);
}

static void Log(const std::string& msg)
{
    SYSTEMTIME t;
    GetLocalTime(&t);
    char line[1400];
    snprintf(line, sizeof(line), "%02d:%02d:%02d  %s", t.wHour, t.wMinute, t.wSecond, msg.c_str());
    auto* copy = new std::wstring(Utf8ToWide(line));
    PostMessageW(g_app.hwnd, WM_APP_LOG, 0, (LPARAM)copy);
}

static void SetStatus(const std::string& msg, int progress)
{
    SetWindowTextW(g_app.status, Utf8ToWide(msg).c_str());
    SendMessageW(g_app.progress, PBM_SETPOS, std::clamp(progress, 0, 100), 0);
    Log(msg);
}

static void RequireOk(const CommandResult& r, const std::string& what)
{
    if (r.code != 0)
    {
        Log(r.output);
        throw std::runtime_error(what + " failed");
    }
}

static std::wstring FindQemuImg()
{
    auto r = PowerShell(L"(Get-Command qemu-img -ErrorAction SilentlyContinue).Source");
    std::string s = r.output;
    s.erase(std::remove(s.begin(), s.end(), '\r'), s.end());
    s.erase(std::remove(s.begin(), s.end(), '\n'), s.end());
    return Utf8ToWide(s);
}

static void EnsureTooling()
{
    RequireOk(PowerShell(L"if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw 'Hyper-V PowerShell tools are missing. Enable Hyper-V first.' }"), "Hyper-V check");

    if (!FileExists(L"C:\\Program Files\\TigerVNC\\vncviewer.exe"))
    {
        Log("TigerVNC missing. Asking winget to install it.");
        RequireOk(RunHidden(L"winget.exe", L"install --id TigerVNC.TigerVNC --exact --accept-source-agreements --accept-package-agreements"), "TigerVNC install");
    }
}

static std::wstring EnsureImage(const std::wstring& installDir, const std::wstring& source, int diskGb)
{
    std::filesystem::create_directories(installDir);
    std::wstring imagePath = installDir + L"\\ez-gentoo-base.vhdx";

    if (!FileExists(imagePath))
    {
        if (StartsWithHttp(source))
        {
            Log("Downloading base image. This is the long part.");
            HRESULT hr = URLDownloadToFileW(nullptr, source.c_str(), imagePath.c_str(), 0, nullptr);
            if (FAILED(hr)) throw std::runtime_error("download failed");
        }
        else if (FileExists(source) && source.size() >= 5 && source.substr(source.size() - 5) == L".vhdx")
        {
            Log("Copying local VHDX.");
            std::filesystem::copy_file(source, imagePath, std::filesystem::copy_options::overwrite_existing);
        }
        else if (FileExists(source) && source.size() >= 6 && source.substr(source.size() - 6) == L".qcow2")
        {
            std::wstring qemu = FindQemuImg();
            if (qemu.empty())
            {
                Log("qemu-img missing. Asking winget to install it.");
                RequireOk(RunHidden(L"winget.exe", L"install --id cloudbase.qemu-img --exact --accept-source-agreements --accept-package-agreements"), "qemu-img install");
                qemu = FindQemuImg();
            }
            if (qemu.empty()) throw std::runtime_error("qemu-img not found");
            Log("Converting QCOW2 to VHDX.");
            RequireOk(RunHidden(qemu, L"convert -p -O vhdx \"" + source + L"\" \"" + imagePath + L"\""), "qemu-img convert");
        }
        else
        {
            throw std::runtime_error("image must be a URL, .vhdx, or .qcow2");
        }
    }
    else
    {
        Log("Base image already exists.");
    }

    long long targetBytes = (long long)diskGb * 1024LL * 1024LL * 1024LL;
    std::wstringstream resize;
    resize << L"$vhd = Get-VHD -Path " << PsQuote(imagePath) << L"; "
           << L"if ($vhd.Size -lt " << targetBytes << L") { Resize-VHD -Path "
           << PsQuote(imagePath) << L" -SizeBytes " << targetBytes << L" }";
    RequireOk(PowerShell(resize.str()), "disk resize");
    return imagePath;
}

static void EnsureVm(const std::wstring& vm, const std::wstring& installDir, const std::wstring& imagePath, int ramGb, int cpuCount)
{
    std::wstring vmDir = installDir + L"\\vm";
    std::filesystem::create_directories(vmDir);
    long long memoryBytes = (long long)ramGb * 1024LL * 1024LL * 1024LL;
    long long minBytes = 2LL * 1024LL * 1024LL * 1024LL;

    std::wstringstream ps;
    ps << L"$vm = Get-VM -Name " << PsQuote(vm) << L" -ErrorAction SilentlyContinue; "
       << L"if (-not $vm) { "
       << L"New-VM -Name " << PsQuote(vm)
       << L" -Generation 2 -MemoryStartupBytes " << memoryBytes
       << L" -VHDPath " << PsQuote(imagePath)
       << L" -Path " << PsQuote(vmDir)
       << L" -SwitchName 'Default Switch' | Out-Null; "
       << L"Set-VMFirmware -VMName " << PsQuote(vm) << L" -EnableSecureBoot Off }; "
       << L"Set-VMProcessor -VMName " << PsQuote(vm) << L" -Count " << cpuCount << L"; "
       << L"Set-VMMemory -VMName " << PsQuote(vm)
       << L" -DynamicMemoryEnabled $true -MinimumBytes " << minBytes
       << L" -StartupBytes " << memoryBytes
       << L" -MaximumBytes " << memoryBytes;

    RequireOk(PowerShell(ps.str()), "VM create/configure");
}

static void StartVm(const std::wstring& vm)
{
    std::wstring ps = L"$vm = Get-VM -Name " + PsQuote(vm) + L"; if ($vm.State -ne 'Running') { Start-VM -Name " + PsQuote(vm) + L" }";
    RequireOk(PowerShell(ps), "VM start");
}

static std::vector<std::string> CandidateIps(const std::wstring& vm)
{
    std::wstring ps =
        L"$adapter = Get-VMNetworkAdapter -VMName " + PsQuote(vm) + L"; "
        L"$mac = (($adapter.MacAddress -replace '[^0-9A-Fa-f]', '').ToUpper() -replace '(.{2})(?!$)', '$1-'); "
        L"$ips = @(); "
        L"$ips += @($adapter.IPAddresses | Where-Object { $_ -match '^\\d+\\.\\d+\\.\\d+\\.\\d+$' }); "
        L"$ips += @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | "
        L"Where-Object { $_.LinkLayerAddress -eq $mac -and $_.State -notin @('Unreachable','Incomplete') } | "
        L"Select-Object -ExpandProperty IPAddress); "
        L"$ips | Select-Object -Unique";
    auto r = PowerShell(ps);
    std::vector<std::string> ips;
    std::stringstream ss(r.output);
    std::string line;
    while (std::getline(ss, line))
    {
        line.erase(std::remove(line.begin(), line.end(), '\r'), line.end());
        if (std::count(line.begin(), line.end(), '.') == 3) ips.push_back(line);
    }
    return ips;
}

static bool TestTcp(const std::string& ip, int port)
{
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return false;
    u_long mode = 1;
    ioctlsocket(s, FIONBIO, &mode);

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)port);
    inet_pton(AF_INET, ip.c_str(), &addr.sin_addr);
    connect(s, (sockaddr*)&addr, sizeof(addr));

    fd_set set;
    FD_ZERO(&set);
    FD_SET(s, &set);
    timeval timeout{ 0, 900000 };
    int ok = select(0, nullptr, &set, nullptr, &timeout);
    closesocket(s);
    return ok > 0;
}

static std::string WaitForVnc(const std::wstring& vm)
{
    std::vector<std::string> seen;
    for (int i = 0; i < 75; ++i)
    {
        for (const auto& ip : CandidateIps(vm))
        {
            if (std::find(seen.begin(), seen.end(), ip) == seen.end())
            {
                seen.push_back(ip);
                Log("Found candidate IP " + ip);
            }
            if (TestTcp(ip, g_app.vncPort)) return ip;
        }
        Sleep(2000);
    }
    throw std::runtime_error("VNC never answered");
}

static void OpenVnc(const std::string& ip, int display)
{
    std::wstring target = Utf8ToWide(ip + ":" + std::to_string(display));
    ShellExecuteW(nullptr, L"open", L"C:\\Program Files\\TigerVNC\\vncviewer.exe", (L"-FullScreen " + target).c_str(), nullptr, SW_SHOWNORMAL);
}

struct Settings
{
    std::wstring vm;
    std::wstring dir;
    std::wstring image;
    int ram = 4;
    int cpu = 4;
    int disk = 40;
};

static Settings ReadSettings()
{
    Settings s;
    s.vm = GetText(g_app.vmName);
    s.dir = GetText(g_app.installDir);
    s.image = GetText(g_app.imageSource);
    s.ram = std::clamp(GetInt(g_app.ram, 4), 2, 64);
    s.cpu = std::clamp(GetInt(g_app.cpu, 4), 1, 32);
    s.disk = std::clamp(GetInt(g_app.disk, 40), 20, 512);
    return s;
}

static void InstallStartConnect(Settings s)
{
    try
    {
        SetStatus("Checking Windows bits...", 5);
        EnsureTooling();
        if (VmExists(s.vm))
        {
            SetStatus("Using existing VM " + WideToUtf8(s.vm) + "...", 45);
        }
        else
        {
            SetStatus("Preparing Gentoo image...", 20);
            std::wstring image = EnsureImage(s.dir, s.image, s.disk);
            SetStatus("Creating Hyper-V VM...", 45);
            EnsureVm(s.vm, s.dir, image, s.ram, s.cpu);
        }
        SetStatus("Starting Gentoo...", 60);
        StartVm(s.vm);
        SetStatus("Finding the VM on Hyper-V's chaos network...", 75);
        g_app.currentIp = WaitForVnc(s.vm);
        SetStatus("Opening Gentoo desktop...", 95);
        OpenVnc(g_app.currentIp, g_app.vncDisplay);
        SetStatus("Done. Go larp.", 100);
    }
    catch (const std::exception& e)
    {
        SetStatus(std::string("Failed: ") + e.what(), 0);
    }
    PostMessageW(g_app.hwnd, WM_APP_LOG, 1, 0);
}

static void Connect(Settings s)
{
    try
    {
        SetStatus("Finding the VM...", 60);
        g_app.currentIp = WaitForVnc(s.vm);
        OpenVnc(g_app.currentIp, g_app.vncDisplay);
        SetStatus("Desktop opened.", 100);
    }
    catch (const std::exception& e)
    {
        SetStatus(std::string("Failed: ") + e.what(), 0);
    }
    PostMessageW(g_app.hwnd, WM_APP_LOG, 1, 0);
}

static void StopVm(Settings s)
{
    try
    {
        SetStatus("Stopping VM...", 30);
        RequireOk(PowerShell(L"Stop-VM -Name " + PsQuote(s.vm) + L" -TurnOff -Force"), "VM stop");
        SetStatus("VM stopped.", 0);
    }
    catch (const std::exception& e)
    {
        SetStatus(std::string("Failed: ") + e.what(), 0);
    }
    PostMessageW(g_app.hwnd, WM_APP_LOG, 1, 0);
}

static void BrowseFolder()
{
    BROWSEINFOW bi{};
    bi.lpszTitle = L"Choose where ez gentoo should live";
    PIDLIST_ABSOLUTE pidl = SHBrowseForFolderW(&bi);
    if (!pidl) return;
    wchar_t path[MAX_PATH]{};
    SHGetPathFromIDListW(pidl, path);
    CoTaskMemFree(pidl);
    SetWindowTextW(g_app.installDir, path);
}

static void PickImage()
{
    wchar_t path[MAX_PATH]{};
    OPENFILENAMEW ofn{ sizeof(ofn) };
    ofn.lpstrFile = path;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrFilter = L"VM images\0*.vhdx;*.qcow2\0All files\0*.*\0";
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;
    if (GetOpenFileNameW(&ofn)) SetWindowTextW(g_app.imageSource, path);
}

static HWND Add(HWND parent, const wchar_t* cls, const wchar_t* text, DWORD style, int id, int x, int y, int w, int h)
{
    HWND hwnd = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h, parent, (HMENU)(INT_PTR)id, GetModuleHandleW(nullptr), nullptr);
    SendMessageW(hwnd, WM_SETFONT, (WPARAM)g_uiFont, TRUE);
    return hwnd;
}

static void AddLabel(HWND parent, const wchar_t* text, int x, int y, int w, int h)
{
    Add(parent, L"STATIC", text, 0, 0, x, y, w, h);
}

static void CreateUi(HWND hwnd)
{
    g_titleFont = CreateFontW(-30, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Poppins");
    g_uiFont = CreateFontW(-16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Poppins");

    HWND title = Add(hwnd, L"STATIC", L"ez gentoo", 0, 0, 24, 18, 240, 42);
    SendMessageW(title, WM_SETFONT, (WPARAM)g_titleFont, TRUE);
    Add(hwnd, L"STATIC", L"Gentoo for larpers. Configure it, press install, go touch grass for a bit.", 0, 0, 26, 58, 760, 24);

    AddLabel(hwnd, L"VM name", 26, 102, 140, 22);
    g_app.vmName = Add(hwnd, L"EDIT", FindDefaultVmName().c_str(), WS_BORDER | ES_AUTOHSCROLL, IdVmName, 170, 98, 260, 28);

    AddLabel(hwnd, L"Install folder", 26, 140, 140, 22);
    g_app.installDir = Add(hwnd, L"EDIT", DefaultInstallDir().c_str(), WS_BORDER | ES_AUTOHSCROLL, IdInstallDir, 170, 136, 520, 28);
    Add(hwnd, L"BUTTON", L"Browse", BS_PUSHBUTTON, IdBrowse, 704, 136, 110, 28);

    AddLabel(hwnd, L"Image URL or file", 26, 178, 140, 22);
    g_app.imageSource = Add(hwnd, L"EDIT", L"https://github.com/Pocimin/ez-gentoo/releases/latest/download/ez-gentoo-base.vhdx", WS_BORDER | ES_AUTOHSCROLL, IdImageSource, 170, 174, 520, 28);
    Add(hwnd, L"BUTTON", L"Pick image", BS_PUSHBUTTON, IdPickImage, 704, 174, 110, 28);

    AddLabel(hwnd, L"RAM GB", 26, 218, 80, 22);
    g_app.ram = Add(hwnd, L"EDIT", L"4", WS_BORDER | ES_NUMBER, IdRam, 110, 214, 70, 28);
    AddLabel(hwnd, L"CPU cores", 206, 218, 90, 22);
    g_app.cpu = Add(hwnd, L"EDIT", L"4", WS_BORDER | ES_NUMBER, IdCpu, 302, 214, 70, 28);
    AddLabel(hwnd, L"Disk GB", 398, 218, 80, 22);
    g_app.disk = Add(hwnd, L"EDIT", L"40", WS_BORDER | ES_NUMBER, IdDisk, 482, 214, 70, 28);

    Add(hwnd, L"BUTTON", L"Install / Start", BS_DEFPUSHBUTTON, IdInstall, 26, 268, 150, 38);
    Add(hwnd, L"BUTTON", L"Connect", BS_PUSHBUTTON, IdConnect, 188, 268, 110, 38);
    Add(hwnd, L"BUTTON", L"Stop VM", BS_PUSHBUTTON, IdStop, 310, 268, 110, 38);

    g_app.status = Add(hwnd, L"STATIC", L"Ready", 0, IdStatus, 26, 328, 788, 24);
    g_app.progress = Add(hwnd, PROGRESS_CLASSW, L"", 0, IdProgress, 26, 358, 788, 22);
    SendMessageW(g_app.progress, PBM_SETRANGE, 0, MAKELPARAM(0, 100));

    g_app.log = Add(hwnd, L"LISTBOX", L"", WS_BORDER | WS_VSCROLL | LBS_NOINTEGRALHEIGHT, IdLog, 26, 398, 788, 220);
}

static void LoadBundledFont()
{
    wchar_t exe[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::filesystem::path font = std::filesystem::path(exe).parent_path() / "assets" / "fonts" / "Poppins-Regular.ttf";
    if (std::filesystem::exists(font)) AddFontResourceExW(font.c_str(), FR_PRIVATE, nullptr);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    switch (msg)
    {
    case WM_CREATE:
        g_app.hwnd = hwnd;
        LoadBundledFont();
        CreateUi(hwnd);
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wParam))
        {
        case IdBrowse:
            BrowseFolder();
            return 0;
        case IdPickImage:
            PickImage();
            return 0;
        case IdInstall:
            if (!g_app.busy) { SetBusy(true); std::thread(InstallStartConnect, ReadSettings()).detach(); }
            return 0;
        case IdConnect:
            if (!g_app.busy) { SetBusy(true); std::thread(Connect, ReadSettings()).detach(); }
            return 0;
        case IdStop:
            if (!g_app.busy) { SetBusy(true); std::thread(StopVm, ReadSettings()).detach(); }
            return 0;
        }
        break;
    case WM_APP_LOG:
        if (wParam == 1)
        {
            SetBusy(false);
            return 0;
        }
        if (lParam)
        {
            auto* line = (std::wstring*)lParam;
            AddLogLine(*line);
            delete line;
        }
        return 0;
    case WM_CTLCOLORSTATIC:
        SetBkMode((HDC)wParam, TRANSPARENT);
        return (LRESULT)GetStockObject(WHITE_BRUSH);
    case WM_DESTROY:
        DeleteObject(g_titleFont);
        DeleteObject(g_uiFont);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

int APIENTRY wWinMain(HINSTANCE hInstance, HINSTANCE, LPWSTR, int)
{
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    WSADATA wsa{};
    WSAStartup(MAKEWORD(2, 2), &wsa);

    INITCOMMONCONTROLSEX icc{ sizeof(icc), ICC_PROGRESS_CLASS };
    InitCommonControlsEx(&icc);

    WNDCLASSEXW wc{ sizeof(wc) };
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(WHITE_BRUSH);
    wc.lpszClassName = L"EzGentoo";
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowW(wc.lpszClassName, L"ez gentoo", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 860, 680, nullptr, nullptr, hInstance, nullptr);
    ShowWindow(hwnd, SW_SHOWDEFAULT);
    UpdateWindow(hwnd);

    wchar_t exe[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    if (std::filesystem::path(exe).stem().wstring().find(L"Installer") != std::wstring::npos)
    {
        SetBusy(true);
        std::thread(InstallStartConnect, ReadSettings()).detach();
    }

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0))
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    WSACleanup();
    CoUninitialize();
    return 0;
}
