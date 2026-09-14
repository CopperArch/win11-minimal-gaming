<#
.SYNOPSIS
    One-shot "make me the ISO" launcher for Win11-Minimal, with a GUI.

.DESCRIPTION
    Does everything the manual build needs, in order, with no prior setup:

      1. Self-elevates (prompts for admin via UAC) — the build servicing
         stage needs Administrator for DISM / Mount-WindowsImage.
      2. Makes sure oscdimg.exe exists; if not, installs the free Windows
         ADK "Deployment Tools" via winget and locates it.
      3. Runs build-windows.ps1 (auto-downloading the latest Windows 11,
         English International, 64-bit — see build-windows.ps1's
         -WinSkuId header for what that SKU id resolves to), writing the
         finished Win11-Minimal.iso straight into your Downloads folder
         (override with -OutDir).

    Just double-click Build-Iso.cmd (or right-click this file > Run with
    PowerShell). A window opens showing which stage is running (resolving
    the download link, downloading, slimming the image, rebuilding the
    ISO, ...) with a progress bar and a live, scrolling log of everything
    build-windows.ps1 prints — not just a spinner, the actual detail, so
    you can tell what it's doing during the long DISM servicing stage
    rather than staring at a frozen-looking window. Pass -NoGui for the
    old plain-console behavior instead (e.g. when running unattended /
    over a remote session where a GUI window can't show).

    The build downloads an ~8.5GB Windows 11 ISO from Microsoft and runs a
    servicing pass, so expect it to run a while. The pipeline is still
    UNVERIFIED end-to-end (see README) — boot-test the ISO in a VM before
    using it on real hardware.

.PARAMETER OutDir
    Where to write Win11-Minimal.iso. Defaults to your Downloads folder.

.PARAMETER SkipDownload
    Reuse an already-downloaded build\windows11.iso instead of fetching it
    again (handshake links expire in ~24h).

.PARAMETER WinSkuId
    Passed through to build-windows.ps1 (ISO language/edition SKU id).
    Defaults to build-windows.ps1's own default (English International,
    64-bit) if not given.

.PARAMETER NoGui
    Skip the GUI progress window and run with plain console output instead
    (the pre-GUI behavior) — useful for unattended runs or a session where
    no desktop is available to show a window.
#>
param(
    [string]$OutDir = (Join-Path $env:USERPROFILE "Downloads"),
    [switch]$SkipDownload,
    [string]$WinSkuId,
    [switch]$NoGui
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Resolve the directory this is actually running from, whether as a plain
# .ps1 (has $PSScriptRoot) or as the ps2exe-compiled Build-Iso.exe (doesn't —
# $PSScriptRoot is empty there since there's no script file on disk to root
# from; fall back to the running exe's own folder instead).
$RepoDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$BuildScript = Join-Path $RepoDir "build-windows.ps1"

# ── 1. Self-elevate ────────────────────────────────────────────────────────
# Only relevant for the plain .ps1: relaunch this same script elevated (UAC
# prompt) and let the elevated copy do the work. This first copy just hands
# off and exits. The compiled Build-Iso.exe is built with -requireAdmin, so
# Windows already elevates it via UAC before this code even runs — this
# relaunch path needs a real .ps1 file path to hand to a new powershell.exe
# ($PSCommandPath), which doesn't exist inside a compiled exe, so it's
# gated on $PSScriptRoot (empty when compiled) rather than attempted there.
if ($PSScriptRoot -and -not (Test-Admin)) {
    Write-Host "==> Requesting administrator rights (needed for DISM image servicing)..." -ForegroundColor Cyan
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-OutDir", "`"$OutDir`"")
    if ($SkipDownload) { $argList += "-SkipDownload" }
    if ($WinSkuId)     { $argList += @("-WinSkuId", $WinSkuId) }
    if ($NoGui)        { $argList += "-NoGui" }
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argList
        Write-Host "    An elevated window is opening to run the build." -ForegroundColor Cyan
    } catch {
        Write-Host "[ERR] Elevation was cancelled. Re-run and accept the UAC prompt." -ForegroundColor Red
    }
    return
}
if (-not (Test-Admin)) {
    # Compiled exe, still not elevated — the -requireAdmin manifest should
    # have prevented this (Windows would have refused to even start the
    # process), but if it's somehow reached anyway, fail loudly rather than
    # silently continuing with a build that will fail at the DISM step.
    [System.Windows.Forms.MessageBox]::Show(
        "This needs to run as Administrator (DISM image servicing requires it). Right-click Build-Iso.exe and choose 'Run as administrator'.",
        "Administrator required", "OK", "Error") | Out-Null
    return
}

