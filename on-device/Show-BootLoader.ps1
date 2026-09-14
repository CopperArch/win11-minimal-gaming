<#
.SYNOPSIS
    Fullscreen "GAMING" boot loader — a black, topmost splash with a moving
    3D starfield, a big GAMING logo, a progress ring with a light spinning
    around it, and a live status line underneath ("GAME MODE" + whatever is
    currently being loaded/installed).

.DESCRIPTION
    Purpose-built to cover the real desktop the instant it can, so the brief
    desktop flash before Steam Big Picture paints (normal logins) — and the
    whole first-boot install phase (drivers, Steam, apps) — read as a single
    console-style loading screen rather than a visible Windows desktop doing
    setup.

    THE STARFIELD: behind the logo, stars stream out of the centre of the
    screen toward the viewer (a classic "warp"/hyperspace field). Each star is
    a 3D point (x, y, depth) projected with perspective (screen = centre +
    xy / depth). As a star's depth shrinks it drifts outward and speeds up, so
    — exactly as asked — stars near the centre move slowly and stars out toward
    the edges move fast. Sizes and positions are randomised per star, and each
    respawns at the far plane once it passes the camera, so the field never
    thins out. It's all drawn in the same double-buffered paint pass as the
    ring, so it animates smoothly while the caller does blocking installs.

    It is intentionally a SEPARATE process driven by a status FILE, not an
    in-process form: the caller (first-boot-tweaks.ps1) is doing long blocking
    installs on its own thread and can't also pump a UI message loop, so it
    just writes one line of status to $StatusFile as it progresses and this
    process animates smoothly and reflects it. Signal completion by writing the
    literal token "__DONE__" to the status file (or deleting it) and the loader
    closes, revealing whatever the caller launched (Big Picture, or the
    desktop as a fallback).

    explorer.exe remains the real Windows shell throughout — this is only a
    window layered on top. Nothing here changes the shell.

.PARAMETER StatusFile
    Path to the one-line status file this loader polls. The caller writes the
    current step there; "__DONE__" (or the file being removed) closes the loader.

.PARAMETER Title
    Big centered logo text inside the ring. Default "GAMING".

.PARAMETER Subtitle
    Heading under the ring. Default "GAME MODE".

.PARAMETER TimeoutSeconds
    Hard safety cap — the loader self-closes after this long even if it never
    sees "__DONE__", so a broken/killed caller can never strand the machine on
    the splash. Generous by default because first-boot driver+app installs can
    take a while.
