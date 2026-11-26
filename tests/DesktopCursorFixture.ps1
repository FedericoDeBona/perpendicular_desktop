param([switch]$Automated)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$form = [Windows.Forms.Form]::new()
$form.Text = 'Perpendicular - prova puntatore'
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.Bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$form.TopMost = $true
$form.KeyPreview = $true
$form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })

$background = [Drawing.Color]::FromArgb(42, 137, 170)
$form.BackColor = $background
$midX = [int]($form.ClientSize.Width / 2)
$midY = [int]($form.ClientSize.Height / 2)
$boundaries = @(0, ($midX - 35), ($midX + 35), $form.ClientSize.Width)
$shapes = @([Windows.Forms.Cursors]::Arrow, [Windows.Forms.Cursors]::Hand, [Windows.Forms.Cursors]::IBeam)
for ($i = 0; $i -lt $shapes.Count; $i++) {
    $region = [Windows.Forms.Panel]::new()
    $region.SetBounds($boundaries[$i], 0, ($boundaries[$i + 1] - $boundaries[$i]), $form.ClientSize.Height)
    $region.BackColor = $background
    $region.Cursor = $shapes[$i]
    $form.Controls.Add($region)
}

# Keep the measured part of the desktop flat. Change a square in the corner
# so the native publisher receives frames even with Windows' cursor hidden.
$beacon = [Windows.Forms.Panel]::new()
$beacon.SetBounds(16, 16, 20, 20)
$form.Controls.Add($beacon)
$beacon.BringToFront()
$marker = [Windows.Forms.Panel]::new()
$marker.SetBounds(($midX + 18), ($midY + 12), 12, 12)
$marker.BackColor = [Drawing.Color]::Black
$marker.Visible = $Automated.IsPresent
$form.Controls.Add($marker)
$marker.BringToFront()

if (!$Automated) {
    $guide = [Windows.Forms.Label]::new()
    $guide.Text = 'Muovi il cursore di poco a sinistra e a destra del centro. Esc per uscire.'
    $guide.TextAlign = 'MiddleCenter'
    $guide.ForeColor = [Drawing.Color]::White
    $guide.SetBounds(($midX - 360), ($midY - 170), 720, 50)
    $form.Controls.Add($guide)
    $guide.BringToFront()
    foreach ($offset in @(-180, 180)) {
        $tickMark = [Windows.Forms.Panel]::new()
        $tickMark.BackColor = [Drawing.Color]::White
        $tickMark.SetBounds(($midX + $offset), $midY, 12, 2)
        $form.Controls.Add($tickMark)
        $tickMark.BringToFront()
    }
}

$clock = [Diagnostics.Stopwatch]::new()
$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 50
$script:tick = 0
$script:lastShape = 0
$previousPosition = [Windows.Forms.Cursor]::Position
$shapeOffsets = @(-24, 0, 24)
$duration = $(if ($Automated) { 15 } else { 50 })
$timer.Add_Tick({
    $elapsed = $clock.Elapsed.TotalSeconds
    if ($elapsed -ge $duration) { $form.Close(); return }
    $script:tick++
    $beacon.BackColor = $(if ($script:tick % 2) { [Drawing.Color]::White } else { [Drawing.Color]::Black })
    if (!$Automated -or $elapsed -lt 3) { return }
    $marker.Visible = $false
    if ($script:tick % 5 -ne 0) { return }
    $script:lastShape = ($script:lastShape + 1) % $shapes.Count
    # Keep the hotspot in the sampled region on high-DPI displays, too.
    [Windows.Forms.Cursor]::Position = [Drawing.Point]::new(($midX + $shapeOffsets[$script:lastShape]), ($midY - 8))
    [Windows.Forms.Cursor]::Current = $shapes[$script:lastShape]
})
$form.Add_Shown({ $form.Activate(); $clock.Start(); $timer.Start() })
try { [void]$form.ShowDialog() }
finally {
    $timer.Dispose()
    $form.Dispose()
    if ($Automated) { [Windows.Forms.Cursor]::Position = $previousPosition }
}
