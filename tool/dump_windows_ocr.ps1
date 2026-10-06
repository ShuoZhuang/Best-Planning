# Captures what Windows OCR actually returns for an image, as JSON, so the
# timetable parser can be inspected against real engine output.
#
# Must run under Windows PowerShell 5.1 (WinRT projection is unavailable in
# PowerShell 7):
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool/dump_windows_ocr.ps1 `
#     -Path C:\path\to\timetable.jpg -Out C:\path\to\dump.json
#
# Then feed the dump to `dart run tool/timetable_ocr_probe.dart <dump.json>`.
# Images and dumps contain the user's own timetable: keep them outside the repo.

param(
  [Parameter(Mandatory = $true)][string]$Path,
  [string]$Out,
  [string]$Language = 'zh-Hans'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) { throw "image not found: $Path" }
if (-not $Out) { $Out = [System.IO.Path]::ChangeExtension($Path, '.ocr.json') }

Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
  })[0]

function Await($op, [Type]$type) {
  $asTask = $asTaskGeneric.MakeGenericMethod($type)
  $task = $asTask.Invoke($null, @($op))
  $task.Wait(-1) | Out-Null
  $task.Result
}

[void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
[void][Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
[void][Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]

Write-Host "MaxImageDimension = $([Windows.Media.Ocr.OcrEngine]::MaxImageDimension)"
Write-Host "AvailableRecognizerLanguages = $(([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag }) -join ', ')"

# NOTE: PowerShell variable names are case-insensitive — do not call this
# $language, or it overwrites the $Language parameter.
$recognizerLanguage = New-Object Windows.Globalization.Language $Language
if (-not [Windows.Media.Ocr.OcrEngine]::IsLanguageSupported($recognizerLanguage)) {
  throw "the installed OCR languages do not include '$Language'"
}
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($recognizerLanguage)
if ($null -eq $engine) { throw "could not create an OCR engine for '$Language'" }
Write-Host "engine language = $($engine.RecognizerLanguage.LanguageTag)"

# Opens the file through StorageFile, which is what a plain console process can
# always do. (The shipped app instead reads the bytes itself and hands them to
# the decoder through an in-memory stream, because a packaged process can be
# denied StorageFile access to the user's own paths; the engine call below is
# the same either way.)
$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])

$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

$lines = @()
foreach ($line in $result.Lines) {
  $words = @()
  foreach ($word in $line.Words) {
    $rect = $word.BoundingRect
    $words += [ordered]@{
      text   = $word.Text
      bounds = [ordered]@{
        left   = $rect.X
        top    = $rect.Y
        width  = $rect.Width
        height = $rect.Height
      }
    }
  }
  $lines += [ordered]@{ text = $line.Text; words = $words }
}

$angle = $null
if ($null -ne $result.TextAngle) { $angle = $result.TextAngle }

$payload = [ordered]@{
  width     = $decoder.PixelWidth
  height    = $decoder.PixelHeight
  textAngle = $angle
  lines     = $lines
}

$payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Out -Encoding UTF8
Write-Host "wrote $Out : $($lines.Count) lines, $($decoder.PixelWidth)x$($decoder.PixelHeight)"