#>
param(
    [string]$StatusFile     = (Join-Path $env:ProgramData "GameMode\boot-status.txt"),
    [string]$Title          = "GAMING",
    [string]$Subtitle       = "GAME MODE",
    [int]   $TimeoutSeconds = 3600
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Shared animation/state (script scope so the timer + paint handler share it) ──
$script:angle    = 0                       # current rotation of the spinning light (degrees)
$script:status   = "Starting Game Mode..." # last status line read from the file
$script:started  = Get-Date
$script:accent   = [System.Drawing.Color]::FromArgb(255,  76, 194, 255)  # cyan-blue "light" — starting hue; the spinning arc/head then fade-cycles away from this each frame (see Get-HueColor)
$script:accentDim= [System.Drawing.Color]::FromArgb(255,  38,  42,  50)  # dim base ring — stays fixed, only the bright arc/head cycle color
$script:tick     = 0                       # frame counter (used to re-assert topmost)
$script:hue      = 195.0                   # current hue (degrees) of the spinning arc/head — 195 = the starting cyan-blue

# Smoothly fades the spinning arc/head through the color wheel (fixed
# saturation/brightness matching the original cyan-blue accent, hue advances
# a fraction of a degree per frame) rather than jumping between random
# colors — each frame's color is barely different from the last, so it reads
# as a continuous fade rather than a flicker.
function Get-HueColor {
    param([double]$Hue, [double]$Sat = 0.70, [double]$Val = 1.0)
    $h = (($Hue % 360) + 360) % 360
    $c = $Val * $Sat
    $x = $c * (1 - [math]::Abs((($h / 60.0) % 2) - 1))
    $m = $Val - $c
    switch ([int]($h / 60)) {
        0 { $r = $c; $g = $x; $b = 0 }
        1 { $r = $x; $g = $c; $b = 0 }
        2 { $r = 0; $g = $c; $b = $x }
        3 { $r = 0; $g = $x; $b = $c }
        4 { $r = $x; $g = 0; $b = $c }
        default { $r = $c; $g = 0; $b = $x }
    }
    return [System.Drawing.Color]::FromArgb(255, [int](($r + $m) * 255), [int](($g + $m) * 255), [int](($b + $m) * 255))
}

# ── Starfield tunables ───────────────────────────────────────────────────────
$script:starCount = 220     # how many stars are alive at once
$script:warpSpeed = 0.010   # depth travelled toward the camera each frame (bigger = faster warp)
$script:zNear     = 0.045   # depth at which a star has "passed" the camera and respawns
$script:rng       = New-Object System.Random

# ── Crawl text — a Star Wars-style opening crawl summarizing what this build
# does/removes, scrolling up from the bottom and shrinking into the screen
# centre (the same point the starfield radiates from) until it vanishes.
# Drawn BEHIND the starfield in the paint order below, so the stars pass in
# front of it rather than the other way around. Dark/muted and semi-
# transparent so it reads as background flavor, not competing with the ring/
# status text for attention.
$script:crawlContent = @(
    "Removing Microsoft Edge"
    "Removing OneDrive"
    "Disabling Windows Update (security patches still install automatically)"
    "Stripping telemetry and diagnostics"
    "Trimming Windows apps and features you don't need for gaming"
    "Installing the latest GPU driver"
    "Installing AMD chipset drivers"
    "Installing Intel chipset and platform drivers"
    "Updating network, audio, and Bluetooth drivers"
    "Installing the .NET Desktop Runtime"
    "Installing Steam"
    "Setting up Big Picture autostart"
    "Enabling dark mode"
    "Setting your display to its best resolution"
    "Setting display scaling to 150%"
    "Applying a high-performance power plan"
    "Disabling background services you don't need"
    "Setting Helium as your default browser"
    "Preparing your gaming desktop"
)
$script:crawlItems       = New-Object System.Collections.ArrayList
$script:crawlNextIndex   = 0
$script:crawlSpawnTimer  = 0
$script:crawlSpawnEvery  = 55       # ticks between new lines (~1.8s at ~30fps)
$script:crawlSpeed       = 0.0018   # progress/frame -> ~18s bottom-to-vanish, Star Wars pace
$script:crawlFontFamily  = "Segoe UI"
$script:crawlBaseSize    = 22.0
$script:crawlColor       = [System.Drawing.Color]::FromArgb(255, 70, 80, 95)  # dark, muted
$script:crawlFmt = New-Object System.Drawing.StringFormat
$script:crawlFmt.Alignment     = [System.Drawing.StringAlignment]::Center
$script:crawlFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
$script:crawlBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0, $script:crawlColor))
$script:crawlFontCache = @{}
# Fonts are the expensive part of drawing crawl text (construction +
# measurement), so cache one per rounded pixel size and reuse it across every
# line and every frame instead of allocating fresh ones ~30 times a second.
function Get-CrawlFont {
    param([single]$Size)
    $key = [int]([math]::Round($Size))
    if ($key -lt 2) { $key = 2 }
    if (-not $script:crawlFontCache.ContainsKey($key)) {
        $script:crawlFontCache[$key] = New-Object System.Drawing.Font($script:crawlFontFamily, [single]$key, [System.Drawing.FontStyle]::Bold)
    }
    return $script:crawlFontCache[$key]
}

function Read-Status {
    # Open with FileShare.ReadWrite so a concurrent writer (the caller updating
    # the status, including the "__DONE__" sentinel) never collides with our
    # ~30 Hz polling. A rare partial/empty read just leaves the status unchanged
    # for one tick and self-corrects on the next.
    try {
        $fs = [System.IO.File]::Open($StatusFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            return $sr.ReadToEnd().Trim()
        } finally { $fs.Dispose() }
    } catch { return $null }
}

# Spawn/reset one star at the far plane with a fresh random position, size and
# colour. Stars are hashtables of normalised coords: X/Y in [-1,1], Z depth in
# (0,1] (1 = far, ~0 = right at the camera).
function New-Star {
    param($star)
    if (-not $star) { $star = @{} }
    $star.X = $script:rng.NextDouble() * 2.0 - 1.0
    $star.Y = $script:rng.NextDouble() * 2.0 - 1.0
    $star.Z = 1.0
    $star.Base = $script:rng.NextDouble() * 1.2 + 0.5   # base radius multiplier 0.5..1.7
    # Mostly cool white, a few warm-white and a few accent-cyan for depth.
    $roll = $script:rng.NextDouble()
    if     ($roll -lt 0.14) { $star.R = 120; $star.G = 200; $star.B = 255 }  # cyan
    elseif ($roll -lt 0.26) { $star.R = 255; $star.G = 244; $star.B = 224 }  # warm white
    else                    { $star.R = 226; $star.G = 236; $star.B = 255 }  # cool white
    return $star
}

