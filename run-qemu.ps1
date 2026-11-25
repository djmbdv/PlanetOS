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

.PARAMETER Vga
    Plain std VGA instead of the virtio-gpu default.

.PARAMETER Virtio
    virtio-gpu-pci without OpenGL: 2D resources over the virtio queue, no virgl.

.PARAMETER Venus
    virtio-gpu-gl-pci with venus/blob/hostmem enabled. Needs a virglrenderer
    built with the render server; the MSYS2 one is not, so it falls back to a
    plain virgl context there.

.PARAMETER VirtioGl
    Alias of -Venus, kept for invocations written before virtio-gl became the
    default.

.PARAMETER Sdl
    Uses the SDL window instead of GTK. SDL handles the pointer grab differently
    on Windows, which decides whether a relative PS/2 mouse gets motion events
    at all.

.EXAMPLE
    .\run-qemu.ps1

.EXAMPLE
    .\run-qemu.ps1 -Headless

.EXAMPLE
    .\run-qemu.ps1 -Vga

.EXAMPLE
    .\run-qemu.ps1 -Virtio -NoBuild

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
    [switch]$Vga,
    [switch]$Virtio,
    [switch]$Venus,
    [switch]$VirtioGl,
    [switch]$Sdl
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

# Windows path -> MSYS2 path (/c/Users/...). Building it here instead of
# shelling out to `cygpath` keeps PowerShell 5.1 native-argument quoting from
# eating the backslashes.
function To-MsysPath([string]$Path) {
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') {
        $p = '/' + $Matches[1].ToLower() + $Matches[2]
    }
    return $p
}

function Invoke-Bash([string]$Command) {
    # valac/gcc write warnings to stderr, and PowerShell 5.1 turns native
    # stderr into a terminating NativeCommandError under
    # $ErrorActionPreference = 'Stop'. Surface it as plain text and let the
    # exit code decide instead.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Bash -lc $Command 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            Write-Host $_.Exception.Message
        } else {
            Write-Host $_
        }
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return $code
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
# A stage-0 planc built before the last pull rejects the newest flags
# ("unknown option: --nostdlib"), so rebuild it when its sources are newer and
# a build is actually going to run.
$NeedPlanc = -not (Test-Path $Planc)
if (-not $NeedPlanc -and -not $NoBuild) {
    $plancTime = (Get-Item $Planc).LastWriteTime
    $newestSrc = Get-ChildItem -Path @(
        (Join-Path $Root 'planc\src\*.vala'),
        (Join-Path $Root 'planc\stage0\*.vala')
    ) -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($newestSrc -and $newestSrc.LastWriteTime -gt $plancTime) {
        $NeedPlanc = $true
    }
}
if ($NeedPlanc) {
    # tools/build-planc-host.sh is the MSYS2 UCRT64 valac path; planc/build.sh
    # needs the Linux Vala oracle and only works where that is installed.
    Write-Step 'Building the stage-0 planc with valac (tools/build-planc-host.sh)...'
    $rootUnix = To-MsysPath $Root
    $bootCode = Invoke-Bash ("cd '" + $rootUnix + "' && ./tools/build-planc-host.sh")
    if ($bootCode -ne 0) {
        $bootCode = Invoke-Bash ("cd '" + $rootUnix + "' && ./planc/build.sh")
    }
    if ($bootCode -ne 0) {
        Fail 'planc bootstrap failed (tools/build-planc-host.sh and planc/build.sh)'
    }
    if (Test-Path (Join-Path $Root 'planc\build\planc.exe')) {
        $Planc = Join-Path $Root 'planc\build\planc.exe'
    } elseif (Test-Path (Join-Path $Root 'planc\build\planc')) {
        $Planc = Join-Path $Root 'planc\build\planc'
    } else {
        Fail 'the planc bootstrap did not produce planc'
    }
}

