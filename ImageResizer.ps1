param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [string]$Destination = "",
    [int]$MaxWidth = 1920,
    [int]$MaxHeight = 1080,
    [int]$Quality = 85,
    [bool]$Overwrite = $false,
    [bool]$IncludeSubfolders = $true
)

# Unterstützte Formate
$Extensions = @(".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp")

if (!(Test-Path -LiteralPath $Source)) {
    Write-Error "Quellordner existiert nicht: $Source"
    exit 1
}

# Zielordner vorbereiten (falls genutzt)
$useSeparateDest = -not [string]::IsNullOrWhiteSpace($Destination)
if ($useSeparateDest) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

# .NET Imaging laden
Add-Type -AssemblyName System.Drawing

function Fix-ExifOrientation {
    param([System.Drawing.Image]$img)
    try {
        $o = ($img.PropertyItems | Where-Object { $_.Id -eq 274 })
        if ($o) {
            $val = [int]$o.Value[0]
            switch ($val) {
                2 { $img.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX) }
                3 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
                4 { $img.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipY) }
                5 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipX) }
                6 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
                7 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipX) }
                8 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
            }
            # Orientierung zurücksetzen
            $o.Value[0] = 1
            $img.SetPropertyItem($o)
        }
    }
    catch { }
}

function Get-RelativePath {
    param([string]$basePath, [string]$fullPath)
    # Liefert den Pfad von fullPath relativ zu basePath (ohne führenden Slash)
    $base = (Resolve-Path -LiteralPath $basePath).Path.TrimEnd('\')
    $full = (Resolve-Path -LiteralPath $fullPath).Path
    if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($base.Length)
        return $rel.TrimStart('\')
    }
    # Fallback (sollte nicht passieren, falls $full unter $base liegt)
    return Split-Path -Path $full -Leaf
}

function Get-OutputPath {
    param([string]$inPath)
    if ($useSeparateDest) {
        $rel = Get-RelativePath -basePath $Source -fullPath $inPath
        $outFull = Join-Path -Path $Destination -ChildPath $rel
        # Ordnerstruktur nachbilden
        $outDir = Split-Path -Path $outFull -Parent
        if (!(Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        return $outFull
    }
    else {
        return $inPath
    }
}

function Save-Image {
    param(
        [System.Drawing.Image]$img, 
        [string]$outPath, 
        [int]$quality
    )
    $ext = [System.IO.Path]::GetExtension($outPath).ToLowerInvariant()
    $codecJpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }

    # Transparenz?
    $hasAlpha = $false
    try { $hasAlpha = $img.PixelFormat.ToString().ToLower().Contains("alpha") } catch {}

    $outDir = Split-Path -Path $outPath -Parent
    if (!(Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    if ($ext -in @(".jpg", ".jpeg") -and -not $hasAlpha) {
        $encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [int64]$quality)
        $img.Save($outPath, $codecJpeg, $encParams)
    }
    else {
        $outPathPng = [System.IO.Path]::ChangeExtension($outPath, ".png")
        $img.Save($outPathPng, [System.Drawing.Imaging.ImageFormat]::Png)
    }
}

function Resize-IfNeeded {
    param([string]$inPath)
    

    # Wenn wir am Ursprungsort schreiben und Overwrite=false: nichts tun
    if ((-not $useSeparateDest) -and (-not $Overwrite)) {
        Write-Verbose "Überspringe (Overwrite=false): $inPath"
        return
    }

    $outPath = Get-OutputPath -inPath $inPath

    try {
        $img = [System.Drawing.Image]::FromFile($inPath)
    
        try {
            Fix-ExifOrientation -img $img

            $w = [double]$img.Width
            $h = [double]$img.Height

            $scale = [Math]::Min($MaxWidth / $w, $MaxHeight / $h)
            if ($scale -ge 1.0) {
                if ($useSeparateDest) {
                    Copy-Item -LiteralPath $inPath -Destination $outPath -Force
                }
                else {
                    Write-Host "Unverändert: $inPath"
                }
                return
            }

            $newW = [int][Math]::Round($w * $scale)
            $newH = [int][Math]::Round($h * $scale)

            $bmp = New-Object System.Drawing.Bitmap($newW, $newH)
            try {
                $gfx = [System.Drawing.Graphics]::FromImage($bmp)
                try {
                    $gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $gfx.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $gfx.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                    $gfx.DrawImage($img, 0, 0, $newW, $newH)
                }
                finally { $gfx.Dispose() }

                Save-Image -img $bmp -outPath $outPath -quality $Quality
                Write-Host ("Verkleinert: {0} -> {1} ({2}x{3} -> {4}x{5})" -f $inPath, $outPath, [int]$w, [int]$h, $newW, $newH)
            }
            finally {
                $bmp.Dispose()
            }
        }
        finally {
            $img.Dispose()
        }
    }
    catch {
        Write-Warning ("Fehler bei {0}: {1}" -f $inPath, $_.Exception.Message)
    }
}

$files = Get-ChildItem -LiteralPath $Source -Recurse:$IncludeSubfolders -File |
Where-Object { $Extensions -contains $_.Extension.ToLowerInvariant() }

foreach ($f in $files) {
    Resize-IfNeeded -inPath $f.FullName
}

Write-Host "Fertig. Dateien verarbeitet: $($files.Count)"