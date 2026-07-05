#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commdlg.h>
#include <shlobj.h>
#include <shellapi.h>
#include <urlmon.h>
#include <wincrypt.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <d3d11.h>
#include <tchar.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "imgui.h"
#include "imgui_impl_dx11.h"
#include "imgui_impl_win32.h"

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "urlmon.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "comdlg32.lib")

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

static ID3D11Device* g_pd3dDevice = nullptr;
static ID3D11DeviceContext* g_pd3dDeviceContext = nullptr;
static IDXGISwapChain* g_pSwapChain = nullptr;
static UINT g_ResizeWidth = 0, g_ResizeHeight = 0;
static ID3D11RenderTargetView* g_mainRenderTargetView = nullptr;

static bool CreateDeviceD3D(HWND hWnd);
static void CleanupDeviceD3D();
static void CreateRenderTarget();
static void CleanupRenderTarget();
static LRESULT WINAPI WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);

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
    char vmName[128] = "EzGentoo";
    char installDir[512]{};
    char imageSource[1024] = "http://136.243.8.214:8088/ez-gentoo-base.vhdx";
    int ramGb = 4;
    int cpuCount = 4;
    int diskGb = 40;
    int vncDisplay = 1;
    int vncPort = 5901;
    int progress = 0;
    bool busy = false;
    bool autoRun = false;
    std::string status = "Ready";
    std::string currentIp;
    std::vector<std::string> log;
    std::mutex mutex;
};

static void Log(AppState& app, const std::string& msg)
{
    SYSTEMTIME t;
    GetLocalTime(&t);
    char line[1400];
    snprintf(line, sizeof(line), "%02d:%02d:%02d  %s", t.wHour, t.wMinute, t.wSecond, msg.c_str());
    std::lock_guard<std::mutex> lock(app.mutex);
    app.log.emplace_back(line);
    if (app.log.size() > 500) app.log.erase(app.log.begin());
}

static void SetStatus(AppState& app, const std::string& msg, int progress)
{
    {
        std::lock_guard<std::mutex> lock(app.mutex);
        app.status = msg;
        app.progress = std::clamp(progress, 0, 100);
    }
    Log(app, msg);
}