# Seed from any status already written before we started.
$seed = Read-Status
if ($seed -and $seed -ne "__DONE__") { $script:status = $seed }

# ── The fullscreen black form ────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.WindowState     = [System.Windows.Forms.FormWindowState]::Maximized
$form.BackColor       = [System.Drawing.Color]::Black
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.KeyPreview      = $true
$form.Cursor          = [System.Windows.Forms.Cursors]::Default
$form.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
$form.Bounds          = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

# Double-buffer the form (the DoubleBuffered/SetStyle members are protected —
# reach them via reflection) so the starfield + spinning ring animate without flicker.
try {
    $setStyle = [System.Windows.Forms.Control].GetMethod('SetStyle', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $styles = [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
              [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
              [System.Windows.Forms.ControlStyles]::UserPaint
    $setStyle.Invoke($form, @([Object]$styles, [Object]$true)) | Out-Null
} catch { }

# Layout + reusable GDI+ resources, computed once the (fixed) fullscreen size is known.
$script:ready = $false
$form.Add_Shown({
    $script:W  = $form.ClientSize.Width
    $script:H  = $form.ClientSize.Height
    $script:cx = [int]($script:W / 2)
    $script:cy = [int]($script:H * 0.40)                     # ring sits a little above centre
    $script:R  = [int]([math]::Min($script:W, $script:H) * 0.17)
    $t         = [math]::Max(6, [int]($script:R * 0.11))     # ring thickness

    # Starfield projection: stars radiate from the true screen centre.
    $script:scx       = [double]($script:W / 2)
    $script:scy       = [double]($script:H / 2)
    $script:projScale = [double]($script:W * 0.55)
    $script:stars = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $script:starCount; $i++) {
        $s = New-Star $null
        $s.Z = $script:rng.NextDouble() * 0.9 + 0.1          # stagger initial depths so the field is full at frame 0
        [void]$script:stars.Add($s)
    }
    # One reusable pen for every star streak (round caps => a zero-length streak
    # still renders as a dot); colour + width are set per star during paint.
    $script:starPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [single]1)
    $script:starPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $script:starPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round

    $script:basePen = New-Object System.Drawing.Pen($script:accentDim, $t)
    $script:arcPen  = New-Object System.Drawing.Pen($script:accent, $t)
    $script:arcPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $script:arcPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $script:headBrush = New-Object System.Drawing.SolidBrush($script:accent)
    $script:whiteBrush= New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $script:subBrush  = New-Object System.Drawing.SolidBrush($script:accent)
    $script:statBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 170, 176, 188))

    # Title font, shrunk until "GAMING" fits comfortably inside the ring.
    $g = $form.CreateGraphics()
    $fs = [double]($script:R * 0.62)
    do {
        if ($script:titleFont) { $script:titleFont.Dispose() }
        $script:titleFont = New-Object System.Drawing.Font("Segoe UI", [single]$fs, [System.Drawing.FontStyle]::Bold)
        $sz = $g.MeasureString($Title, $script:titleFont)
        $fs -= 2
    } while ($sz.Width -gt ($script:R * 1.7) -and $fs -gt 10)
    $g.Dispose()

    $script:subFont  = New-Object System.Drawing.Font("Segoe UI", [single]([math]::Max(11, $script:R * 0.16)), [System.Drawing.FontStyle]::Bold)
    $script:statFont = New-Object System.Drawing.Font("Segoe UI", [single]([math]::Max(10, $script:R * 0.11)), [System.Drawing.FontStyle]::Regular)

    $script:centerFmt = New-Object System.Drawing.StringFormat
    $script:centerFmt.Alignment     = [System.Drawing.StringAlignment]::Center
    $script:centerFmt.LineAlignment = [System.Drawing.StringAlignment]::Center

    # Status text now carries specific, frequently-changing detail (what's
    # downloading/installing right now, not just a section name), so it wraps
    # onto two lines and gets a tighter fit than the centered ring/subtitle
    # text: top-aligned, word-wrapped, ellipsis if a single line still overflows.
    $script:statFmt = New-Object System.Drawing.StringFormat
    $script:statFmt.Alignment     = [System.Drawing.StringAlignment]::Center
    $script:statFmt.LineAlignment = [System.Drawing.StringAlignment]::Near
    $script:statFmt.Trimming      = [System.Drawing.StringTrimming]::EllipsisWord

    $script:ready = $true
    $form.Invalidate()
})