# ═══════════════════════════════════════════════════════════════════════════
# From here on we are elevated.
# ═══════════════════════════════════════════════════════════════════════════

function Find-Oscdimg {
    $std = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    if (Test-Path $std) { return $std }
    foreach ($root in @("${env:ProgramFiles(x86)}\Windows Kits\10", "${env:ProgramFiles}\Windows Kits\10")) {
        if (Test-Path $root) {
            $hit = Get-ChildItem -Path $root -Recurse -Filter "oscdimg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

# ═══════════════════════════════════════════════════════════════════════════
# PLAIN CONSOLE PATH (-NoGui) — the original behavior, unchanged.
# ═══════════════════════════════════════════════════════════════════════════
if ($NoGui) {
    try {
        if (-not (Test-Path $BuildScript)) {
            throw "build-windows.ps1 was not found next to this launcher ($RepoDir). Keep Build-Iso.ps1 in the repo root."
        }
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
        $OutDir = (Resolve-Path $OutDir).Path

        $oscdimg = Find-Oscdimg
        if (-not $oscdimg) {
            Write-Host "==> oscdimg.exe not found — installing the Windows ADK (Deployment Tools) via winget..." -ForegroundColor Cyan
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
                throw "winget isn't available on this machine. Install the Windows ADK 'Deployment Tools' feature manually from https://learn.microsoft.com/windows-hardware/get-started/adk-install then re-run."
            }
            & winget install --id Microsoft.WindowsADK -e --accept-source-agreements --accept-package-agreements
            $oscdimg = Find-Oscdimg
            if (-not $oscdimg) {
                throw "The ADK install finished but oscdimg.exe still isn't present. Make sure the 'Deployment Tools' feature was selected, then re-run."
            }
        }
        Write-Host "    oscdimg: $oscdimg" -ForegroundColor DarkGray

        Write-Host "==> Building Win11-Minimal.iso -> $OutDir" -ForegroundColor Cyan
        Write-Host "    (downloads ~8.5GB from Microsoft + runs a servicing pass — this takes a while)" -ForegroundColor DarkGray
        $buildArgs = @("-OscdimgPath", $oscdimg, "-OutDir", $OutDir)
        if ($SkipDownload) { $buildArgs += "-SkipDownload" }
        if ($WinSkuId)     { $buildArgs += @("-WinSkuId", $WinSkuId) }
        & $BuildScript @buildArgs

        $finalIso = Join-Path $OutDir "Win11-Minimal.iso"
        Write-Host ""
        if (Test-Path $finalIso) {
            $gb = [math]::Round((Get-Item $finalIso).Length / 1GB, 2)
            Write-Host "==> DONE. ISO created: $finalIso (${gb}GB)" -ForegroundColor Green
        } else {
            Write-Host "[WARN] Build finished but $finalIso wasn't found — check the output above." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host ""
        Write-Host "[ERR] $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        Write-Host ""
        Write-Host "Press Enter to close..." -ForegroundColor DarkGray
        [void](Read-Host)
    }
    return
}

# ═══════════════════════════════════════════════════════════════════════════
# GUI PATH (default) — a WinForms progress window wrapping the exact same
# build-windows.ps1 call the console path makes, so behavior is identical;
# only the presentation differs. The heavy build work runs in a background
# job (a separate, out-of-process powershell.exe that inherits this process's
# elevation, the same way every other Start-Process call in this project's
# on-device scripts does) so the GUI's own message loop stays responsive —
# same "separate process driven by polling" architecture Show-BootLoader.ps1
# uses for exactly the same reason (a blocking install can't also pump a UI).
# (System.Windows.Forms/System.Drawing are already loaded near the top of
# this script, before the elevation check, so the admin-required MessageBox
# has them available too.)
# ═══════════════════════════════════════════════════════════════════════════

$stages = @(
    @{ Match = "Fetching a download link";               Label = "Resolving the Windows 11 download link..." }
    @{ Match = "Got a link";                              Label = "Downloading Windows 11 (English International, 64-bit, ~8.5 GB)..." }
    @{ Match = "Mounting and copying source files";       Label = "Extracting Windows 11 source files..." }
    @{ Match = "Slimming install.wim";                    Label = "Slimming the Windows image — the slow part, expect 1-2+ hours..." }
    @{ Match = "Injecting autounattend.xml";              Label = "Injecting unattended setup + first-boot scripts..." }
    @{ Match = "Rebuilding as a hybrid BIOS+UEFI";        Label = "Building the final bootable ISO..." }
    @{ Match = "==> Done:";                               Label = "Done." }
)

$form = New-Object System.Windows.Forms.Form
$form.Text = "Win11-Minimal Gaming — ISO Builder"
$form.Size = New-Object System.Drawing.Size(720, 560)
$form.MinimumSize = New-Object System.Drawing.Size(480, 360)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "Sizable"
$form.MaximizeBox = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(255, 18, 18, 22)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Building Win11-Minimal.iso"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 15, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.AutoSize = $true
$titleLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$titleLabel.Location = New-Object System.Drawing.Point(20, 18)
$form.Controls.Add($titleLabel)

# Shows the actual Windows edition/version/build being used, read from the
# source image's own metadata once build-windows.ps1 reports it (an
# "==> Detected: ..." line, parsed by the poll timer below) — not hardcoded,
# so this stays correct whatever version Microsoft ships under the
# configured SKU id (Windows 11 today, 12/13/... automatically if that ever
# changes) rather than needing this script updated to match.
$osInfoLabel = New-Object System.Windows.Forms.Label
$osInfoLabel.Text = "Windows version: resolving..."
$osInfoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$osInfoLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 150, 155, 165)
$osInfoLabel.AutoSize = $false
$osInfoLabel.AutoEllipsis = $true
$osInfoLabel.Size = New-Object System.Drawing.Size(660, 18)
$osInfoLabel.Location = New-Object System.Drawing.Point(20, 46)
$osInfoLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($osInfoLabel)

# stageLabel/progressBar/logBox all anchor Left+Right so they stretch to fill
# whatever width the window is resized to, rather than leaving blank space or
# (for the label/log text) getting clipped; logBox also anchors Bottom so it
# claims any extra vertical space too — everything else stays a fixed height.
$stageLabel = New-Object System.Windows.Forms.Label
$stageLabel.Text = "Starting..."
$stageLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$stageLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 120, 200, 255)
$stageLabel.AutoSize = $false
$stageLabel.AutoEllipsis = $true
$stageLabel.Size = New-Object System.Drawing.Size(660, 24)
$stageLabel.Location = New-Object System.Drawing.Point(20, 80)
$stageLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($stageLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 110)
$progressBar.Size = New-Object System.Drawing.Size(660, 22)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0
$progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($progressBar)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Vertical"
$logBox.WordWrap = $true
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(255, 10, 10, 13)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 205, 215)
$logBox.BorderStyle = "FixedSingle"
$logBox.Location = New-Object System.Drawing.Point(20, 142)
$logBox.Size = New-Object System.Drawing.Size(660, 314)
$logBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($logBox)

