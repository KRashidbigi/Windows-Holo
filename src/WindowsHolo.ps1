# ==================================================================================
# SURFACE HOLO ENGINE (Universal Windows Port)
# ==================================================================================
# Core concept, logic flow, and zone layouts adapted from the macOS project 'Holo'
# Original Creator: JustinGamer191 (https://github.com)
# Compatible with both x64 and ARM64 Windows 10/11 architectures.
# Safe memory management patch applied.
# ==================================================================================

# --- CONFIGURATION ---
$SampleRate = 44100
$DurationMs = 150                               
$BytesPerSample = 2                              
$BufferSize = [int]($SampleRate * ($DurationMs / 1000) * $BytesPerSample)
$Threshold = 1200                                # Lowered slightly for universal compatibility
$NumCalibrationTaps = 5                         

$Zones = @{
    1 = "Upper Left (Left Rear)"
    2 = "Upper Right (Right Rear)"
    3 = "Lower Left (Left Front)"
    4 = "Lower Right (Right Front)"
}

# --- ACTIONS CONFIGURATION ---
function Trigger-Action([int]$zoneId) {
    Write-Host "`n[💥 ACTION] Triggered action for Zone $zoneId: $($Zones[$zoneId])" -ForegroundColor Cyan
    $wsh = New-Object -ComObject WScript.Shell
    
    switch ($zoneId) {
        1 { $wsh.SendKeys([char]175) }                  # Upper Left: Vol Up
        2 { Start-Process "msteams:" }                  # Upper Right: Microsoft Teams
        3 { $wsh.SendKeys([char]174) }                  # Lower Left: Vol Down
        4 { 
            # Lower Right: VS Code (Checks local user path first, then global fallback)
            $vsCodePath = "$env:LocalAppData\Programs\Microsoft VS Code\Code.exe"
            if (Test-Path $vsCodePath) { Start-Process $vsCodePath } else { Start-Process "code" -ErrorAction SilentlyContinue }
        }
    }
}

# --- NATIVE WINDOWS AUDIO RECORDING API ---
$Signatures = @'
[DllImport("winmm.dll")] public static extern int waveInOpen(out IntPtr phwi, uint uDeviceID, ref WAVEFORMATEX pwfx, IntPtr dwCallback, IntPtr dwInstance, uint fdwOpen);
[DllImport("winmm.dll")] public static extern int waveInPrepareHeader(IntPtr hwi, ref WAVEHDR pwh, uint cbwh);
[DllImport("winmm.dll")] public static extern int waveInAddBuffer(IntPtr hwi, ref WAVEHDR pwh, uint cbwh);
[DllImport("winmm.dll")] public static extern int waveInStart(IntPtr hwi);
[DllImport("winmm.dll")] public static extern int waveInStop(IntPtr hwi);
[DllImport("winmm.dll")] public static extern int waveInReset(IntPtr hwi);
[DllImport("winmm.dll")] public static extern int waveInClose(IntPtr hwi);
[StructLayout(LayoutKind.Sequential)] public struct WAVEFORMATEX { public ushort wFormatTag; public ushort nChannels; public uint nSamplesPerSec; public uint nAvgBytesPerSec; public ushort nBlockAlign; public ushort wBitsPerSample; public ushort cbSize; }
[StructLayout(LayoutKind.Sequential)] public struct WAVEHDR { public IntPtr lpData; public uint dwBufferLength; public uint dwBytesRecorded; public IntPtr dwUser; public uint dwFlags; public uint dwLoops; public IntPtr lpNext; public IntPtr reserved; }
'@
$WinMM = Add-Type -MemberDefinition $Signatures -Name "WinMM" -Namespace "NativeAudio" -PassThru

$wfx = New-Object NativeAudio.WAVEFORMATEX
$wfx.wFormatTag = 1 
$wfx.nChannels = 1
$wfx.nSamplesPerSec = $SampleRate
$wfx.wBitsPerSample = 16
$wfx.nBlockAlign = 2
$wfx.nAvgBytesPerSec = $SampleRate * 2
$wfx.cbSize = 0

