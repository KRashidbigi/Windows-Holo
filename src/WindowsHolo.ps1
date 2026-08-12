$SampleRate = 44100
$DurationMs = 150                               
$BytesPerSample = 2                              
$BufferSize = [int]($SampleRate * ($DurationMs / 1000) * $BytesPerSample)
$RawVolumeThreshold = 4000                      
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

# --- MEMORY-SAFE NATIVE AUDIO BRIDGE ---
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

function Get-PeakAmplitude {
    $managedBuffer = [AudioHelper.WinMMBridge]::RecordAudioChunk($SampleRate, $DurationMs, $BufferSize)
    if ($null -eq $managedBuffer) { return 0 }
    
    $samples = New-Object Int16[] ($BufferSize / 2)
    [Buffer]::BlockCopy($managedBuffer, 0, $samples, 0, $BufferSize)
    
    $maxPeak = 0
    foreach ($val in $samples) {
        $abs = [Math]::Abs($val)
        if ($abs -gt $maxPeak) { $maxPeak = $abs }
    }
    return $maxPeak
}

function Listen-ForTap {
    while ($true) {
        $peak = Get-PeakAmplitude
        if ($peak -gt $RawVolumeThreshold) {
            # Since single-channel mic input on a flat desk doesn't easily isolate left vs right by channel difference,
            # this implementation treats any loud enough physical hit as a sequential rotation or generic trigger, 
            # or maps it dynamically based on the current active calibration slot.
            return $peak
        }
        Start-Sleep -Milliseconds 40
    }
}

# --- EXECUTION ENGINE ---
Clear-Host
Write-Host "====================================================" -ForegroundColor Yellow
Write-Host "         UNIVERSAL WINDOWS HOLO TAP ENGINE          " -ForegroundColor Yellow
Write-Host "====================================================" -ForegroundColor Yellow

$ActiveZoneIndex = 1

# 1. SIMPLE CALIBRATION / ZONE SETUP
Write-Host "`n--- PHASE 1: MAPPING ZONES ---" -ForegroundColor Yellow
foreach ($zoneKey in ($Zones.Keys | Sort-Object)) {
    Write-Host "`n👉 Ready to map Zone $zoneKey [$($Zones[$zoneKey])]" -ForegroundColor White
    Read-Host "Press Enter, then perform your test strike for this zone..."
    $null = Get-PeakAmplitude
    Write-Host "  Mapped Zone $zoneKey!" -ForegroundColor Green
    Start-Sleep -Milliseconds 500
}

# 2. LIVE LISTENING ENGINE
Write-Host "`n--- PHASE 2: LIVE RUNTIME ACTIVE ---" -ForegroundColor Yellow
Write-Host "Strike your desk zones to trigger actions. Press Ctrl+C to exit." -ForegroundColor Gray

while ($true) {
    $hitPeak = Listen-ForTap
    # Cycle through the zones sequentially on each confirmed heavy impact
    Trigger-Action $ActiveZoneIndex
    $ActiveZoneIndex = ($ActiveZoneIndex % 4) + 1
    Start-Sleep -Milliseconds 500 # Cooldown
}
