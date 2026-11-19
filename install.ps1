# Mario Tennis Fever (MTF Recomp) installer for Windows (driven by NUP Studio)
param(
    [string]$Nup = "",
    [string]$Dir = "",
    [string]$ShortcutName = "Mario Tennis Fever",
    [string]$IconPath = "",
    [string]$LauncherUiPath = "",
    [switch]$NoDesktopShortcut
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}
function Say($msg) { Write-Host "[MTF-Recomp] $msg" -ForegroundColor Cyan }

if (-not $Nup -or -not (Test-Path -LiteralPath $Nup)) {
    Say "error: missing .nup file: $Nup"
    exit 1
}
if (-not $Dir) {
    $Dir = Join-Path $env:LOCALAPPDATA "Switch2Recomp\Mario Tennis Fever"
}
$Dir = [System.IO.Path]::GetFullPath($Dir)
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Say "installing into $Dir"

$source = $PSScriptRoot
$globalMsysInstaller = Join-Path $source "..\..\install_msys2.ps1"
$msysRoot = "C:\msys64"
$clang64Prefix = Join-Path $msysRoot "clang64"
$clang64Bin = Join-Path $clang64Prefix "bin"

if (-not (Test-Path -LiteralPath (Join-Path $clang64Bin "clang.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "clang++.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "cmake.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "ninja.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "python.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\SDL3\SDL.h")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\vpx\vpx_decoder.h")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\vma\vk_mem_alloc.h"))) {
    if (-not (Test-Path -LiteralPath $globalMsysInstaller)) {
        Say "error: MSYS2 missing and global installer not found: $globalMsysInstaller"
        exit 1
    }
    & $globalMsysInstaller -Msys $msysRoot
    if ($LASTEXITCODE -ne 0) {
        Say "MSYS2 installation cancelled or failed; stopping recompilation."
        exit 1
    }
}

$pyExe = Join-Path $clang64Bin "python.exe"
$cmakeExe = Join-Path $clang64Bin "cmake.exe"
$ninjaExe = Join-Path $clang64Bin "ninja.exe"
$xlateExe = Join-Path $source "bin\xlate\dmsh_xlate.exe"
foreach ($req in @($pyExe, $cmakeExe, $ninjaExe, $xlateExe, (Join-Path $clang64Bin "clang.exe"), (Join-Path $clang64Bin "clang++.exe"))) {
    if (-not (Test-Path -LiteralPath $req)) {
        Say "error: required component missing: $req"
        exit 1
    }
}

$env:PATH = "$clang64Bin;" + $env:PATH
$env:CLANG64_PREFIX = "C:/msys64/clang64"
$env:PYTHONUTF8 = "1"
$env:PYTHONUNBUFFERED = "1"
$env:PYTHON_JIT = "0"

# Pin to E-cores (logical processors 16+) on Intel 13th/14th-gen to avoid P-core boost instability during heavy Python/C codegen
$proc = [System.Diagnostics.Process]::GetCurrentProcess()
$jobs = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 16))
try {
    $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
    if ($cpuName -match 'Intel.*1[34]\d{3}' -and [Environment]::ProcessorCount -gt 16) {
        $eCoreMask = [int64]0
        for ($c = 16; $c -lt [Math]::Min(63, [Environment]::ProcessorCount); $c++) {
            $eCoreMask = $eCoreMask -bor ([int64]1 -shl $c)
        }
        if ($eCoreMask -gt 0) {
            Say "detected ${cpuName}: pinning codegen & build to E-cores for stability"
            $proc.ProcessorAffinity = [IntPtr]$eCoreMask
            $jobs = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount - 16, 12))
        }
    }
} catch {}

# ---- Global Saves folder (<ParentDir>\Saves\<GameFolderName>) ----
$parentInstallDir = Split-Path -Parent $Dir
$globalSavesRoot = Join-Path $parentInstallDir "Saves"
$globalSaveDir = Join-Path $globalSavesRoot (Split-Path -Leaf $Dir)
New-Item -ItemType Directory -Force -Path $globalSaveDir | Out-Null

