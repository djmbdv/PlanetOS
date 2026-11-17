#Requires -Version 5.1
<#
.SYNOPSIS
    Builds PlanetOS and boots it in QEMU from PowerShell.

.DESCRIPTION
    Native PowerShell counterpart of run-qemu.sh: compiles the kernel, the
    userland and planc.elf with planc, builds the XFS boot image with
    tools/mkdisk.py and starts QEMU.

    Requires MSYS2 (UCRT64) with qemu, python and vala. The script finds MSYS2
    in $env:MSYS2_ROOT, C:\msys64, %USERPROFILE%\msys64 or %LOCALAPPDATA%\msys64,
    or wherever bash.exe is on PATH.

.PARAMETER Headless
    Serial-only mode: no QEMU window, the guest shell uses this terminal.

.PARAMETER Display
    Forces a QEMU window. Windows always has a display, so this is the default;
    the switch exists for parity with run-qemu.sh.

.PARAMETER NoBuild
    Skips compiling and reuses the artifacts in <msys64>\tmp\planetos-qemu.

.PARAMETER BuildOnly
    Compiles everything and stops before starting QEMU. Prints the build
    directory so tests/qemu.py can reuse the artifacts.

.EXAMPLE
    .\run-qemu.ps1

.EXAMPLE
    .\run-qemu.ps1 -Headless

.NOTES
    If PowerShell refuses to run the script, start it with:
        powershell -NoProfile -ExecutionPolicy Bypass -File .\run-qemu.ps1
#>
[CmdletBinding()]
param(
    [switch]$Headless,
    [switch]$Display,
    [switch]$NoBuild,
    [switch]$BuildOnly,
    [switch]$Virtio,
    [switch]$VirtioGl
)