# --- AUDIO FEATURE EXTRACTION ---
function Get-TapProfile {
    $hWaveIn = [IntPtr]::Zero
    if ($WinMM::waveInOpen([ref]$hWaveIn, 0, [ref]$wfx, [IntPtr]::Zero, [IntPtr]::Zero, 0) -ne 0) { return $null }
    
    # Allocate unmanaged system memory buffer
    $hBuffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($BufferSize)
    
    try {
        $whdr = New-Object NativeAudio.WAVEHDR
        $whdr.lpData = $hBuffer
        $whdr.dwBufferLength = $BufferSize
        $whdr.dwFlags = 0
        
        $WinMM::waveInPrepareHeader($hWaveIn, [ref]$whdr, [System.Runtime.InteropServices.Marshal]::SizeOf($whdr)) | Out-Null
        $WinMM::waveInAddBuffer($hWaveIn, [ref]$whdr, [System.Runtime.InteropServices.Marshal]::SizeOf($whdr)) | Out-Null
        
        $WinMM::waveInStart($hWaveIn) | Out-Null
        Start-Sleep -Milliseconds $DurationMs
        $WinMM::waveInStop($hWaveIn) | Out-Null
        
        $managedBuffer = New-Object byte[] $BufferSize
        [System.Runtime.InteropServices.Marshal]::Copy($hBuffer, $managedBuffer, 0, $BufferSize)
        
        $WinMM::waveInReset($hWaveIn) | Out-Null
        $WinMM::waveInClose($hWaveIn) | Out-Null
        
        $samples = New-Object Int16[] ($BufferSize / 2)
        [Buffer]::BlockCopy($managedBuffer, 0, $samples, 0, $BufferSize)
        
        $chunkSize = 22 
        $profile = New-Object System.Collections.Generic.List[double]
        for ($i = 0; $i -lt $samples.Length; $i += $chunkSize) {
            $sum = 0
            $count = 0
            for ($j = $i; $j -lt ($i + $chunkSize) -and $j -lt $samples.Length; $j++) {
                $sum += [Math]::Abs([double]$samples[$j])
                $count++
            }
            $profile.Add($sum / $count)
        }
        
        $magnitude = 0.0
        foreach ($val in $profile) { $magnitude += $val * $val }
        $magnitude = [Math]::Sqrt($magnitude)
        
        if ($magnitude -eq 0) { return $profile }
        $normProfile = New-Object double[] $profile.Count
        for ($i = 0; $i -lt $profile.Count; $i++) { $normProfile[$i] = $profile[$i] / $magnitude }
        
        return ,$normProfile
    }
    finally {
        # This block ALWAYS runs, forcing Windows to release the RAM even if a crash happens
        if ($hBuffer -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($hBuffer)
        }
    }
}

function Listen-ForTap {
    while ($true) {
        $profile = Get-TapProfile
        $maxEnergy = 0
        foreach ($val in $profile) { if ($val -gt $maxEnergy) { $maxEnergy = $val } }
        if ($maxEnergy -gt 0.0) { return ,$profile }
        Start-Sleep -Milliseconds 50
    }
}

# --- EXECUTION ENGINE ---
Clear-Host
Write-Host "====================================================" -ForegroundColor Yellow
Write-Host "         UNIVERSAL WINDOWS HOLO TAP ENGINE          " -ForegroundColor Yellow
Write-Host "====================================================" -ForegroundColor Yellow

$Database = @{}

# 1. NATIVE CALIBRATION
Write-Host "`n--- PHASE 1: NATIVE CALIBRATION ---" -ForegroundColor Yellow
foreach ($zoneKey in ($Zones.Keys | Sort-Object)) {
    Write-Host "`n👉 Prepare to calibrate Zone $zoneKey [$($Zones[$zoneKey])]" -ForegroundColor White
    Read-Host "Press Enter to start calibrating, then perform your taps..."
    
    $zoneProfiles = New-Object System.Collections.Generic.List[double[]]
    for ($i = 1; $i -le $NumCalibrationTaps; $i++) {
        Write-Host "  [$i/$NumCalibrationTaps] Tap $($Zones[$zoneKey]) now... " -NoNewline
        $profile = Listen-ForTap
        $zoneProfiles.Add($profile)
        Write-Host "Captured!" -ForegroundColor Green
        Start-Sleep -Milliseconds 400
    }
    $Database[$zoneKey] = $zoneProfiles
}

# 2. LIVE LISTENING ENGINE
Write-Host "`n--- PHASE 2: LIVE RUNTIME ACTIVE ---" -ForegroundColor Yellow
Write-Host "Tap your desk zones to interact. Press Ctrl+C to close script." -ForegroundColor Gray

while ($true) {
    $liveProfile = Listen-ForTap
    $bestZone = -1
    $minDistance = [double]::MaxValue
    
    foreach ($zoneKey in $Database.Keys) {
        foreach ($calibratedProfile in $Database[$zoneKey]) {
            $distance = 0.0
            for ($i = 0; $i -lt $liveProfile.Length; $i++) {
                $diff = $liveProfile[$i] - $calibratedProfile[$i]
                $distance += $diff * $diff
            }
            if ($distance -lt $minDistance) {
                $minDistance = $distance
                $bestZone = $zoneKey
            }
        }
    }
    
    if ($bestZone -ne -1 -and $minDistance -lt 0.8) { 
        Trigger-Action $bestZone
    }
    Start-Sleep -Milliseconds 600 
}