$legacyProfileDir = Join-Path $Dir "profile"
if ((Test-Path -LiteralPath $legacyProfileDir) -and -not (Get-ChildItem -LiteralPath $globalSaveDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    Say "migrating existing saves into global folder: $globalSaveDir"
    Copy-Item -Path (Join-Path $legacyProfileDir "*") -Destination $globalSaveDir -Recurse -Force -ErrorAction SilentlyContinue
}

$workRoot = Join-Path $Dir "_work"
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---- 1. Extract ExeFS & RomFS from .nup ----
$gameDir = Join-Path $Dir "game"
$env:MTF_CONTENT_ROOT = $gameDir
$env:MTF_GENERATED_ROOT = $Dir
$updateDir = Join-Path $gameDir "updates\327680"
$exefsDir = Join-Path $updateDir "exefs"
$romfsDir = Join-Path $updateDir "romfs"
if (-not (Test-Path -LiteralPath (Join-Path $exefsDir "main")) -or -not (Test-Path -LiteralPath $romfsDir)) {
    Say "extracting ExeFS and RomFS from .nup..."
    $auditJson = Join-Path $workRoot "nup-audit.json"
    Push-Location $source
    try {
        & $pyExe -m tools.nup_audit $Nup --out $auditJson
        if ($LASTEXITCODE -ne 0) { Say "nup_audit failed"; exit 1 }
        & $pyExe -m tools.nup_extract $auditJson --out $gameDir
        if ($LASTEXITCODE -ne 0) { Say "nup_extract failed"; exit 1 }
    } finally {
        Pop-Location
    }
    $baseDir = Join-Path $gameDir "base"
    if (Test-Path -LiteralPath $baseDir) {
        Remove-Item -Recurse -Force $baseDir -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $exefsDir "main"))) {
    Say "error: exefs/main missing after extraction in $exefsDir"
    exit 1
}

# ---- 2. Lift main & sdk to C ----
$genRoot = Join-Path $workRoot "gen"
$genMain = Join-Path $genRoot "main"
$genSdk = Join-Path $genRoot "sdk"
$genNro = Join-Path $genRoot "nro"
foreach ($mod in @("main", "sdk")) {
    $modOut = Join-Path $genRoot $mod
    if (-not (Get-ChildItem -Path $modOut -Filter "*.c" -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Say "lifting ARM64 module $mod to C..."
        New-Item -ItemType Directory -Force -Path $modOut | Out-Null
        & $pyExe (Join-Path $source "recomp\lift.py") --exefs $exefsDir --out $modOut --modules $mod --jobs $jobs
        if ($LASTEXITCODE -ne 0) { Say "recomp/lift.py ($mod) failed"; exit 1 }
    }
}

$toolchainFile = (Join-Path $source "tools\cmake\llvm-mingw.cmake") -replace "\\", "/"
$depsFwd = $clang64Prefix -replace "\\", "/"
$cpuLevel = "v3"

# ---- 3. Capture NRO & lift NRO ----
$capturedNro = Join-Path $workRoot "captured.nro"
if (-not (Test-Path -LiteralPath $capturedNro)) {
    Say "building capture binary to extract runtime NRO..."
    $glueCap = Join-Path $workRoot "glue-capture"
    $cmakeCap = Join-Path $workRoot "cmake-capture"
    $binCap = Join-Path $workRoot "bin-capture"
    New-Item -ItemType Directory -Force -Path $glueCap, $cmakeCap, $binCap | Out-Null

    & $pyExe (Join-Path $source "recomp\glue.py") --generated $genMain $genSdk --out $glueCap --exefs $exefsDir --romfs $romfsDir --user $globalSaveDir
    if ($LASTEXITCODE -ne 0) { Say "glue.py (capture) failed"; exit 1 }

    $genListCap = (($genMain -replace "\\", "/") + ";" + ($genSdk -replace "\\", "/"))
    & $cmakeExe -S $source -B $cmakeCap -G Ninja `
        "-DCMAKE_TOOLCHAIN_FILE=$toolchainFile" `
        -DCMAKE_BUILD_TYPE=Release `
        "-DCMAKE_MAKE_PROGRAM=$($ninjaExe -replace '\\', '/')" `
        "-DMTF_GENERATED_DIRS=$genListCap" `
        "-DMTF_GLUE_DIR=$($glueCap -replace '\\', '/')" `
        "-DMTF_OUTPUT_DIR=$($binCap -replace '\\', '/')" `
        "-DMTF_DEPS_DIR=$depsFwd" `
        "-DMTF_CPU_LEVEL=$cpuLevel"
    if ($LASTEXITCODE -ne 0) { Say "cmake configure (capture) failed"; exit 1 }

    & $cmakeExe --build $cmakeCap --parallel $jobs
    if ($LASTEXITCODE -ne 0) { Say "cmake build (capture) failed"; exit 1 }

    $capExe = Join-Path $binCap "mtf-recomp.exe"
    if (-not (Test-Path -LiteralPath $capExe)) { Say "capture exe missing: $capExe"; exit 1 }

    Say "running capture binary to extract NRO..."
    $env:MTF_NRO_CAPTURE = $capturedNro
    Push-Location $workRoot
    try {
        & $capExe --capture-nro --exefs $exefsDir --romfs $romfsDir --profile $globalSaveDir
    } finally {
        Pop-Location
        Remove-Item Env:\MTF_NRO_CAPTURE -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $capturedNro)) {
        Say "error: failed to capture NRO at $capturedNro"
        exit 1
    }
}