static void RequireOk(AppState& app, const CommandResult& r, const std::string& what)
{
    if (r.code != 0)
    {
        Log(app, r.output);
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

static void EnsureTooling(AppState& app)
{
    RequireOk(app, PowerShell(L"if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw 'Hyper-V PowerShell tools are missing. Enable Hyper-V first.' }"), "Hyper-V check");

    if (!FileExists(L"C:\\Program Files\\TigerVNC\\vncviewer.exe"))
    {
        Log(app, "TigerVNC missing. Asking winget to install it.");
        RequireOk(app, RunHidden(L"winget.exe", L"install --id TigerVNC.TigerVNC --exact --accept-source-agreements --accept-package-agreements"), "TigerVNC install");
    }
}

static std::wstring EnsureImage(AppState& app)
{
    std::wstring installDir = Utf8ToWide(app.installDir);
    std::wstring source = Utf8ToWide(app.imageSource);
    std::filesystem::create_directories(installDir);
    std::wstring imagePath = installDir + L"\\ez-gentoo-base.vhdx";

    if (!FileExists(imagePath))
    {
        if (StartsWithHttp(source))
        {
            Log(app, "Downloading base image. This is the long part.");
            HRESULT hr = URLDownloadToFileW(nullptr, source.c_str(), imagePath.c_str(), 0, nullptr);
            if (FAILED(hr)) throw std::runtime_error("download failed");
        }
        else if (FileExists(source) && source.size() >= 5 && source.substr(source.size() - 5) == L".vhdx")
        {
            Log(app, "Copying local VHDX.");
            std::filesystem::copy_file(source, imagePath, std::filesystem::copy_options::overwrite_existing);
        }
        else if (FileExists(source) && source.size() >= 6 && source.substr(source.size() - 6) == L".qcow2")
        {
            std::wstring qemu = FindQemuImg();
            if (qemu.empty())
            {
                Log(app, "qemu-img missing. Asking winget to install it.");
                RequireOk(app, RunHidden(L"winget.exe", L"install --id cloudbase.qemu-img --exact --accept-source-agreements --accept-package-agreements"), "qemu-img install");
                qemu = FindQemuImg();
            }
            if (qemu.empty()) throw std::runtime_error("qemu-img not found");
            Log(app, "Converting QCOW2 to VHDX.");
            RequireOk(app, RunHidden(qemu, L"convert -p -O vhdx \"" + source + L"\" \"" + imagePath + L"\""), "qemu-img convert");
        }
        else
        {
            throw std::runtime_error("image must be a URL, .vhdx, or .qcow2");
        }
    }
    else
    {
        Log(app, "Base image already exists.");
    }

    long long targetBytes = (long long)app.diskGb * 1024LL * 1024LL * 1024LL;
    std::wstringstream resize;
    resize << L"$vhd = Get-VHD -Path " << PsQuote(imagePath) << L"; "
           << L"if ($vhd.Size -lt " << targetBytes << L") { Resize-VHD -Path "
           << PsQuote(imagePath) << L" -SizeBytes " << targetBytes << L" }";
    RequireOk(app, PowerShell(resize.str()), "disk resize");
    return imagePath;
}

static void EnsureVm(AppState& app, const std::wstring& imagePath)
{
    std::wstring vm = Utf8ToWide(app.vmName);
    std::wstring vmDir = Utf8ToWide(app.installDir) + L"\\vm";
    std::filesystem::create_directories(vmDir);
    long long memoryBytes = (long long)app.ramGb * 1024LL * 1024LL * 1024LL;
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
       << L"Set-VMProcessor -VMName " << PsQuote(vm) << L" -Count " << app.cpuCount << L"; "
       << L"Set-VMMemory -VMName " << PsQuote(vm)
       << L" -DynamicMemoryEnabled $true -MinimumBytes " << minBytes
       << L" -StartupBytes " << memoryBytes
       << L" -MaximumBytes " << memoryBytes;

    RequireOk(app, PowerShell(ps.str()), "VM create/configure");
}

static void StartVm(AppState& app)
{
    std::wstring vm = Utf8ToWide(app.vmName);
    std::wstring ps = L"$vm = Get-VM -Name " + PsQuote(vm) + L"; if ($vm.State -ne 'Running') { Start-VM -Name " + PsQuote(vm) + L" }";
    RequireOk(app, PowerShell(ps), "VM start");
}

static std::vector<std::string> CandidateIps(AppState& app)
{
    std::wstring vm = Utf8ToWide(app.vmName);
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

static std::string WaitForVnc(AppState& app)
{
    std::vector<std::string> seen;
    for (int i = 0; i < 75; ++i)
    {
        for (const auto& ip : CandidateIps(app))
        {
            if (std::find(seen.begin(), seen.end(), ip) == seen.end())
            {
                seen.push_back(ip);
                Log(app, "Found candidate IP " + ip);
            }
            if (TestTcp(ip, app.vncPort)) return ip;
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

static void InstallStartConnect(AppState& app)
{
    try
    {
        SetStatus(app, "Checking Windows bits...", 5);
        EnsureTooling(app);
        if (VmExists(Utf8ToWide(app.vmName)))
        {
            SetStatus(app, std::string("Using existing VM ") + app.vmName + "...", 45);
        }
        else
        {
            SetStatus(app, "Preparing Gentoo image...", 20);
            std::wstring image = EnsureImage(app);
            SetStatus(app, "Creating Hyper-V VM...", 45);
            EnsureVm(app, image);
        }
        SetStatus(app, "Starting Gentoo...", 60);
        StartVm(app);
        SetStatus(app, "Finding the VM on Hyper-V's chaos network...", 75);
        app.currentIp = WaitForVnc(app);
        SetStatus(app, "Opening Gentoo desktop...", 95);
        OpenVnc(app.currentIp, app.vncDisplay);
        SetStatus(app, "Done. Go larp.", 100);
    }
    catch (const std::exception& e)
    {
        SetStatus(app, std::string("Failed: ") + e.what(), 0);
    }
    app.busy = false;
}

static void Connect(AppState& app)
{
    try
    {
        SetStatus(app, "Finding the VM...", 60);
        app.currentIp = WaitForVnc(app);
        OpenVnc(app.currentIp, app.vncDisplay);
        SetStatus(app, "Desktop opened.", 100);
    }
    catch (const std::exception& e)
    {
        SetStatus(app, std::string("Failed: ") + e.what(), 0);
    }
    app.busy = false;
}

static void StopVm(AppState& app)
{
    try
    {
        SetStatus(app, "Stopping VM...", 30);
        RequireOk(app, PowerShell(L"Stop-VM -Name " + PsQuote(Utf8ToWide(app.vmName)) + L" -TurnOff -Force"), "VM stop");
        SetStatus(app, "VM stopped.", 0);
    }
    catch (const std::exception& e)
    {
        SetStatus(app, std::string("Failed: ") + e.what(), 0);
    }
    app.busy = false;
}

static void BrowseFolder(AppState& app)
{
    BROWSEINFOW bi{};
    bi.lpszTitle = L"Choose where ez gentoo should live";
    PIDLIST_ABSOLUTE pidl = SHBrowseForFolderW(&bi);
    if (!pidl) return;
    wchar_t path[MAX_PATH]{};
    SHGetPathFromIDListW(pidl, path);
    CoTaskMemFree(pidl);
    strncpy_s(app.installDir, WideToUtf8(path).c_str(), sizeof(app.installDir) - 1);
}

static void PickImage(AppState& app)
{
    wchar_t path[MAX_PATH]{};
    OPENFILENAMEW ofn{ sizeof(ofn) };
    ofn.lpstrFile = path;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrFilter = L"VM images\0*.vhdx;*.qcow2\0All files\0*.*\0";
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;
    if (GetOpenFileNameW(&ofn))
        strncpy_s(app.imageSource, WideToUtf8(path).c_str(), sizeof(app.imageSource) - 1);
}

static void DrawButtonRow(AppState& app)
{
    ImGui::BeginDisabled(app.busy);
    if (ImGui::Button("Install / Start", ImVec2(162, 40)) && !app.busy)
    {
        app.busy = true;
        std::thread(InstallStartConnect, std::ref(app)).detach();
    }
    ImGui::SameLine();
    if (ImGui::Button("Connect", ImVec2(116, 40)) && !app.busy)
    {
        app.busy = true;
        std::thread(Connect, std::ref(app)).detach();
    }
    ImGui::SameLine();
    if (ImGui::Button("Stop VM", ImVec2(116, 40)) && !app.busy)
    {
        app.busy = true;
        std::thread(StopVm, std::ref(app)).detach();
    }
    ImGui::EndDisabled();
}

static void DrawUi(AppState& app)
{
    ImGuiIO& io = ImGui::GetIO();
    ImDrawList* bg = ImGui::GetBackgroundDrawList();
    ImVec2 screen = io.DisplaySize;
    bg->AddRectFilled(ImVec2(0, 0), screen, IM_COL32(14, 14, 15, 255));
    bg->AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(screen.x, 180), IM_COL32(32, 32, 34, 255), IM_COL32(22, 22, 24, 255), IM_COL32(14, 14, 15, 0), IM_COL32(14, 14, 15, 0));

    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(screen);
    ImGui::Begin("ez gentoo", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoBackground);

    std::string status;
    int progress = 0;
    std::vector<std::string> log;
    {
        std::lock_guard<std::mutex> lock(app.mutex);
        status = app.status;
        progress = app.progress;
        log = app.log;
    }

    ImGui::SetCursorPos(ImVec2(34, 28));
    ImGui::TextColored(ImVec4(0.96f, 0.96f, 0.96f, 1.0f), "ez gentoo");
    ImGui::SetCursorPosX(36);
    ImGui::TextColored(ImVec4(0.62f, 0.63f, 0.66f, 1.0f), "gentoo for larpers. one click, one vm, maximum fake wizard energy.");

    ImGui::SetCursorPos(ImVec2(34, 96));
    ImGui::BeginChild("config", ImVec2(620, 310), true, ImGuiWindowFlags_NoScrollbar);
    ImGui::TextColored(ImVec4(0.92f, 0.92f, 0.94f, 1.0f), "setup");
    ImGui::Spacing();
    ImGui::BeginDisabled(app.busy);
    ImGui::TextDisabled("VM name");
    ImGui::SetNextItemWidth(-1);
    ImGui::InputText("##vm", app.vmName, IM_ARRAYSIZE(app.vmName));

    ImGui::TextDisabled("Install folder");
    ImGui::SetNextItemWidth(ImGui::GetContentRegionAvail().x - 106);
    ImGui::InputText("##dir", app.installDir, IM_ARRAYSIZE(app.installDir));
    ImGui::SameLine();
    if (ImGui::Button("Browse", ImVec2(96, 0))) BrowseFolder(app);

    ImGui::TextDisabled("Image URL or file");
    ImGui::SetNextItemWidth(ImGui::GetContentRegionAvail().x - 106);
    ImGui::InputText("##image", app.imageSource, IM_ARRAYSIZE(app.imageSource));
    ImGui::SameLine();
    if (ImGui::Button("Pick", ImVec2(96, 0))) PickImage(app);

    ImGui::PushItemWidth(150);
    ImGui::SliderInt("RAM GB", &app.ramGb, 2, 64);
    ImGui::SameLine(240);
    ImGui::SliderInt("CPU cores", &app.cpuCount, 1, 32);
    ImGui::SliderInt("Disk GB", &app.diskGb, 20, 512);
    ImGui::PopItemWidth();
    ImGui::EndDisabled();
    ImGui::Spacing();
    DrawButtonRow(app);
    ImGui::EndChild();

    ImGui::SetCursorPos(ImVec2(674, 96));
    ImGui::BeginChild("status", ImVec2(screen.x - 708, 310), true, ImGuiWindowFlags_NoScrollbar);
    ImGui::TextColored(ImVec4(0.92f, 0.92f, 0.94f, 1.0f), "status");
    ImGui::Spacing();
    ImGui::TextWrapped("%s", status.c_str());
    ImGui::Spacing();
    ImGui::ProgressBar(progress / 100.0f, ImVec2(-1, 18), "");
    ImGui::Spacing();
    ImGui::TextDisabled("image");
    ImGui::TextWrapped("%s", app.imageSource);
    ImGui::Spacing();
    ImGui::TextDisabled("detected ip");
    ImGui::TextWrapped("%s", app.currentIp.empty() ? "not yet" : app.currentIp.c_str());
    ImGui::EndChild();

    ImGui::SetCursorPos(ImVec2(34, 426));
    ImGui::BeginChild("log", ImVec2(screen.x - 68, screen.y - 460), true);
    ImGui::TextColored(ImVec4(0.92f, 0.92f, 0.94f, 1.0f), "log");
    ImGui::Separator();
    for (const auto& line : log) ImGui::TextUnformatted(line.c_str());
    if (ImGui::GetScrollY() >= ImGui::GetScrollMaxY()) ImGui::SetScrollHereY(1.0f);
    ImGui::EndChild();
    ImGui::End();
}

int APIENTRY wWinMain(HINSTANCE hInstance, HINSTANCE, LPWSTR, int)
{
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    WSADATA wsa{};
    WSAStartup(MAKEWORD(2, 2), &wsa);

    AppState app;
    strncpy_s(app.installDir, WideToUtf8(DefaultInstallDir()).c_str(), sizeof(app.installDir) - 1);
    strncpy_s(app.vmName, WideToUtf8(FindDefaultVmName()).c_str(), sizeof(app.vmName) - 1);
    wchar_t exe[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring exeName = std::filesystem::path(exe).stem().wstring();
    app.autoRun = exeName.find(L"Installer") != std::wstring::npos;

    WNDCLASSEXW wc = { sizeof(wc), CS_CLASSDC, WndProc, 0L, 0L, hInstance, nullptr, nullptr, nullptr, nullptr, L"EzGentoo", nullptr };
    RegisterClassExW(&wc);
    HWND hwnd = CreateWindowW(wc.lpszClassName, L"ez gentoo", WS_OVERLAPPEDWINDOW, 100, 100, 1040, 720, nullptr, nullptr, wc.hInstance, nullptr);

    if (!CreateDeviceD3D(hwnd))
    {
        CleanupDeviceD3D();
        UnregisterClassW(wc.lpszClassName, wc.hInstance);
        return 1;
    }

    ShowWindow(hwnd, SW_SHOWDEFAULT);
    UpdateWindow(hwnd);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    ImGui::StyleColorsDark();
    ImGuiStyle& style = ImGui::GetStyle();
    style.WindowPadding = ImVec2(0, 0);
    style.WindowBorderSize = 0;
    style.WindowRounding = 0;
    style.ChildRounding = 12;
    style.ChildBorderSize = 1;
    style.FrameRounding = 8;
    style.GrabRounding = 8;
    style.PopupRounding = 8;
    style.ScrollbarSize = 4;
    style.ScrollbarRounding = 8;
    style.ItemSpacing = ImVec2(10, 8);
    ImVec4* colors = style.Colors;
    colors[ImGuiCol_Text] = ImVec4(0.94f, 0.94f, 0.95f, 1.00f);
    colors[ImGuiCol_TextDisabled] = ImVec4(0.52f, 0.53f, 0.56f, 1.00f);
    colors[ImGuiCol_WindowBg] = ImVec4(0.06f, 0.06f, 0.065f, 1.00f);
    colors[ImGuiCol_ChildBg] = ImVec4(0.095f, 0.095f, 0.105f, 0.96f);
    colors[ImGuiCol_Border] = ImVec4(1.00f, 1.00f, 1.00f, 0.07f);
    colors[ImGuiCol_FrameBg] = ImVec4(0.13f, 0.13f, 0.145f, 1.00f);
    colors[ImGuiCol_FrameBgHovered] = ImVec4(0.18f, 0.18f, 0.20f, 1.00f);
    colors[ImGuiCol_FrameBgActive] = ImVec4(0.23f, 0.23f, 0.25f, 1.00f);
    colors[ImGuiCol_Button] = ImVec4(0.18f, 0.18f, 0.20f, 1.00f);
    colors[ImGuiCol_ButtonHovered] = ImVec4(0.25f, 0.25f, 0.28f, 1.00f);
    colors[ImGuiCol_ButtonActive] = ImVec4(0.86f, 0.86f, 0.88f, 1.00f);
    colors[ImGuiCol_SliderGrab] = ImVec4(0.90f, 0.90f, 0.92f, 1.00f);
    colors[ImGuiCol_SliderGrabActive] = ImVec4(1.00f, 1.00f, 1.00f, 1.00f);
    colors[ImGuiCol_PlotHistogram] = ImVec4(0.92f, 0.92f, 0.94f, 1.00f);
    wchar_t exeDir[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exeDir, MAX_PATH);
    auto fontPath = std::filesystem::path(exeDir).parent_path() / "assets" / "fonts" / "Poppins-Regular.ttf";
    if (std::filesystem::exists(fontPath))
        io.FontDefault = io.Fonts->AddFontFromFileTTF(fontPath.string().c_str(), 16.0f);
    ImGui_ImplWin32_Init(hwnd);
    ImGui_ImplDX11_Init(g_pd3dDevice, g_pd3dDeviceContext);

    if (app.autoRun)
    {
        app.busy = true;
        std::thread(InstallStartConnect, std::ref(app)).detach();
    }

    bool done = false;
    while (!done)
    {
        MSG msg;
        while (PeekMessage(&msg, nullptr, 0U, 0U, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
            if (msg.message == WM_QUIT) done = true;
        }
        if (done) break;

        if (g_ResizeWidth != 0 && g_ResizeHeight != 0)
        {
            CleanupRenderTarget();
            g_pSwapChain->ResizeBuffers(0, g_ResizeWidth, g_ResizeHeight, DXGI_FORMAT_UNKNOWN, 0);
            g_ResizeWidth = g_ResizeHeight = 0;
            CreateRenderTarget();
        }

        ImGui_ImplDX11_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();
        DrawUi(app);
        ImGui::Render();

        const float clear_color[4] = { 0.08f, 0.09f, 0.10f, 1.00f };
        g_pd3dDeviceContext->OMSetRenderTargets(1, &g_mainRenderTargetView, nullptr);
        g_pd3dDeviceContext->ClearRenderTargetView(g_mainRenderTargetView, clear_color);
        ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
        g_pSwapChain->Present(1, 0);
    }

    ImGui_ImplDX11_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    CleanupDeviceD3D();
    DestroyWindow(hwnd);
    UnregisterClassW(wc.lpszClassName, wc.hInstance);
    WSACleanup();
    CoUninitialize();
    return 0;
}

static bool CreateDeviceD3D(HWND hWnd)
{
    DXGI_SWAP_CHAIN_DESC sd{};
    sd.BufferCount = 2;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hWnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    UINT flags = 0;
    D3D_FEATURE_LEVEL featureLevel;
    const D3D_FEATURE_LEVEL featureLevelArray[2] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0 };
    HRESULT res = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, featureLevelArray, 2,
        D3D11_SDK_VERSION, &sd, &g_pSwapChain, &g_pd3dDevice, &featureLevel, &g_pd3dDeviceContext);
    if (res == DXGI_ERROR_UNSUPPORTED)
        res = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, featureLevelArray, 2,
            D3D11_SDK_VERSION, &sd, &g_pSwapChain, &g_pd3dDevice, &featureLevel, &g_pd3dDeviceContext);
    if (res != S_OK) return false;
    CreateRenderTarget();
    return true;
}

static void CleanupDeviceD3D()
{
    CleanupRenderTarget();
    if (g_pSwapChain) { g_pSwapChain->Release(); g_pSwapChain = nullptr; }
    if (g_pd3dDeviceContext) { g_pd3dDeviceContext->Release(); g_pd3dDeviceContext = nullptr; }
    if (g_pd3dDevice) { g_pd3dDevice->Release(); g_pd3dDevice = nullptr; }
}

static void CreateRenderTarget()
{
    ID3D11Texture2D* pBackBuffer = nullptr;
    g_pSwapChain->GetBuffer(0, IID_PPV_ARGS(&pBackBuffer));
    g_pd3dDevice->CreateRenderTargetView(pBackBuffer, nullptr, &g_mainRenderTargetView);
    pBackBuffer->Release();
}

static void CleanupRenderTarget()
{
    if (g_mainRenderTargetView) { g_mainRenderTargetView->Release(); g_mainRenderTargetView = nullptr; }
}

static LRESULT WINAPI WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    if (ImGui_ImplWin32_WndProcHandler(hWnd, msg, wParam, lParam))
        return true;
    switch (msg)
    {
    case WM_SIZE:
        if (wParam != SIZE_MINIMIZED) { g_ResizeWidth = LOWORD(lParam); g_ResizeHeight = HIWORD(lParam); }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hWnd, msg, wParam, lParam);
}