$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
if (-not $Root) {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

function Write-Step([string]$Text) {
    Write-Host $Text -ForegroundColor Cyan
}

function Fail([string]$Text) {
    Write-Host ("run-qemu: " + $Text) -ForegroundColor Red
    exit 1
}

function To-QemuPath([string]$Path) {
    return $Path.Replace('\', '/')
}

# --- MSYS2 discovery -------------------------------------------------------

$MsysCandidates = @()
if ($env:MSYS2_ROOT) { $MsysCandidates += $env:MSYS2_ROOT }
$MsysCandidates += 'C:\msys64'
if ($env:USERPROFILE) { $MsysCandidates += (Join-Path $env:USERPROFILE 'msys64') }
if ($env:LOCALAPPDATA) { $MsysCandidates += (Join-Path $env:LOCALAPPDATA 'msys64') }

$Msys = $null
foreach ($candidate in $MsysCandidates) {
    if ($candidate -and (Test-Path (Join-Path $candidate 'usr\bin\bash.exe'))) {
        $Msys = $candidate
        break
    }
}
if (-not $Msys) {
    $bashCommand = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($bashCommand) {
        $binDir = Split-Path -Parent $bashCommand.Source
        $usrDir = Split-Path -Parent $binDir
        $Msys = Split-Path -Parent $usrDir
    }
}
if (-not $Msys) {
    Fail 'MSYS2 not found. Install it (https://www.msys2.org) or set $env:MSYS2_ROOT.'
}

$Bash = Join-Path $Msys 'usr\bin\bash.exe'
$UcrtBin = Join-Path $Msys 'ucrt64\bin'
$Python = Join-Path $UcrtBin 'python.exe'
$Qemu = Join-Path $UcrtBin 'qemu-system-x86_64.exe'

if (-not (Test-Path $Python)) {
    Fail ("missing " + $Python + " (pacman -S mingw-w64-ucrt-x86_64-python)")
}
if (-not (Test-Path $Qemu)) {
    Fail ("missing " + $Qemu + " (pacman -S mingw-w64-ucrt-x86_64-qemu)")
}

# planc.exe and QEMU need the UCRT64 DLLs on PATH.
$env:PATH = $UcrtBin + ';' + $env:PATH

# --- planc ----------------------------------------------------------------

$Planc = Join-Path $Root 'planc\build\planc.exe'
if (-not (Test-Path $Planc)) {
    $PlancNoExt = Join-Path $Root 'planc\build\planc'
    if (Test-Path $PlancNoExt) {
        $Planc = $PlancNoExt
    }
}
if (-not (Test-Path $Planc)) {
    Write-Step 'Building the stage-0 planc with valac (planc/build.sh)...'
    $rootUnix = (& $Bash -lc ('cygpath -m "' + $Root + '"')).Trim()
    & $Bash -lc ("cd '" + $rootUnix + "' && ./planc/build.sh")
    if ($LASTEXITCODE -ne 0) {
        Fail 'planc/build.sh failed'
    }
    if (Test-Path (Join-Path $Root 'planc\build\planc.exe')) {
        $Planc = Join-Path $Root 'planc\build\planc.exe'
    } elseif (Test-Path (Join-Path $Root 'planc\build\planc')) {
        $Planc = Join-Path $Root 'planc\build\planc'
    } else {
        Fail 'planc/build.sh did not produce planc'
    }
}

function Invoke-Planc {
    param([string[]]$PlancArgs)
    & $Planc @PlancArgs
    if ($LASTEXITCODE -ne 0) {
        Fail ('planc failed: ' + ($PlancArgs -join ' '))
    }
}

$Out = Join-Path $Msys 'tmp\planetos-qemu'
New-Item -ItemType Directory -Force -Path $Out | Out-Null

$UserDir = Join-Path $Root 'user'
$StdDir = Join-Path $Root 'stdlib'
$SrcDir = Join-Path $Root 'planc\src'
$KernelDir = Join-Path $Root 'kernel'
$RtDir = Join-Path $Root 'planetrt'

function Out-Path([string]$Name) {
    return (Join-Path $Out $Name)
}

# --- build ----------------------------------------------------------------

if (-not $NoBuild) {
    Write-Step 'Building PlanetOS kernel and userland...'

    Invoke-Planc @('--target=planetos', (Join-Path $UserDir 'init.vala'), '-o', (Out-Path 'init.elf'))
    Invoke-Planc @('--target=planetos', '--image-base=0x900000', (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $UserDir 'worker.vala'), '-o', (Out-Path 'worker.elf'))
    Invoke-Planc @('--target=planetos', (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $UserDir 'banner.vala'), '-o', (Out-Path 'banner.elf'))
    Invoke-Planc @('--target=planetos', (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $StdDir 'glib_compat.vala'), (Join-Path $UserDir 'wc.vala'), '-o', (Out-Path 'wc.elf'))
    Invoke-Planc @('--target=planetos', (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $StdDir 'glib_compat.vala'), (Join-Path $StdDir 'gio_compat.vala'), (Join-Path $UserDir 'gio_demo.vala'), '-o', (Out-Path 'gio_demo.elf'))
    Invoke-Planc @('--target=planetos', (Join-Path $StdDir 'gobject_compat.vala'), (Join-Path $UserDir 'gobject_demo.vala'), '-o', (Out-Path 'gobject_demo.elf'))
    Invoke-Planc @('--target=planetos', (Join-Path $StdDir 'gmodule_compat.vala'), (Join-Path $UserDir 'gmodule_demo.vala'), '-o', (Out-Path 'gmodule_demo.elf'))
    Invoke-Planc @('--target=planetos', (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $StdDir 'glib_compat.vala'), (Join-Path $StdDir 'gio_compat.vala'), (Join-Path $UserDir 'mainloop_demo.vala'), '-o', (Out-Path 'mainloop_demo.elf'))
    Invoke-Planc @('--target=planetos', (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $StdDir 'cairo_compat.vala'), (Join-Path $StdDir 'gdk_compat.vala'), (Join-Path $UserDir 'cairo_demo.vala'), '-o', (Out-Path 'cairo_demo.elf'))
    Invoke-Planc @('--target=spirv', (Join-Path $UserDir 'frag_planet.vala'), '-o', (Out-Path 'frag.spv'))
    Invoke-Planc @('--target=spirv', (Join-Path $UserDir 'frag_pattern.vala'), '-o', (Out-Path 'frag_pattern.spv'))
    Invoke-Planc @('--target=planetos', (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $StdDir 'spirv_compat.vala'), (Join-Path $StdDir 'cairo_compat.vala'), (Join-Path $StdDir 'gdk_compat.vala'), (Join-Path $UserDir 'spv_demo.vala'), '-o', (Out-Path 'spv_demo.elf'))
    Invoke-Planc @('--target=planetos', '-O2', (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $StdDir 'spirv_compat.vala'), (Join-Path $StdDir 'venus_compat.vala'), (Join-Path $StdDir 'cairo_compat.vala'), (Join-Path $StdDir 'gdk_compat.vala'), (Join-Path $StdDir 'gsk_compat.vala'), (Join-Path $UserDir 'vk_demo.vala'), '-o', (Out-Path 'vk_demo.elf'))
    Invoke-Planc @('--target=planetos', '-O2', (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $StdDir 'glib_compat.vala'), (Join-Path $StdDir 'pango_compat.vala'), (Join-Path $StdDir 'spirv_compat.vala'), (Join-Path $StdDir 'cairo_compat.vala'), (Join-Path $StdDir 'gdk_compat.vala'), (Join-Path $StdDir 'schrift.vala'), (Join-Path $StdDir 'gtk\text.vala'), (Join-Path $StdDir 'gtk\widget.vala'), (Join-Path $StdDir 'gtk\widgets.vala'), (Join-Path $StdDir 'gtk\container.vala'), (Join-Path $StdDir 'gtk\window.vala'), (Join-Path $UserDir 'compositor.vala'), '-o', (Out-Path 'compositor.elf'))
    Invoke-Planc @('--target=planetos', (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $StdDir 'cairo_compat.vala'), (Join-Path $StdDir 'pango_compat.vala'), (Join-Path $UserDir 'pango_demo.vala'), '-o', (Out-Path 'pango_demo.elf'))
    Invoke-Planc @('--target=planetos', (Join-Path $UserDir 'jsmn_demo.vala'), (Join-Path $Root 'tools' 'c2vala_rt.vala'), '-o', (Out-Path 'jsmn_demo.elf'))
    Invoke-Planc @('--target=planetos', (Join-Path $Root 'planc' 'src' 'buffer.vala'), (Join-Path $Root 'planc' 'src' 'host_planetos.vala'), (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $Root 'tools' 'c2vala' 'ast.vala'), (Join-Path $Root 'tools' 'c2vala' 'preproc.vala'), (Join-Path $Root 'tools' 'c2vala' 'lexer.vala'), (Join-Path $Root 'tools' 'c2vala' 'parser.vala'), (Join-Path $Root 'tools' 'c2vala' 'translator.vala'), (Join-Path $Root 'tools' 'c2vala' 'main.vala'), '-o', (Out-Path 'c2vala.elf'))
    Invoke-Planc @('--target=planetos', '-O2', (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $StdDir 'cairo_compat.vala'), (Join-Path $StdDir 'gdk_compat.vala'), (Join-Path $StdDir 'schrift.vala'), (Join-Path $StdDir 'gtk\text.vala'), (Join-Path $StdDir 'gtk\widget.vala'), (Join-Path $StdDir 'gtk\widgets.vala'), (Join-Path $StdDir 'gtk\container.vala'), (Join-Path $StdDir 'gtk\window.vala'), (Join-Path $UserDir 'gtk_demo.vala'), '-o', (Out-Path 'gtk_demo.elf'))
    Invoke-Planc @('--target=planetos', '-O2', '--image-base=0xA00000', (Join-Path $StdDir 'planet_sys.vala'), (Join-Path $StdDir 'glib_compat.vala'), (Join-Path $UserDir 'shell.vala'), '-o', (Out-Path 'shell.elf'))

    Invoke-Planc @(
        '--target=planetos', '--image-base=0xC00000',
        (Join-Path $StdDir 'planet_sys.vala'),
        (Join-Path $SrcDir 'buffer.vala'),
        (Join-Path $SrcDir 'host_planetos.vala'),
        (Join-Path $SrcDir 'ast.vala'),
        (Join-Path $SrcDir 'lexer.vala'),
        (Join-Path $SrcDir 'parser.vala'),
        (Join-Path $SrcDir 'asm.vala'),
        (Join-Path $SrcDir 'emitter.vala'),
        (Join-Path $SrcDir 'elf.vala'),
        (Join-Path $SrcDir 'dwarf.vala'),
        (Join-Path $SrcDir 'spirv.vala'),
        (Join-Path $SrcDir 'opt.vala'),
        (Join-Path $SrcDir 'codegen.vala'),
        (Join-Path $SrcDir 'main.vala'),
        '-o', (Out-Path 'planc.elf')
    )

    Invoke-Planc @(
        '--freestanding',
        (Join-Path $RtDir 'boot_mb2.vala'),
        (Join-Path $RtDir 'serial.vala'),
        (Join-Path $KernelDir 'cpu.vala'),
        (Join-Path $KernelDir 'vga.vala'),
        (Join-Path $KernelDir 'fb.vala'),
        (Join-Path $KernelDir 'pmm.vala'),
        (Join-Path $KernelDir 'vmm.vala'),
        (Join-Path $KernelDir 'console_font.vala'),
        (Join-Path $KernelDir 'virtio_gpu.vala'),
        (Join-Path $KernelDir 'env.vala'),
        (Join-Path $KernelDir 'ramfs.vala'),
        (Join-Path $KernelDir 'keyboard.vala'),
        (Join-Path $KernelDir 'rtc.vala'),
        (Join-Path $KernelDir 'mouse.vala'),
        (Join-Path $KernelDir 'ata.vala'),
        (Join-Path $KernelDir 'xfs.vala'),
        (Join-Path $KernelDir 'vfs.vala'),
        (Join-Path $KernelDir 'syscall.vala'),
        (Join-Path $KernelDir 'elf_loader.vala'),
        (Join-Path $KernelDir 'sched.vala'),
        (Join-Path $KernelDir 'main.vala'),
        '-o', (Out-Path 'planet-kernel')
    )

    Write-Step 'Building the boot disk image...'
    & $Python (Join-Path $Root 'tools\mkdisk.py') `
        (Out-Path 'disk.img') `
        (Out-Path 'init.elf') `
        (Out-Path 'shell.elf') `
        (Out-Path 'planc.elf') `
        (Out-Path 'banner.elf') `
        (Out-Path 'worker.elf') `
        (Out-Path 'wc.elf') `
        (Out-Path 'cairo_demo.elf') `
        (Out-Path 'frag.spv') `
        (Out-Path 'spv_demo.elf') `
        (Out-Path 'gio_demo.elf') `
        (Join-Path $Root 'planc\tests\valid\utf8.vala') `
        (Join-Path $Root 'planc\tests\valid\class_basic.vala') `
        (Out-Path 'gobject_demo.elf') `
        (Out-Path 'gmodule_demo.elf') `
        (Out-Path 'mainloop_demo.elf') `
        (Out-Path 'compositor.elf') `
        (Out-Path 'pango_demo.elf') `
        (Out-Path 'jsmn_demo.elf') `
        (Out-Path 'c2vala.elf') `
        (Join-Path $Root 'tools' 'c2vala_tests' 'cases' 'arith' 'main.c') `
        (Out-Path 'frag_pattern.spv') `
        (Out-Path 'gtk_demo.elf') `
        (Out-Path 'vk_demo.elf') `
        (Join-Path $Root 'assets' 'LiberationSans-Regular.ttf') `
        (Join-Path $Root 'assets' 'LiberationMono-Regular.ttf')
    if ($LASTEXITCODE -ne 0) {
        Fail 'mkdisk.py failed'
    }
} else {
    Write-Host 'Skipping build (-NoBuild).'
}

$kernelPath = Out-Path 'planet-kernel'
$diskPath = Out-Path 'disk.img'
if (-not (Test-Path $kernelPath)) { Fail ('missing ' + $kernelPath + ' (run without -NoBuild)') }
if (-not (Test-Path $diskPath)) { Fail ('missing ' + $diskPath + ' (run without -NoBuild)') }

if ($BuildOnly) {
    Write-Host ('PLANETOS_OUT=' + $Out)
    Write-Host ('PLANETOS_QEMU=' + $Qemu)
    Write-Host 'Build complete (build-only).'
    exit 0
}

# --- QEMU -----------------------------------------------------------------

# Window by default (Windows always has a display); -Headless forces the
# serial-only mode, -Display is accepted for parity with run-qemu.sh.
if ($Headless -and $Display) {
    Fail 'use either -Headless or -Display, not both'
}

if ($Virtio -and $VirtioGl) {
    Fail 'use either -Virtio or -VirtioGl, not both'
}

$vgaArgs = @('-vga', 'std')
if ($Virtio) {
    $vgaArgs = @('-vga', 'none', '-device', 'virtio-gpu-pci')
} elseif ($VirtioGl) {
    $vgaArgs = @('-vga', 'none', '-device', 'virtio-gpu-gl-pci,venus=on,blob=on,hostmem=256M')
}

$qemuArgs = @(
    '-cpu', 'max',
    '-kernel', (To-QemuPath $kernelPath),
    '-drive', ('file=' + (To-QemuPath $diskPath) + ',format=raw,if=ide')
) + $vgaArgs + @(
    '-no-reboot',
    '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'
)

if ($Headless) {
    $disp = if ($VirtioGl) { 'egl-headless' } else { 'none' }
    $qemuArgs += @('-display', $disp, '-serial', 'mon:stdio')
} else {
    if ($VirtioGl) {
        $qemuArgs += @('-display', 'gtk,gl=on,grab-on-hover=on')
    } elseif ($Virtio) {
        $qemuArgs += @('-display', 'gtk,grab-on-hover=on')
    }
    $serialLog = Out-Path 'serial.log'
    $qemuArgs += @('-serial', ('file:' + (To-QemuPath $serialLog)))
    Write-Host ('Serial log: ' + $serialLog)
}

Write-Step "Booting PlanetOS in QEMU (type 'exit' in the guest shell to quit)..."
& $Qemu @qemuArgs
exit $LASTEXITCODE