$form.Add_Paint({
    param($sender, $e)
    if (-not $script:ready) { return }
    $g = $e.Graphics
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear([System.Drawing.Color]::Black)

    # ── Crawl text (drawn first — furthest back, so the starfield below
    # renders on top of it and stars appear to pass through the text) ────────
    # Fonts are cached by rounded size and the brush is a single reused
    # instance with its Color swapped per line — with up to ~10 lines alive
    # at once, allocating a fresh Font (an expensive GDI+ object to
    # construct/measure) and Brush every single frame for every line was
    # producing exactly the stutter this was fixed for; now the ~30Hz timer
    # tick does no per-line allocation at all, just cache lookups and a
    # struct copy for the rectangle.
    foreach ($item in $script:crawlItems) {
        $p = [double]$item.Progress
        $yStart = $script:H + 30.0
        $yVanish = $script:scy
        $y = $yStart + (($yVanish - $yStart) * $p)
        $scale = 1.0 - (0.92 * $p)   # shrinks to ~8% size right at the vanishing point
        if ($scale -le 0.02) { continue }
        $fadeIn  = [math]::Min(1.0, $p / 0.05)
        $fadeOut = [math]::Min(1.0, (1.0 - $p) / 0.15)
        $alpha = [int](130 * $fadeIn * $fadeOut)
        if ($alpha -le 0) { continue }
        $size = [single]([math]::Max(2.0, $script:crawlBaseSize * $scale))
        $crawlFont = Get-CrawlFont -Size $size
        $script:crawlBrush.Color = [System.Drawing.Color]::FromArgb($alpha, $script:crawlColor.R, $script:crawlColor.G, $script:crawlColor.B)
        $crawlRect = New-Object System.Drawing.RectangleF(0, [single]($y - 40), [single]$script:W, [single]80)
        $g.DrawString($item.Text, $crawlFont, $script:crawlBrush, $crawlRect, $script:crawlFmt)
    }

    # ── Starfield (drawn next, on top of the crawl text, behind the ring/logo) ──
    $scx = $script:scx; $scy = $script:scy; $ps = $script:projScale
    foreach ($s in $script:stars) {
        $z = $s.Z
        $px = $scx + ($s.X / $z) * $ps
        $py = $scy + ($s.Y / $z) * $ps
        # Depth-driven look: nearer = bigger and brighter.
        $near   = 1.0 - $z
        $radius = [double]$s.Base * (0.4 + $near * 3.2)
        $alpha  = [int](40 + $near * 215); if ($alpha -gt 255) { $alpha = 255 }
        $script:starPen.Color = [System.Drawing.Color]::FromArgb($alpha, $s.R, $s.G, $s.B)
        $script:starPen.Width = [single]([math]::Max(1.0, $radius))
        # Streak from where the star was last frame to where it is now — the
        # motion trail that sells the "flying toward you" warp; round caps make
        # far/short streaks read as points.
        $zp  = $z + $script:warpSpeed
        $ppx = $scx + ($s.X / $zp) * $ps
        $ppy = $scy + ($s.Y / $zp) * $ps
        $g.DrawLine($script:starPen, [single]$ppx, [single]$ppy, [single]$px, [single]$py)
    }

    $R = $script:R; $cx = $script:cx; $cy = $script:cy
    $x = $cx - $R; $y = $cy - $R; $d = 2 * $R

    # Dim full base ring, then the bright rotating light arc on top of it.
    $g.DrawEllipse($script:basePen, $x, $y, $d, $d)
    $sweep = 80
    $g.DrawArc($script:arcPen, $x, $y, $d, $d, $script:angle, $sweep)

    # Bright leading "head" dot at the end of the arc, for the spinning-light feel.
    $headRad = ($script:angle + $sweep) * [math]::PI / 180.0
    $hx = $cx + $R * [math]::Cos($headRad)
    $hy = $cy + $R * [math]::Sin($headRad)
    $hr = [math]::Max(5, $R * 0.09)
    $g.FillEllipse($script:headBrush, [single]($hx - $hr), [single]($hy - $hr), [single](2 * $hr), [single](2 * $hr))

    # "GAMING" logo centred inside the ring.
    $titleRect = New-Object System.Drawing.RectangleF([single]($cx - $R), [single]($cy - $R), [single]$d, [single]$d)
    $g.DrawString($Title, $script:titleFont, $script:whiteBrush, $titleRect, $script:centerFmt)

    # "GAME MODE" heading + live status line beneath the ring.
    $subY  = $cy + $R + ($R * 0.35)
    $subRect = New-Object System.Drawing.RectangleF(0, [single]$subY, [single]$script:W, [single]($R * 0.4))
    $g.DrawString($Subtitle, $script:subFont, $script:subBrush, $subRect, $script:centerFmt)

    # Wider/taller than before and top-aligned + word-wrapped (statFmt) — the
    # status text now carries specific, frequently-changing detail (what's
    # downloading/installing right now) rather than short section names, so it
    # needs room to run onto a second line instead of getting clipped.
    $statY = $subY + ($R * 0.45)
    $statRect = New-Object System.Drawing.RectangleF([single]($script:W * 0.10), [single]$statY, [single]($script:W * 0.80), [single]($R * 1.3))
    $g.DrawString($script:status, $script:statFont, $script:statBrush, $statRect, $script:statFmt)
})

