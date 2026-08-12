$SampleRate = 44100
$DurationMs = 150                               
$BytesPerSample = 2                              
$BufferSize = [int]($SampleRate * ($DurationMs / 1000) * $BytesPerSample)
# INCREASED: Higher number means quiet room noise is completely ignored
$EnergyThreshold = 0.20 
# TIGHTER: Lower number means live taps must match your calibration profile strictly
$MatchStrictness = 0.10                        
$NumCalibrationTaps = 5                       

$Zones = @{
    1 = "Upper Left (Left Rear)"
    2 = "Upper Right (Right Rear)"
    3 = "Lower Left (Left Front)"
    4 = "Lower Right (Right Front)"
}

# --- ACTIONS CONFIGURATION ---
function Trigger-Action([int]$zoneId) {
    Write-Host "`n[💥 ACTION] Triggered action for Zone ${zoneId}: $($Zones[$zoneId])" -ForegroundColor Cyan
    $wsh = New-Object -ComObject WScript.Shell
    
    switch ($zoneId) {
        1 { $wsh.SendKeys([char]175) }                  # Upper Left: Vol Up
        2 { Start-Process "msteams:" -ErrorAction SilentlyContinue } # Upper Right: Microsoft Teams
        3 { $wsh.SendKeys([char]174) }                  # Lower Left: Vol Down
        4 { 
            $vsCodePath = "$env:LocalAppData\Programs\Microsoft VS Code\Code.exe"
            if (Test-Path $vsCodePath) { Start-Process $vsCodePath } else { Start-Process "code" -ErrorAction SilentlyContinue }
        }
    }
}

# --- COMPLETE MEMORY-SAFE NATIVE AUDIO BRIDGE ---
if (-not ([System.Management.Automation.PSTypeName]'AudioHelper.WinMMBridge').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace AudioHelper
{
    [StructLayout(LayoutKind.Sequential)]
    public struct WAVEFORMATEX
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WAVEHDR
    {
        public IntPtr lpData;
        public uint dwBufferLength;
        public uint dwBytesRecorded;
        public IntPtr dwUser;
        public uint dwFlags;
        public uint dwLoops;
        public IntPtr lpNext;
        public IntPtr reserved;
    }

    public class WinMMBridge
    {
        [DllImport("winmm.dll", SetLastError = true)]
        private static extern int waveInOpen(out IntPtr phwi, uint uDeviceID, ref WAVEFORMATEX pwfx, IntPtr dwCallback, IntPtr dwInstance, uint fdwOpen);

        [DllImport("winmm.dll", SetLastError = true)]
        private static extern int waveInPrepareHeader(IntPtr hwi, ref WAVEHDR pwh, uint cbwh);

        [DllImport("winmm.dll", SetLastError = true)]
        private static extern int waveInAddBuffer(IntPtr hwi, ref WAVEHDR pwh, uint cbwh);

        [DllImport("winmm.dll", SetLastError = true)]
        private static extern int waveInStart(IntPtr hwi);

        [DllImport("winmm.dll", SetLastError = true)]
        private static extern int waveInStop(IntPtr hwi);

        [DllImport("winmm.dll", SetLastError = true)]
        private static extern int waveInReset(IntPtr hwi);

        [DllImport("winmm.dll", SetLastError = true)]
        private static extern int waveInClose(IntPtr hwi);

        public static byte[] RecordAudioChunk(uint sampleRate, int durationMs, int bufferSize)
        {
            IntPtr hWaveIn = IntPtr.Zero;
            WAVEFORMATEX wfx = new WAVEFORMATEX();
            wfx.wFormatTag = 1;
            wfx.nChannels = 1;
            wfx.nSamplesPerSec = sampleRate;
            wfx.wBitsPerSample = 16;
            wfx.nBlockAlign = 2;
            wfx.nAvgBytesPerSec = sampleRate * 2;
            wfx.cbSize = 0;

            if (waveInOpen(out hWaveIn, 0, ref wfx, IntPtr.Zero, IntPtr.Zero, 0) != 0)
            {
                return null;
            }

            IntPtr hBuffer = Marshal.AllocHGlobal(bufferSize);
            byte[] managedBuffer = new byte[bufferSize];

            try
            {
                WAVEHDR whdr = new WAVEHDR();
                whdr.lpData = hBuffer;
                whdr.dwBufferLength = (uint)bufferSize;
                whdr.dwFlags = 0;

                waveInPrepareHeader(hWaveIn, ref whdr, (uint)Marshal.SizeOf(whdr));
                waveInAddBuffer(hWaveIn, ref whdr, (uint)Marshal.SizeOf(whdr));

                waveInStart(hWaveIn);
                System.Threading.Thread.Sleep(durationMs);
                waveInStop(hWaveIn);

                Marshal.Copy(hBuffer, managedBuffer, 0, bufferSize);
            }
            finally
            {
                waveInReset(hWaveIn);
                waveInClose(hWaveIn);
                if (hBuffer != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(hBuffer);
                }
            }

            return managedBuffer;
        }
    }
}
'@
}

# --- AUDIO FEATURE EXTRACTION ---
function Get-TapProfile {
    $managedBuffer = [AudioHelper.WinMMBridge]::RecordAudioChunk($SampleRate, $DurationMs, $BufferSize)
    if ($null -eq $managedBuffer) { return $null }
    
    $samples = New-Object Int16[] ($BufferSize / 2)
    [Buffer]::BlockCopy($managedBuffer, 0, $samples, 0, $BufferSize)
    
    $chunkSize = 22 
    $profile = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $samples.Length; $i += $chunkSize) {
        $sum = 0
        $count = 0
        for ($j = $i; $j -lt ($i + $chunkSize) -and $j -lt $samples.Length; $j++) {
            $val = $samples[$j]
            if ($val -lt 0) { $sum -= $val } else { $sum += $val }
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

function Listen-ForTap {
    while ($true) {
        $profile = Get-TapProfile
        if ($null -eq $profile) { Start-Sleep -Milliseconds 300; continue }
        
        $maxEnergy = 0
        foreach ($val in $profile) { if ($val -gt $maxEnergy) { $maxEnergy = $val } }
        
        # TUNED: Only accept the sample if peak energy clears our minimum noise floor
        if ($maxEnergy -gt $EnergyThreshold) { return ,$profile }
        Start-Sleep -Milliseconds 30
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
    if ($null -eq $liveProfile) { Start-Sleep -Milliseconds 300; continue }
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
    
    # TUNED: Distance must now be tightly constrained by $MatchStrictness
    if ($bestZone -ne -1 -and $minDistance -lt $MatchStrictness) { 
        Trigger-Action $bestZone
        Start-Sleep -Milliseconds 400 # Cooldown to prevent multi-triggering
    }
    Start-Sleep -Milliseconds 100 
}