function Invoke-Planc {
    param([string[]]$PlancArgs)
    # planc writes diagnostics (warnings included) to stderr. Under
    # $ErrorActionPreference = 'Stop' PowerShell 5.1 turns that into a
    # terminating NativeCommandError, which would make any warning fatal, so
    # stderr is surfaced as plain text and only the exit code decides.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if ($env:PLANC_TRACE) {
        Write-Host ('planc ' + ($PlancArgs -join ' '))
    }
    & $Planc @PlancArgs 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            Write-Host $_.Exception.Message
        } else {
            Write-Host $_
        }
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) {
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

    $Opt = '-O2'
    if ($env:PLANC_OPT) { $Opt = $env:PLANC_OPT }

    $PlanetSys = Join-Path $StdDir 'planet_sys.vala'
    $GlibSrcs = @(
        (Join-Path $StdDir 'glib\core.vala'),
        (Join-Path $StdDir 'glib\filestream.vala'),
        (Join-Path $StdDir 'glib\utils.vala'),
        (Join-Path $StdDir 'glib\test_option.vala'),
        (Join-Path $StdDir 'glib\math.vala'),
        (Join-Path $StdDir 'glib\process.vala'),
        (Join-Path $StdDir 'glib\keyfile.vala'),
        (Join-Path $StdDir 'glib\mainloop.vala'),
        (Join-Path $StdDir 'glib\regex.vala'),
        (Join-Path $StdDir 'glib\variant.vala'),
        (Join-Path $StdDir 'glib\time.vala'),
        (Join-Path $StdDir 'glib\thread.vala'),
        (Join-Path $StdDir 'glib\uuid.vala'),
        (Join-Path $StdDir 'glib\bit.vala'),
        (Join-Path $StdDir 'glib\memory.vala'),
        (Join-Path $StdDir 'glib\slice.vala'),
        (Join-Path $StdDir 'glib\atomic.vala'),
        (Join-Path $StdDir 'glib\bytes.vala'),
        (Join-Path $StdDir 'glib\codec.vala'),
        (Join-Path $StdDir 'glib\hashtable.vala'),
        (Join-Path $StdDir 'glib\queue.vala'),
        (Join-Path $StdDir 'glib\uri.vala'),
        (Join-Path $StdDir 'glib\bookmark.vala'),
        (Join-Path $StdDir 'glib\arena.vala'),
        (Join-Path $StdDir 'glib\simd.vala')
    )
    $GeeSrcs = @(
        (Join-Path $StdDir 'gee\base.vala'),
        (Join-Path $StdDir 'gee\lists.vala'),
        (Join-Path $StdDir 'gee\maps.vala'),
        (Join-Path $StdDir 'gee\queues.vala'),
        (Join-Path $StdDir 'gee\trees.vala')
    )
    $GioSrcs = @(
        (Join-Path $StdDir 'gio\types.vala'),
        (Join-Path $StdDir 'gio\streams.vala'),
        (Join-Path $StdDir 'gio\converter.vala'),
        (Join-Path $StdDir 'gio\file.vala'),
        (Join-Path $StdDir 'gio\models.vala'),
        (Join-Path $StdDir 'gio\planet.vala'),
        (Join-Path $StdDir 'gio\stack.vala'),
        (Join-Path $StdDir 'gio\net.vala'),
        (Join-Path $StdDir 'gio\tls.vala'),
        (Join-Path $StdDir 'gio\dns.vala'),
        (Join-Path $StdDir 'gio\subprocess.vala')
    )
    $CairoSrcs = @(
        (Join-Path $StdDir 'cairo\surface.vala'),
        (Join-Path $StdDir 'cairo\context.vala')
    )
    $GdkSrcs = @(
        (Join-Path $StdDir 'gdk\rgba.vala'),
        (Join-Path $StdDir 'gdk\event.vala'),
        (Join-Path $StdDir 'gdk\window.vala'),
        (Join-Path $StdDir 'gdk\display.vala')
    )
    $GskSrcs = @(
        (Join-Path $StdDir 'gsk\path.vala'),
        (Join-Path $StdDir 'gsk\types.vala'),
        (Join-Path $StdDir 'gsk\nodes.vala'),
        (Join-Path $StdDir 'gsk\renderer.vala')
    )
    $GtkSrcs = @(
        (Join-Path $StdDir 'gtk\text.vala'),
        (Join-Path $StdDir 'gtk\widget.vala'),
        (Join-Path $StdDir 'gtk\widgets.vala'),
        (Join-Path $StdDir 'gtk\container.vala'),
        (Join-Path $StdDir 'gtk\scrolled.vala'),
        (Join-Path $StdDir 'gtk\listview.vala'),
        (Join-Path $StdDir 'gtk\image.vala'),
        (Join-Path $StdDir 'gtk\window.vala')
    )
    $CompositorSrcs = @(
        (Join-Path (Join-Path $Root 'tools') 'c2vala_rt.vala'),
        (Join-Path $StdDir 'gdk\stb_image.vala'),
        (Join-Path $UserDir 'compositor\apps.vala'),
        (Join-Path $UserDir 'compositor\win.vala'),
        (Join-Path $UserDir 'compositor\wm.vala'),
        (Join-Path $UserDir 'compositor\main.vala')
    )

    $LibDir = Out-Path 'library'
    foreach ($pkg in @('glib','gee','gio','cairo','gdk','pango','spirv','venus','gsk','gtk','gobject','gmodule','unsafe')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $LibDir $pkg) | Out-Null
    }
    $LibFlags = '--library-dir=' + $LibDir
    function Lib-Dlib([string]$Pkg) { return (Join-Path (Join-Path $LibDir $Pkg) ($Pkg + '.dlib')) }
    function Lib-Hlib([string]$Pkg) { return (Join-Path (Join-Path $LibDir $Pkg) ($Pkg + '.hlib')) }

    Invoke-Planc (@('--target=planetos', $Opt, '--nostdlib', '--format=dlib', '--image-base=0x1800000', $PlanetSys) + $GlibSrcs + @('-o', (Lib-Dlib 'glib')))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--format=dlib', '--image-base=0x1A80000', (Join-Path $StdDir 'planet_unsafe.vala'), '-o', (Lib-Dlib 'unsafe'))
    Invoke-Planc (@('--target=planetos', $Opt, $LibFlags, '--format=dlib', '--image-base=0x1880000') + $GeeSrcs + @('-o', (Lib-Dlib 'gee')))
    Invoke-Planc (@('--target=planetos', $Opt, $LibFlags, '--import-lib=unsafe', '--format=dlib', '--image-base=0x1AA0000') + $GioSrcs + @('-o', (Lib-Dlib 'gio')))
    Invoke-Planc (@('--target=planetos', $Opt, $LibFlags, '--format=dlib', '--image-base=0x18E0000') + $CairoSrcs + @('-o', (Lib-Dlib 'cairo')))
    Invoke-Planc (@('--target=planetos', $Opt, $LibFlags, '--import-lib=unsafe', '--import-lib=cairo', '--format=dlib', '--image-base=0x1900000') + $GdkSrcs + @('-o', (Lib-Dlib 'gdk')))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=cairo', '--format=dlib', '--image-base=0x1920000', (Join-Path $StdDir 'schrift.vala'), (Join-Path $StdDir 'pango_compat.vala'), '-o', (Lib-Dlib 'pango'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--format=dlib', '--image-base=0x1950000', (Join-Path $StdDir 'spirv_compat.vala'), '-o', (Lib-Dlib 'spirv'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--format=dlib', '--image-base=0x1970000', (Join-Path $StdDir 'venus_compat.vala'), '-o', (Lib-Dlib 'venus'))
    Invoke-Planc (@('--target=planetos', $Opt, $LibFlags, '--import-lib=unsafe', '--import-lib=cairo', '--import-lib=gdk', '--import-lib=spirv', '--import-lib=venus', '--format=dlib', '--image-base=0x1990000') + $GskSrcs + @('-o', (Lib-Dlib 'gsk')))
    Invoke-Planc (@('--target=planetos', $Opt, $LibFlags, '--import-lib=gio', '--import-lib=cairo', '--import-lib=gdk', '--import-lib=gsk', '--import-lib=pango', '--import-lib=spirv', '--import-lib=venus', '--format=dlib', '--image-base=0x19C0000') + $GtkSrcs + @('-o', (Lib-Dlib 'gtk')))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--format=dlib', '--image-base=0x1A40000', (Join-Path $StdDir 'gobject_compat.vala'), '-o', (Lib-Dlib 'gobject'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=unsafe', '--format=dlib', '--image-base=0x1A60000', (Join-Path $StdDir 'gmodule_compat.vala'), '-o', (Lib-Dlib 'gmodule'))

    # In-guest compiles need the GLib declarations (c2vala_sdk.vala),
    # packed into one file because the guest shell line buffer is only 480 bytes.
    & $Python (Join-Path $Root 'tools\make_sdk.py') (Out-Path 'c2vala_sdk.vala')
    if ($LASTEXITCODE -ne 0) {
        Fail 'tools/make_sdk.py failed'
    }

    Invoke-Planc @('--target=planetos', $Opt, '--nostdlib', (Join-Path $UserDir 'init.vala'), '-o', (Out-Path 'init.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--image-base=0x900000', (Join-Path $UserDir 'worker.vala'), '-o', (Out-Path 'worker.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, (Join-Path $UserDir 'banner.vala'), '-o', (Out-Path 'banner.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=gee', (Join-Path $UserDir 'wc.vala'), '-o', (Out-Path 'wc.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=gio', (Join-Path $UserDir 'gio_demo.vala'), '-o', (Out-Path 'gio_demo.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=gee', '--import-lib=gio', (Join-Path $UserDir 'curl.vala'), '-o', (Out-Path 'curl.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=gobject', (Join-Path $UserDir 'gobject_demo.vala'), '-o', (Out-Path 'gobject_demo.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=gmodule', (Join-Path $UserDir 'gmodule_demo.vala'), '-o', (Out-Path 'gmodule_demo.elf'))
    Invoke-Planc @('--target=planetos', $Opt, '--nostdlib', (Join-Path $UserDir 'mathlib.vala'), '-o', (Out-Path 'mathlib.dlib'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=unsafe', '--import-lib=gmodule', (Join-Path $UserDir 'plan_demo.vala'), '-o', (Out-Path 'plan_demo.plan'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=gio', (Join-Path $UserDir 'mainloop_demo.vala'), '-o', (Out-Path 'mainloop_demo.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=cairo', '--import-lib=gdk', (Join-Path $UserDir 'cairo_demo.vala'), '-o', (Out-Path 'cairo_demo.elf'))
    Invoke-Planc @('--target=spirv', (Join-Path $UserDir 'frag_planet.vala'), '-o', (Out-Path 'frag.spv'))
    Invoke-Planc @('--target=spirv', (Join-Path $UserDir 'frag_pattern.vala'), '-o', (Out-Path 'frag_pattern.spv'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=spirv', '--import-lib=cairo', '--import-lib=gdk', (Join-Path $UserDir 'spv_demo.vala'), '-o', (Out-Path 'spv_demo.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=spirv', '--import-lib=venus', '--import-lib=cairo', '--import-lib=gdk', '--import-lib=gsk', (Join-Path $UserDir 'vk_demo.vala'), '-o', (Out-Path 'vk_demo.elf'))
    Invoke-Planc (@('--target=planetos', $Opt, $LibFlags, '--image-base=0xE00000', '--import-lib=unsafe', '--import-lib=gio', '--import-lib=cairo', '--import-lib=gdk', '--import-lib=pango', '--import-lib=spirv', '--import-lib=venus', '--import-lib=gsk', '--import-lib=gtk') + $CompositorSrcs + @('-o', (Out-Path 'compositor.elf')))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=cairo', '--import-lib=pango', (Join-Path $UserDir 'pango_demo.vala'), '-o', (Out-Path 'pango_demo.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=gee', '--import-lib=gio', '--import-lib=spirv', '--import-lib=venus', '--import-lib=cairo', '--import-lib=gdk', '--import-lib=gsk', '--import-lib=pango', '--import-lib=gtk', (Join-Path $UserDir 'pcm4.vala'), '-o', (Out-Path 'pcm4.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, (Join-Path $UserDir 'pluto.vala'), '-o', (Out-Path 'pluto.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=unsafe', '--import-lib=gee', '--import-lib=gio', '--import-lib=spirv', '--import-lib=venus', '--import-lib=cairo', '--import-lib=gdk', '--import-lib=gsk', '--import-lib=pango', '--import-lib=gtk', (Join-Path $UserDir 'saturn.vala'), '-o', (Out-Path 'saturn.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, (Join-Path $UserDir 'jsmn_demo.vala'), (Join-Path (Join-Path $Root 'tools') 'c2vala_rt.vala'), '-o', (Out-Path 'jsmn_demo.elf'))
    # sys_demo carries the `system` case checks (handles, grants, rings, blk):
    # without this line the suite runs whatever stale binary the image had.
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=unsafe', (Join-Path $UserDir 'sys_demo.vala'), '-o', (Out-Path 'sys_demo.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--import-lib=gio', (Join-Path $UserDir 'mercury.vala'), '-o', (Out-Path 'mercury.elf'))

    $C2valaDir = Join-Path $Root 'tools\c2vala'
    Invoke-Planc (@(
        '--target=planetos', $Opt, $LibFlags,
        (Join-Path $SrcDir 'buffer.vala'),
        (Join-Path $SrcDir 'host_planetos.vala'),
        (Join-Path $C2valaDir 'ast.vala'),
        (Join-Path $C2valaDir 'preproc.vala'),
        (Join-Path $C2valaDir 'lexer.vala'),
        (Join-Path $C2valaDir 'parser.vala'),
        (Join-Path $C2valaDir 'ptr_analyzer.vala'),
        (Join-Path $C2valaDir 'translator_models.vala'),
        (Join-Path $C2valaDir 'translator.vala'),
        (Join-Path $C2valaDir 'main.vala'),
        '-o', (Out-Path 'c2vala.elf')
    ))

    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--image-base=0xA00000', '--import-lib=gee', (Join-Path $UserDir 'shell.vala'), '-o', (Out-Path 'shell.elf'))
    Invoke-Planc @('--target=planetos', $Opt, $LibFlags, '--image-base=0xB00000', '--import-lib=gee', (Join-Path $UserDir 'shell.vala'), '-o', (Out-Path 'vte_sh.elf'))

    Invoke-Planc @(
        '--target=planetos', $Opt, $LibFlags, '--image-base=0xC00000',
        (Join-Path $SrcDir 'buffer.vala'),
        (Join-Path $SrcDir 'host_planetos.vala'),
        (Join-Path $SrcDir 'ast.vala'),
        (Join-Path $SrcDir 'diag.vala'),
        (Join-Path $SrcDir 'preproc.vala'),
        (Join-Path $SrcDir 'lexer.vala'),
        (Join-Path $SrcDir 'parser.vala'),
        (Join-Path $SrcDir 'asm.vala'),
        (Join-Path $SrcDir 'emitter.vala'),
        (Join-Path $SrcDir 'elf.vala'),
        (Join-Path $SrcDir 'dwarf.vala'),
        (Join-Path $SrcDir 'spirv.vala'),
        (Join-Path $SrcDir 'opt.vala'),
        (Join-Path $SrcDir 'pe.vala'),
        (Join-Path $SrcDir 'puzzle_ra.vala'),
        (Join-Path $SrcDir 'codegen.vala'),
        (Join-Path $SrcDir 'main.vala'),
        '-o', (Out-Path 'planc.elf')
    )

    Invoke-Planc @(
        $Opt, '--freestanding',
        (Join-Path $RtDir 'boot_mb2.vala'),
        (Join-Path $RtDir 'serial.vala'),
        (Join-Path $KernelDir 'layout.vala'),
        (Join-Path $KernelDir 'klog.vala'),
        (Join-Path $KernelDir 'cpu.vala'),
        (Join-Path $KernelDir 'vga.vala'),
        (Join-Path $KernelDir 'fb.vala'),
        (Join-Path $KernelDir 'pmm.vala'),
        (Join-Path $KernelDir 'vmm.vala'),
        (Join-Path $KernelDir 'console_font.vala'),
        (Join-Path $KernelDir 'virtio_gpu.vala'),
        (Join-Path $KernelDir 'virtio_blk.vala'),
        (Join-Path $KernelDir 'virtio_net.vala'),
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

    # Fails the build when the fixed low-memory window in kernel/layout.vala is
    # broken (overlapping regions, image reaching into it, asm literals drifted).
    & $Python (Join-Path $Root 'tools\check_layout.py') (Out-Path 'planet-kernel')
    if ($LASTEXITCODE -ne 0) {
        Fail 'the kernel image overlaps its fixed data structures (tools/check_layout.py)'
    }

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
        (Out-Path 'vk_demo.elf') `
        (Out-Path 'c2vala.elf') `
        (Join-Path $Root 'tools\c2vala_tests\cases\arith\main.c') `
        (Out-Path 'frag_pattern.spv') `
        (Join-Path $Root 'assets\Tahoma.ttf') `
        (Join-Path $Root 'assets\Consolas-Regular.ttf') `
        (Join-Path $Root 'cursor.svg') `
        (Out-Path 'pcm4.elf') `
        (Out-Path 'mathlib.dlib') `
        (Out-Path 'plan_demo.plan') `
        (Out-Path 'vte_sh.elf') `
        (Out-Path 'pluto.elf') `
        (Out-Path 'saturn.elf') `
        (Out-Path 'jsmn_demo.elf') `
        (Out-Path 'c2vala_sdk.vala') `
        (Out-Path 'sys_demo.elf') `
        (Out-Path 'mercury.elf') `
        (Out-Path 'curl.elf') `
        (Join-Path $Root 'assets\winxp.jpg') `
        '--lib' (Lib-Dlib 'glib') '--lib' (Lib-Hlib 'glib') `
        '--lib' (Lib-Dlib 'gee') '--lib' (Lib-Hlib 'gee') `
        '--lib' (Lib-Dlib 'gio') '--lib' (Lib-Hlib 'gio') `
        '--lib' (Lib-Dlib 'cairo') '--lib' (Lib-Hlib 'cairo') `
        '--lib' (Lib-Dlib 'gdk') '--lib' (Lib-Hlib 'gdk') `
        '--lib' (Lib-Dlib 'pango') '--lib' (Lib-Hlib 'pango') `
        '--lib' (Lib-Dlib 'spirv') '--lib' (Lib-Hlib 'spirv') `
        '--lib' (Lib-Dlib 'venus') '--lib' (Lib-Hlib 'venus') `
        '--lib' (Lib-Dlib 'gsk') '--lib' (Lib-Hlib 'gsk') `
        '--lib' (Lib-Dlib 'gtk') '--lib' (Lib-Hlib 'gtk') `
        '--lib' (Lib-Dlib 'gobject') '--lib' (Lib-Hlib 'gobject') `
        '--lib' (Lib-Dlib 'gmodule') '--lib' (Lib-Hlib 'gmodule') `
        '--lib' (Lib-Dlib 'unsafe') '--lib' (Lib-Hlib 'unsafe')
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

$gpuSwitches = @()
if ($Vga) { $gpuSwitches += '-Vga' }
if ($Virtio) { $gpuSwitches += '-Virtio' }
if ($Venus) { $gpuSwitches += '-Venus' }
if ($VirtioGl -and -not $Venus) { $gpuSwitches += '-VirtioGl' }
if ($gpuSwitches.Count -gt 1) {
    Fail ('use only one GPU mode, not ' + ($gpuSwitches -join ' + '))
}

# virtio-gpu with virgl is the default: the guest driver (kernel/virtio_gpu.vala)
# negotiates VIRGL and the compositor draws through it. blob=on exposes
# RESOURCE_BLOB so the Phase 3 context/blob path can be probed; it needs no
# hostmem for guest blobs. -Vga goes back to the plain BGA/VGA path, -Virtio
# keeps virtio-gpu without GL, and -Venus asks for venus plus hostmem, which
# needs a render-server virglrenderer.
$GpuMode = 'gl'
if ($Vga) { $GpuMode = 'std' }
elseif ($Virtio) { $GpuMode = 'virtio' }
elseif ($Venus -or $VirtioGl) { $GpuMode = 'venus' }

if ($GpuMode -eq 'venus') {
    # Every MSYS2 virglrenderer so far is built without the render server, so
    # venus cannot come up and QEMU leaves the guest on plain virgl. Say it here
    # instead of letting the failure look like a guest bug.
    Write-Host 'QEMU: -Venus needs a virglrenderer built with the render server; if QEMU reports "failed to initialize venus renderer", this host cannot do venus and the guest keeps plain virgl.'
}

if ($Headless -and ($GpuMode -eq 'gl' -or $GpuMode -eq 'venus')) {    # A GL device needs a GL-capable display backend, and QEMU on Windows has
    # none without a window: '-display egl-headless' boots but its scanouts
    # fail (VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER), so headless stays on the
    # non-GL virtio-gpu where the serial console is all that matters.
    Write-Host 'QEMU: -Headless has no OpenGL backend here; using virtio-gpu-pci instead of virtio-gpu-gl-pci.'
    $GpuMode = 'virtio'
}

switch ($GpuMode) {
    'std'    { $vgaArgs = @('-vga', 'std') }
    'virtio' { $vgaArgs = @('-vga', 'none', '-device', 'virtio-gpu-pci') }
    'venus'  { $vgaArgs = @('-vga', 'none', '-device', 'virtio-gpu-gl-pci,venus=on,blob=on,hostmem=256M') }
    default  { $vgaArgs = @('-vga', 'none', '-device', 'virtio-gpu-gl-pci,blob=on') }
}

$displayArgs = @()
if ($Headless) {
    $displayArgs = @('-display', 'none')
} else {
    # grab-on-hover is a GTK-only sub-option: passing it to SDL makes QEMU refuse
    # to start ("Parameter 'grab-on-hover' is unexpected").
    $backend = if ($Sdl) { 'sdl' } else { 'gtk' }
    $grab = if ($Sdl) { '' } else { ',grab-on-hover=on' }
    if ($GpuMode -eq 'gl' -or $GpuMode -eq 'venus') {
        $displayArgs = @('-display', ($backend + ',gl=on' + $grab))
    } elseif ($GpuMode -eq 'virtio') {
        $displayArgs = @('-display', ($backend + $grab))
    } elseif ($Display) {
        # run-qemu.sh only spells the backend out for std VGA when --display
        # was asked for explicitly; otherwise QEMU picks its default.
        $displayArgs = @('-display', ($backend + $grab))
    }
}

# A virtio-gpu-gl device only exists on top of an OpenGL display backend: QEMU
# refuses to start without one ("The display backend does not have OpenGL
# support enabled"), and a GL device paired with a plain backend is how a run
# silently loses virgl. Keep device and display in sync and say so out loud.
$gpuLine = ($vgaArgs + $displayArgs) -join ' '
$dispLine = $displayArgs -join ' '
if ($gpuLine -match 'virtio-gpu-gl' -and $dispLine -notmatch 'gl=on') {
    Fail ('the GL device needs a gl=on display backend, got: ' + $gpuLine)
}
Write-Host ('GPU: ' + $GpuMode + ' [' + $gpuLine + ']')

$qemuArgs = @(
    '-cpu', 'max',
    '-kernel', (To-QemuPath $kernelPath),
    '-drive', ('file=' + (To-QemuPath $diskPath) + ',format=raw,if=ide'),
    '-drive', ('file=' + (To-QemuPath $diskPath) + ',format=raw,if=none,id=vd0,readonly=on'),
    '-device', 'virtio-blk-pci,drive=vd0',
    '-netdev', 'user,id=net0',
    '-device', 'virtio-net-pci,netdev=net0'
) + $vgaArgs + @(
    '-no-reboot',
    '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'
) + $displayArgs

if ($Headless) {
    $qemuArgs += @('-serial', 'mon:stdio')
} else {
    $serialLog = Out-Path 'serial.log'
    $qemuArgs += @('-serial', ('file:' + (To-QemuPath $serialLog)))
    Write-Host ('Serial log: ' + $serialLog)
}

Write-Step "Booting PlanetOS in QEMU (type 'exit' in the guest shell to quit)..."
& $Qemu @qemuArgs
exit $LASTEXITCODE
