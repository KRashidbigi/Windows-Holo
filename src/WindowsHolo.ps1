$SampleRate = 44100
$DurationMs = 40                                # FASTER: Shorter slice to minimize blind spots
$BytesPerSample = 2                              
$BufferSize = [int]($SampleRate * ($DurationMs / 1000) * $BytesPerSample)
$RawVolumeThreshold = 2000                      
$DoubleTapWindowMs = 400                        # SLIGHTLY WIDER: Gives a bit more room for the second hit
                    

# --- LAUNCH ACTIONS ---
function Invoke-MappedAction([string]$gestureType) {
    Write-Host "`n[🚀 LAUNCH] Gesture recognized: $gestureType" -ForegroundColor Cyan
    
    switch ($gestureType) {
        "Teams" {
            Write-Host "Opening Microsoft Teams..." -ForegroundColor Green
            Start-Process "msteams:" -ErrorAction SilentlyContinue
        }
        "VSCode" {
            Write-Host "Opening Visual Studio Code..." -ForegroundColor Green
            $vsCodePath = "$env:LocalAppData\Programs\Microsoft VS Code\Code.exe"
            if (Test-Path $vsCodePath) { 
                Start-Process $vsCodePath 
            } else { 
                Start-Process "code" -ErrorAction SilentlyContinue 
            }
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

function Test-ImpactPeak {
    $managedBuffer = [AudioHelper.WinMMBridge]::RecordAudioChunk($SampleRate, $DurationMs, $BufferSize)
    if ($null -eq $managedBuffer) { return $false }
    
    $samples = New-Object Int16[] ($BufferSize / 2)
    [Buffer]::BlockCopy($managedBuffer, 0, $samples, 0, $BufferSize)
    
    $maxPeak = 0
    foreach ($val in $samples) {
        $abs = [Math]::Abs($val)
        if ($abs -gt $maxPeak) { $maxPeak = $abs }
    }
    return ($maxPeak -gt $RawVolumeThreshold)
}

# --- EXECUTION ENGINE ---
Clear-Host
Write-Host "====================================================" -ForegroundColor Yellow
Write-Host "                    APP LAUNCHER                    " -ForegroundColor Yellow
Write-Host "====================================================" -ForegroundColor Yellow
Write-Host " Gestures:" -ForegroundColor White
Write-Host "   1 Strike  -> Open Microsoft Teams" -ForegroundColor Gray
Write-Host "   2 Strikes -> Open Visual Studio Code" -ForegroundColor Gray
Write-Host "`nListening for impact...`n" -ForegroundColor DarkGray

while ($true) {
    if (Test-ImpactPeak) {
        Write-Host "⚡ First impact registered... " -NoNewline -ForegroundColor Yellow
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $doubleStrike = $false
        
        while ($sw.ElapsedMilliseconds -lt $DoubleTapWindowMs) {
            Start-Sleep -Milliseconds 20
            if (Test-ImpactPeak) {
                $doubleStrike = $true
                break
            }
        }
        
        if ($doubleStrike) {
            Invoke-MappedAction "VSCode"
            Start-Sleep -Milliseconds 600
        } else {
            Invoke-MappedAction "Teams"
            Start-Sleep -Milliseconds 500
        }
    }
    Start-Sleep -Milliseconds 30
}