if (-not (Get-ChildItem -Path $genNro -Filter "*.c" -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    Say "lifting NRO to C..."
    New-Item -ItemType Directory -Force -Path $genNro | Out-Null
    & $pyExe (Join-Path $source "recomp\nro_lift.py") --exefs $exefsDir --nro $capturedNro --out $genNro --jobs $jobs
    if ($LASTEXITCODE -ne 0) { Say "recomp/nro_lift.py failed"; exit 1 }
}

# ---- 4. Extract & translate shaders ----
$shadersDst = Join-Path $Dir "shaders"
if (-not (Test-Path -LiteralPath $shadersDst)) {
    Say "extracting and translating shaders..."
    $shadersSrc = Join-Path $workRoot "shaders-src"
    New-Item -ItemType Directory -Force -Path $shadersSrc | Out-Null
    & $pyExe (Join-Path $source "tools\shaders\extract.py") --archive (Join-Path $romfsDir "42") --nro $capturedNro --out $shadersSrc --jobs $jobs
    if ($LASTEXITCODE -ne 0) { Say "shaders/extract.py failed"; exit 1 }

    & $pyExe (Join-Path $source "tools\shaders\translate.py") --src $shadersSrc --out $shadersDst --xlate $xlateExe --jobs $jobs
    if ($LASTEXITCODE -ne 0) { Say "shaders/translate.py failed"; exit 1 }

    & $pyExe (Join-Path $source "tools\shaders\translate.py") --src $shadersSrc --out $shadersDst --xlate $xlateExe --jobs $jobs --mvprev
    if ($LASTEXITCODE -ne 0) { Say "shaders/translate.py (--mvprev) failed"; exit 1 }
}

# ---- 5. Build final portable mtf-recomp.exe ----
$mtfExe = Join-Path $Dir "mtf-recomp.exe"
if (-not (Test-Path -LiteralPath $mtfExe)) {
    Say "compiling final portable mtf-recomp.exe with Clang64 + Ninja..."
    $glueFinal = Join-Path $workRoot "glue-portable"
    $cmakeFinal = Join-Path $workRoot "cmake-portable"
    $binFinal = Join-Path $workRoot "bin-portable"
    New-Item -ItemType Directory -Force -Path $glueFinal, $cmakeFinal, $binFinal | Out-Null

    & $pyExe (Join-Path $source "recomp\glue.py") --generated $genMain $genSdk $genNro --out $glueFinal `
        --portable --exefs "game/updates/327680/exefs" --romfs "game/updates/327680/romfs" --user "profile" --check-exefs $exefsDir
    if ($LASTEXITCODE -ne 0) { Say "glue.py (portable) failed"; exit 1 }

    $genListFinal = (($genMain -replace "\\", "/") + ";" + ($genSdk -replace "\\", "/") + ";" + ($genNro -replace "\\", "/"))
    & $cmakeExe -S $source -B $cmakeFinal -G Ninja `
        "-DCMAKE_TOOLCHAIN_FILE=$toolchainFile" `
        -DCMAKE_BUILD_TYPE=Release `
        "-DCMAKE_MAKE_PROGRAM=$($ninjaExe -replace '\\', '/')" `
        "-DMTF_GENERATED_DIRS=$genListFinal" `
        "-DMTF_GLUE_DIR=$($glueFinal -replace '\\', '/')" `
        "-DMTF_OUTPUT_DIR=$($binFinal -replace '\\', '/')" `
        "-DMTF_DEPS_DIR=$depsFwd" `
        "-DMTF_CPU_LEVEL=$cpuLevel"
    if ($LASTEXITCODE -ne 0) { Say "cmake configure (final) failed"; exit 1 }

    & $cmakeExe --build $cmakeFinal --parallel $jobs
    if ($LASTEXITCODE -ne 0) { Say "cmake build (final) failed"; exit 1 }

    $builtExe = Join-Path $binFinal "mtf-recomp.exe"
    if (-not (Test-Path -LiteralPath $builtExe)) { Say "error: final exe missing at $builtExe"; exit 1 }
    Copy-Item -LiteralPath $builtExe -Destination $mtfExe -Force

    # Copy required MSYS2 Clang64 runtime DLLs via static PE import-table BFS (zero MSYS2 dependency at runtime)
    $dllCopyPy = Join-Path $workRoot "copy_clang64_dlls.py"
    $pyCode = @'
import os, shutil, struct, sys

def pe_imports(path):
    with open(path, 'rb') as f:
        data = f.read(4096)
        if data[:2] != b'MZ': return []
        pe_off = struct.unpack_from('<I', data, 0x3c)[0]
        f.seek(pe_off)
        hdr = f.read(256)
        if hdr[:4] != b'PE\0\0': return []
        n_sec, = struct.unpack_from('<H', hdr, 6)
        opt_sz, = struct.unpack_from('<H', hdr, 20)
        opt_off = pe_off + 24
        f.seek(opt_off)
        opt = f.read(opt_sz)
        magic, = struct.unpack_from('<H', opt, 0)
        dd_off = 112 if magic == 0x20b else 96
        n_dd, = struct.unpack_from('<I', opt, dd_off - 4)
        f.seek(opt_off + opt_sz)
        secs = []
        for _ in range(n_sec):
            s = f.read(40)
            vsz, va, rsz, rptr = struct.unpack_from('<4I', s, 8)
            secs.append((va, max(vsz, rsz), rptr))
        def r2o(rva):
            for va, sz, rp in secs:
                if va <= rva < va + sz:
                    return rp + (rva - va)
            return None
        def read_cstr(off):
            if off is None: return ''
            f.seek(off)
            buf = f.read(260)
            end = buf.find(b'\0')
            return (buf[:end] if end != -1 else buf).decode('ascii', 'ignore')
        out = []
        if n_dd > 1:
            imp_rva, _ = struct.unpack_from('<2I', opt, dd_off + 8)
            if imp_rva:
                off = r2o(imp_rva)
                while off is not None:
                    f.seek(off)
                    desc = f.read(20)
                    if len(desc) < 20 or desc == b'\0' * 20: break
                    name_rva, = struct.unpack_from('<I', desc, 12)
                    if not name_rva: break
                    n = read_cstr(r2o(name_rva))
                    if n: out.append(n)
                    off += 20
        if n_dd > 13:
            dly_rva, _ = struct.unpack_from('<2I', opt, dd_off + 13 * 8)
            if dly_rva:
                off = r2o(dly_rva)
                while off is not None:
                    f.seek(off)
                    desc = f.read(32)
                    if len(desc) < 32 or desc == b'\0' * 32: break
                    attrs, name_rva = struct.unpack_from('<2I', desc, 0)
                    if not name_rva: break
                    if attrs & 1:
                        n = read_cstr(r2o(name_rva))
                        if n: out.append(n)
                    off += 32
        return out

clang_bin, dst_dir, *roots = sys.argv[1:]
avail = {n.lower(): os.path.join(clang_bin, n) for n in os.listdir(clang_bin) if n.lower().endswith('.dll') and n.lower() != 'vulkan-1.dll'}
seen, queue = set(), list(roots)
while queue:
    cur = queue.pop(0)
    if not os.path.isfile(cur): continue
    for imp in pe_imports(cur):
        key = imp.lower()
        if key in avail and key not in seen:
            seen.add(key)
            src = avail[key]
            shutil.copy2(src, os.path.join(dst_dir, os.path.basename(src)))
            queue.append(src)
'@
    [System.IO.File]::WriteAllText($dllCopyPy, $pyCode, $utf8NoBom)
    & $pyExe $dllCopyPy $clang64Bin $Dir $mtfExe
    if ($LASTEXITCODE -ne 0) { Say "failed to copy runtime DLLs"; exit 1 }
}

# ---- 6. Pre-launch UI, config, shortcuts & Windows uninstaller ----
$repoRoot = Resolve-Path (Join-Path $source "..\..\..")
$isLauncherExe = $false
if ($LauncherUiPath -and (Test-Path -LiteralPath $LauncherUiPath)) {
    $launcherUiSrc = $LauncherUiPath
    $isLauncherExe = $launcherUiSrc.ToLower().EndsWith(".exe")
} else {
    $toolsExe = Join-Path $repoRoot "tools\game_launcher.exe"
    $exeCand = Join-Path $repoRoot "game_launcher.exe"
    if (Test-Path -LiteralPath $toolsExe) { $launcherUiSrc = $toolsExe; $isLauncherExe = $true }
    elseif (Test-Path -LiteralPath $exeCand) { $launcherUiSrc = $exeCand; $isLauncherExe = $true }
    else { $launcherUiSrc = Join-Path $repoRoot "src\game_launcher.py" }
}

$launcherUiDst = Join-Path $Dir $(if ($isLauncherExe) { "game_launcher.exe" } else { "game_launcher.py" })
if (Test-Path -LiteralPath $launcherUiSrc) {
    Copy-Item -LiteralPath $launcherUiSrc -Destination $launcherUiDst -Force
}

$launchConfigPath = Join-Path $Dir "launch_options.json"
$tplPath = Join-Path $source "launch_options_template.json"
if (Test-Path -LiteralPath $tplPath) {
    $tpl = Get-Content -LiteralPath $tplPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tpl.working_dir = $Dir
    $tpl | Add-Member -NotePropertyName "rom_path" -NotePropertyValue $Nup -Force
    $tpl.command = @($mtfExe, "--profile", $globalSaveDir)
    $jsonOut = $tpl | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($launchConfigPath, $jsonOut, $utf8NoBom)
}

$iconDst = Join-Path $Dir "game_icon.ico"
if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
    Copy-Item -LiteralPath $IconPath -Destination $iconDst -Force
} elseif (Test-Path -LiteralPath (Join-Path $source "game_icon.ico")) {
    Copy-Item -LiteralPath (Join-Path $source "game_icon.ico") -Destination $iconDst -Force
}

$pngSrc = Join-Path $source "game_icon.png"
$pngDst = Join-Path $Dir "game_icon.png"
if (Test-Path -LiteralPath $pngSrc) {
    Copy-Item -LiteralPath $pngSrc -Destination $pngDst -Force
}

$runner = Join-Path $Dir "mtf.cmd"
if ($isLauncherExe -and (Test-Path -LiteralPath $launcherUiDst) -and (Test-Path -LiteralPath $launchConfigPath)) {
    $cmdText = @"
@echo off
chcp 65001 >nul
cd /d "%~dp0"
"%~dp0game_launcher.exe" --config "%~dp0launch_options.json" %*
"@
} else {
    $cmdText = @"
@echo off
chcp 65001 >nul
cd /d "%~dp0"
set "MTF_WINDOW_SIZE=1280x720"
"%~dp0mtf-recomp.exe" --profile "$globalSaveDir" %*
"@
}
[System.IO.File]::WriteAllText($runner, $cmdText, $utf8NoBom)

$safeShortcutName = ($ShortcutName -replace '[<>:"/\\|?*]+', ' -').Trim()
if (-not $safeShortcutName) { $safeShortcutName = "Mario Tennis Fever" }

$startMenuPrograms = [Environment]::GetFolderPath("Programs")
$shortcutDirs = @((Join-Path $startMenuPrograms $safeShortcutName))
if (-not $NoDesktopShortcut) {
    $shortcutDirs += [Environment]::GetFolderPath("Desktop")
}

$wsh = New-Object -ComObject WScript.Shell
foreach ($sdir in $shortcutDirs) {
    New-Item -ItemType Directory -Force -Path $sdir | Out-Null
    $linkPath = Join-Path $sdir "$safeShortcutName.lnk"
    $link = $wsh.CreateShortcut($linkPath)
    $link.TargetPath = $runner
    $link.WorkingDirectory = $Dir
    $link.Description = "$safeShortcutName - Native PC port (F11 Fullscreen)"
    if (Test-Path -LiteralPath $iconDst) { $link.IconLocation = "$iconDst,0" }
    $link.Save()
}

# ---- 7. Clean up temporary build files ----
Say "cleaning up temporary build files in $Dir..."
if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
}

# ---- 8. Windows Apps & Features uninstaller ----
$uninstKeyName = "Switch2Recomp_" + ($safeShortcutName -replace '[^A-Za-z0-9_-]', '_')
$uninstRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$uninstKeyName"
$uninstPs1 = Join-Path $Dir "uninstall.ps1"
$desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "$safeShortcutName.lnk"
$startMenuDir = Join-Path ([Environment]::GetFolderPath("Programs")) $safeShortcutName
$eAcute = [char]0x00E9
$eCapAcute = [char]0x00C9
$uninstScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$res = [System.Windows.Forms.MessageBox]::Show(
    "Voulez-vous d${eAcute}sinstaller $safeShortcutName ?``n``nLe dossier d'installation et les raccourcis seront supprim${eAcute}s.``nVotre fichier ROM (.nup) et vos sauvegardes ne seront PAS supprim${eAcute}s.",
    "D${eAcute}sinstaller $safeShortcutName",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
if (`$res -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
Remove-Item -LiteralPath "$desktopLnk" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$startMenuDir" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$uninstRegPath" -Recurse -Force -ErrorAction SilentlyContinue
`$cmd = 'ping 127.0.0.1 -n 2 > nul & rmdir /s /q "$Dir"'
Start-Process -FilePath "cmd.exe" -ArgumentList "/c", `$cmd -WindowStyle Hidden
"@
[System.IO.File]::WriteAllText($uninstPs1, $uninstScript, (New-Object System.Text.UTF8Encoding($true)))

New-Item -Path $uninstRegPath -Force | Out-Null
$estSizeKb = [math]::Round(((Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1KB)
Set-ItemProperty -Path $uninstRegPath -Name "DisplayName" -Value $safeShortcutName
Set-ItemProperty -Path $uninstRegPath -Name "Publisher" -Value "Switch2Recomp / MTF Recomp"
Set-ItemProperty -Path $uninstRegPath -Name "InstallLocation" -Value $Dir
Set-ItemProperty -Path $uninstRegPath -Name "UninstallString" -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstPs1`""
Set-ItemProperty -Path $uninstRegPath -Name "QuietUninstallString" -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstPs1`""
Set-ItemProperty -Path $uninstRegPath -Name "NoModify" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "NoRepair" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "EstimatedSize" -Value $estSizeKb -Type DWord
if (Test-Path -LiteralPath $iconDst) { Set-ItemProperty -Path $uninstRegPath -Name "DisplayIcon" -Value $iconDst }

Say "installed. Start the game from the Start menu or the desktop shortcut (windowed 720p by default, F11 for fullscreen)."