# ── Animation + status polling timer ─────────────────────────────────────────
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 33   # ~30 fps
$timer.Add_Tick({
    $script:angle = ($script:angle + 7) % 360

    # Fade the spinning arc/head into the next color a fraction of a degree
    # per frame — at ~30fps this is a full trip around the color wheel every
    # ~24 seconds, slow enough to read as a smooth continuous fade rather than
    # a color change you can actually catch happening.
    $script:hue = ($script:hue + 0.5) % 360
    $liveColor = Get-HueColor -Hue $script:hue
    if ($script:arcPen)    { $script:arcPen.Color    = $liveColor }
    if ($script:headBrush) { $script:headBrush.Color = $liveColor }

    # Advance the crawl text: each line rises toward the vanishing point at the
    # screen centre and is dropped once it gets there; a new line spawns at
    # the bottom on a fixed interval, cycling through the content list.
    if ($script:crawlItems -and $script:crawlItems.Count -gt 0) {
        for ($ci = $script:crawlItems.Count - 1; $ci -ge 0; $ci--) {
            $script:crawlItems[$ci].Progress += $script:crawlSpeed
            if ($script:crawlItems[$ci].Progress -ge 1.0) { $script:crawlItems.RemoveAt($ci) }
        }
    }
    $script:crawlSpawnTimer++
    if ($script:crawlSpawnTimer -ge $script:crawlSpawnEvery) {
        $script:crawlSpawnTimer = 0
        $crawlText = $script:crawlContent[$script:crawlNextIndex % $script:crawlContent.Count]
        $script:crawlNextIndex++
        [void]$script:crawlItems.Add(@{ Text = $crawlText; Progress = 0.0 })
    }

    # Advance the starfield: each star moves toward the camera; recycle it at
    # the far plane once it passes the camera or flies well off-screen.
    if ($script:stars) {
        foreach ($s in $script:stars) {
            $s.Z = $s.Z - $script:warpSpeed
            if ($s.Z -le $script:zNear -or
                [math]::Abs($s.X / $s.Z) -gt 2.4 -or
                [math]::Abs($s.Y / $s.Z) -gt 2.4) {
                New-Star $s | Out-Null
            }
        }
    }

    # Re-assert topmost + foreground EVERY frame (~30 Hz) — not just every half
    # second — so nothing (a transient window, a SmartScreen/driver-install
    # dialog, the desktop repainting, Steam's own splash) has more than one
    # frame's worth of a chance to show through in front of the loader. This
    # was previously throttled to every ~500ms, which left a real gap other
    # windows could win. BringToFront + Activate additionally reclaims actual
    # foreground/input focus, not just Z-order — a plain TopMost toggle can
    # still lose to another window that also just set itself topmost.
    $script:tick++
    try {
        $form.TopMost = $false; $form.TopMost = $true
        $form.BringToFront()
        $form.Activate()
    } catch {}

    $s = Read-Status
    if ($s -eq "__DONE__") { $timer.Stop(); $form.Close(); return }
    elseif ($s) { $script:status = $s }

    if (((Get-Date) - $script:started).TotalSeconds -gt $TimeoutSeconds) {
        $timer.Stop(); $form.Close(); return
    }
    $form.Invalidate()
})

# Esc is a manual escape hatch (mainly for testing on a normal desktop).
$form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $timer.Stop(); $form.Close() } })

$form.Add_FormClosed({
    foreach ($r in @($script:starPen,$script:basePen,$script:arcPen,$script:headBrush,$script:whiteBrush,
                      $script:subBrush,$script:statBrush,$script:titleFont,$script:subFont,
                      $script:statFont,$script:centerFmt,$script:crawlBrush,$script:crawlFmt,$timer)) {
        try { if ($r) { $r.Dispose() } } catch {}
    }
    if ($script:crawlFontCache) {
        foreach ($f in $script:crawlFontCache.Values) { try { $f.Dispose() } catch {} }
    }
})

$timer.Start()
[System.Windows.Forms.Application]::Run($form)
