$SampleRate = 44100
$DurationMs = 150                               
$BytesPerSample = 2                              
$Channels = 2
$BufferSize = [int]($SampleRate * ($DurationMs / 1000) * $BytesPerSample * $Channels)
$RawVolumeThreshold = 3000                      

$Zones = @{
    1 = "Left Side Tap (Left Kickstand)"
    2 = "Right Side Tap (Right Kickstand)"
}

# --- ACTIONS CONFIGURATION ---
function Trigger-Action([int]$zoneId) {
    Write-Host "`n[💥 ACTION] Triggered action for Zone ${zoneId}: $($Zones[$zoneId])" -ForegroundColor Cyan
    $wsh = New-Object -ComObject WScript.Shell
    
    switch ($zoneId) {
        1 { $wsh.SendKeys([char]174) }                  # Left Side: Vol Down
        2 { $wsh.SendKeys([char]175) }                  # Right Side: Vol Up
    }
}

# --- MEMORY-SAFE STEREO AUDIO BRIDGE ---
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

        public static byte[] RecordAudioChunk(uint sampleRate, ushort channels, int durationMs, int bufferSize)
        {
            IntPtr hWaveIn = IntPtr.Zero;
            WAVEFORMATEX wfx = new WAVEFORMATEX();
            wfx.wFormatTag = 1;
            wfx.nChannels = channels;
            wfx.nSamplesPerSec = sampleRate;
            wfx.wBitsPerSample = 16;
            wfx.nBlockAlign = (ushort)(channels * 2);
            wfx.nAvgBytesPerSec = sampleRate * wfx.nBlockAlign;
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

function Get-StereoPeaks {
    $managedBuffer = [AudioHelper.WinMMBridge]::RecordAudioChunk($SampleRate, 2, $DurationMs, $BufferSize)
    if ($null -eq $managedBuffer) { return $null }
    
    $samples = New-Object Int16[] ($BufferSize / 2)
    [Buffer]::BlockCopy($managedBuffer, 0, $samples, 0, $BufferSize)
    
    $leftMax = 0
    $rightMax = 0
    
    # Interleaved stereo layout: [Left0, Right0, Left1, Right1, ...]
    for ($i = 0; $i -lt $samples.Length; $i += 2) {
        $lVal = [Math]::Abs($samples[$i])
        $rVal = [Math]::Abs($samples[$i+1])
        if ($lVal -gt $leftMax) { $leftMax = $lVal }
        if ($rVal -gt $rightMax) { $rightMax = $rVal }
    }
    
    return @{ Left = $leftMax; Right = $rightMax }
}

function Listen-ForStereoTap {
    while ($true) {
        $peaks = Get-StereoPeaks
        if ($null -eq $peaks) { Start-Sleep -Milliseconds 40; continue }
        
        $maxGlobal = [Math]::Max($peaks.Left, $peaks.Right)
        if ($maxGlobal -gt $RawVolumeThreshold) {
            if ($peaks.Left -gt ($peaks.Right * 1.2)) {
                return 1 # Left dominant
            } elseif ($peaks.Right -gt ($peaks.Left * 1.2)) {
                return 2 # Right dominant
            }
        }
        Start-Sleep -Milliseconds 30
    }
}

# --- EXECUTION ENGINE ---
Clear-Host
Write-Host "====================================================" -ForegroundColor Yellow
Write-Host "       SURFACE PRO 11 STEREO HOLO ENGINE            " -ForegroundColor Yellow
Write-Host "====================================================" -ForegroundColor Yellow
Write-Host "Tap the left or right side of your desk/kickstand..." -ForegroundColor Gray

while ($true) {
    $zone = Listen-ForStereoTap
    Trigger-Action $zone
    Start-Sleep -Milliseconds 400
}