# Both buttons anchor Bottom+Right so they track the bottom-right corner
# instead of drifting into the middle of a taller/wider resized window.
$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Working... please wait"
$closeButton.Enabled = $false
$closeButton.Size = New-Object System.Drawing.Size(120, 32)
$closeButton.Location = New-Object System.Drawing.Point(560, 468)
$closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$closeButton.Add_Click({ $form.Close() })
$form.Controls.Add($closeButton)

$openFolderButton = New-Object System.Windows.Forms.Button
$openFolderButton.Text = "Open folder"
$openFolderButton.Visible = $false
$openFolderButton.Size = New-Object System.Drawing.Size(120, 32)
$openFolderButton.Location = New-Object System.Drawing.Point(430, 468)
$openFolderButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($openFolderButton)

function Add-LogLine {
    param([string]$Text)
    $logBox.AppendText("$Text`r`n")
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

$script:job = $null
$script:finished = $false
$script:finalIso = $null

$form.Add_Shown({
    New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction SilentlyContinue | Out-Null
    $script:resolvedOutDir = (Resolve-Path $OutDir).Path
    $script:finalIso = Join-Path $script:resolvedOutDir "Win11-Minimal.iso"

    if (-not (Test-Path $BuildScript)) {
        Add-LogLine "[ERR] build-windows.ps1 was not found next to this launcher ($RepoDir)."
        $stageLabel.Text = "Failed."
        $closeButton.Enabled = $true; $closeButton.Text = "Close"
        return
    }

    Add-LogLine "==> Checking for oscdimg.exe (Windows ADK Deployment Tools)..."
    $oscdimg = Find-Oscdimg
    if (-not $oscdimg) {
        Add-LogLine "==> Not found — installing the Windows ADK via winget (this can take a few minutes)..."
        $stageLabel.Text = "Installing the Windows ADK (Deployment Tools) prerequisite..."
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Add-LogLine "[ERR] winget isn't available on this machine. Install the Windows ADK 'Deployment Tools' feature manually: https://learn.microsoft.com/windows-hardware/get-started/adk-install"
            $stageLabel.Text = "Failed."
            $closeButton.Enabled = $true; $closeButton.Text = "Close"
            return
        }
        & winget install --id Microsoft.WindowsADK -e --accept-source-agreements --accept-package-agreements *>&1 | ForEach-Object { Add-LogLine $_.ToString() }
        $oscdimg = Find-Oscdimg
        if (-not $oscdimg) {
            Add-LogLine "[ERR] The ADK install finished but oscdimg.exe still isn't present. Make sure the 'Deployment Tools' feature was selected, then re-run."
            $stageLabel.Text = "Failed."
            $closeButton.Enabled = $true; $closeButton.Text = "Close"
            return
        }
    }
    Add-LogLine "    oscdimg: $oscdimg"

    $buildArgs = @{
        OscdimgPath = $oscdimg
        OutDir      = $script:resolvedOutDir
    }
    if ($SkipDownload) { $buildArgs["SkipDownload"] = $true }
    if ($WinSkuId)     { $buildArgs["WinSkuId"] = $WinSkuId }

    $stageLabel.Text = "Starting the build..."
    Add-LogLine "==> Building Win11-Minimal.iso -> $($script:resolvedOutDir)"

    $script:job = Start-Job -Name "BuildIso" -ScriptBlock {
        param($BuildScript, $BuildArgs)
        try {
            & $BuildScript @BuildArgs *>&1 | ForEach-Object { Write-Output $_.ToString() }
            Write-Output "GUI_BUILD_DONE_OK"
        } catch {
            Write-Output "GUI_BUILD_DONE_FAIL: $($_.Exception.Message)"
        }
    } -ArgumentList $BuildScript, $buildArgs

    $script:pollTimer = New-Object System.Windows.Forms.Timer
    $script:pollTimer.Interval = 400
    $script:pollTimer.Add_Tick({
        if (-not $script:job) { return }
        $lines = Receive-Job -Job $script:job -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            $text = $line.ToString()
            if ($text -eq "GUI_BUILD_DONE_OK") {
                $script:finished = $true
                $stageLabel.Text = "Done."
                $progressBar.Value = 100
                if (Test-Path $script:finalIso) {
                    $gb = [math]::Round((Get-Item $script:finalIso).Length / 1GB, 2)
                    Add-LogLine ""
                    Add-LogLine "==> DONE. ISO created: $($script:finalIso) (${gb}GB)"
                    $openFolderButton.Visible = $true
                    $openFolderButton.Add_Click({
                        $selectArg = '/select,"' + $script:finalIso + '"'
                        Start-Process -FilePath "explorer.exe" -ArgumentList $selectArg
                    })
                } else {
                    Add-LogLine ""
                    Add-LogLine "[WARN] Build finished but the ISO wasn't found at the expected path — check the log above."
                }
                continue
            }
            if ($text -like "GUI_BUILD_DONE_FAIL:*") {
                $script:finished = $true
                $stageLabel.Text = "Failed — see the log for details."
                $stageLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 255, 110, 110)
                Add-LogLine ""
                Add-LogLine "[ERR] $text"
                continue
            }
            Add-LogLine $text
            if ($text -like "==> Detected:*") {
                $osInfoLabel.Text = "Windows version: " + $text.Substring("==> Detected:".Length).Trim()
            }
            for ($i = 0; $i -lt $stages.Count; $i++) {
                if ($text -like "*$($stages[$i].Match)*") {
                    $stageLabel.Text = $stages[$i].Label
                    $progressBar.Value = [int]((($i + 1) / $stages.Count) * 100)
                    break
                }
            }
        }
        if ($script:finished -or $script:job.State -in @("Completed", "Failed", "Stopped")) {
            $script:pollTimer.Stop()
            Receive-Job -Job $script:job -ErrorAction SilentlyContinue | Out-Null
            Remove-Job -Job $script:job -Force -ErrorAction SilentlyContinue
            $closeButton.Enabled = $true
            $closeButton.Text = "Close"
        }
    })
    $script:pollTimer.Start()
})

$form.Add_FormClosing({
    param($sender, $e)
    if (-not $script:finished -and $script:job -and $script:job.State -eq "Running") {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "The build is still running. Closing this window now will stop it partway through (DISM may leave a mounted image that needs `"dism /Cleanup-Mountpoints`" to clear on the next run). Stop the build and close anyway?",
            "Build still running", "YesNo", "Warning")
        if ($r -eq "No") { $e.Cancel = $true; return }
        try { Stop-Job -Job $script:job -ErrorAction SilentlyContinue; Remove-Job -Job $script:job -Force -ErrorAction SilentlyContinue } catch {}
    }
})

[System.Windows.Forms.Application]::Run($form)
