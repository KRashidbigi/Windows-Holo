# --- CONFIGURATION ---
$RawVolumeThreshold = 4000      # Adjust higher if you have mic feedback, lower for lighter taps
$DoubleTapWindowMs = 420        # Window duration to catch the second tap

# --- LAUNCH ACTIONS ---
function Invoke-MappedAction([string]$actionType) {
    Write-Host "[🚀 LAUNCH] Triggered: $actionType" -ForegroundColor Cyan
    switch ($actionType) {
        'Teams' {
            Start-Process "msteams:" -ErrorAction SilentlyContinue
        }
        'VSCode' {
            $vsCodePath = "$env:LocalAppData\Programs\Microsoft VS Code\Code.exe"
            if (Test-Path $vsCodePath) { 
                Start-Process $vsCodePath 
            } else { 
                Start-Process "code" -ErrorAction SilentlyContinue 
            }
        }
    }
}

# --- THREAD-SAFE EVENT-DRIVEN AUDIO ENGINE ---
$csharpCode = @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Concurrent;

namespace AudioHelper
{
    public class TapListener : IDisposable
    {
        [DllImport("winmm.dll", SetLastError = true)]
        private static extern int waveInOpen(out IntPtr phwi, uint uDeviceID, ref WAVEFORMATEX pwfx, IntPtr dwCallback, IntPtr dwInstance, uint fdwOpen);
        [DllImport("winmm.dll")] private static extern int waveInPrepareHeader(IntPtr hwi, ref WAVEHDR pwh, uint cbwh);
        [DllImport("winmm.dll")] private static extern int waveInAddBuffer(IntPtr hwi, ref WAVEHDR pwh, uint cbwh);
        [DllImport("winmm.dll")] private static extern int waveInStart(IntPtr hwi);
        [DllImport("winmm.dll")] private static extern int waveInStop(IntPtr hwi);
        [DllImport("winmm.dll")] private static extern int waveInReset(IntPtr hwi);
        [DllImport("winmm.dll")] private static extern int waveInClose(IntPtr hwi);

        [StructLayout(LayoutKind.Sequential)]
        public struct WAVEFORMATEX { public ushort wFormatTag; public ushort nChannels; public uint nSamplesPerSec; public uint nAvgBytesPerSec; public ushort nBlockAlign; public ushort wBitsPerSample; public ushort cbSize; }
        
        [StructLayout(LayoutKind.Sequential)]
        public struct WAVEHDR { public IntPtr lpData; public uint dwBufferLength; public uint dwBytesRecorded; public IntPtr dwUser; public uint dwFlags; public uint dwLoops; public IntPtr lpNext; public IntPtr reserved; }

        private const uint CALLBACK_FUNCTION = 0x00030000;
        private delegate void WaveInProc(IntPtr hwi, uint uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2);

        private IntPtr hWaveIn = IntPtr.Zero;
        private WaveInProc waveCallback;
        private ConcurrentQueue<int> peakQueue = new ConcurrentQueue<int>();
        private GCHandle[] handles = new GCHandle[3];
        private WAVEHDR[] headers = new WAVEHDR[3];
        private bool running = false;

        public void Start()
        {
            if (running) return;
            running = true;

            WAVEFORMATEX wfx = new WAVEFORMATEX();
            wfx.wFormatTag = 1;
            wfx.nChannels = 1;
            wfx.nSamplesPerSec = 44100;
            wfx.wBitsPerSample = 16;
            wfx.nBlockAlign = 2;
            wfx.nAvgBytesPerSec = 88200;
            wfx.cbSize = 0;

            waveCallback = new WaveInProc(DataCallback);
            waveInOpen(out hWaveIn, 0, ref wfx, Marshal.GetFunctionPointerForDelegate(waveCallback), IntPtr.Zero, CALLBACK_FUNCTION);

            uint bufSize = 1764; // ~20ms slices
            for (int i = 0; i < 3; i++)
            {
                byte[] mem = new byte[bufSize];
                handles[i] = GCHandle.Alloc(mem, GCHandleType.Pinned);
                headers[i] = new WAVEHDR { lpData = handles[i].AddrOfPinnedObject(), dwBufferLength = bufSize, dwUser = (IntPtr)i };
                waveInPrepareHeader(hWaveIn, ref headers[i], (uint)Marshal.SizeOf(headers[i]));
                waveInAddBuffer(hWaveIn, ref headers[i], (uint)Marshal.SizeOf(headers[i]));
            }
            waveInStart(hWaveIn);
        }

        private void DataCallback(IntPtr hwi, uint uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2)
        {
            if (uMsg == 0x3BF) // MM_WIM_DATA
            {
                WAVEHDR hdr = (WAVEHDR)Marshal.PtrToStructure(dwParam1, typeof(WAVEHDR));
                int idx = (int)hdr.dwUser;
                short[] samples = new short[hdr.dwBytesRecorded / 2];
                Marshal.Copy(hdr.lpData, samples, 0, samples.Length);

                int max = 0;
                for (int i = 0; i < samples.Length; i++)
                {
                    int v = Math.Abs(samples[i]);
                    if (v > max) max = v;
                }
                peakQueue.Enqueue(max);

                if (running) waveInAddBuffer(hWaveIn, ref headers[idx], (uint)Marshal.SizeOf(headers[idx]));
            }
        }

        public int ReadPeak()
        {
            if (peakQueue.TryDequeue(out int p)) return p;
            return 0;
        }

        public void Stop()
        {
            if (!running) return;
            running = false;
            waveInStop(hWaveIn);
            waveInReset(hWaveIn);
            waveInClose(hWaveIn);
            for (int i = 0; i < 3; i++) if (handles[i].IsAllocated) handles[i].Free();
        }

        public void Dispose() { Stop(); }
    }
}
'@

if (-not ([System.Management.Automation.PSTypeName]'AudioHelper.TapListener').Type) {
    Add-Type -TypeDefinition $csharpCode
}

# --- MAIN RUNTIME ENGINE ---
Clear-Host
Write-Host '====================================================' -ForegroundColor Yellow
Write-Host '       WINDOWS HOLO TAP ENGINE (ACTIVE)             ' -ForegroundColor Yellow
Write-Host '====================================================' -ForegroundColor Yellow
Write-Host ' Gestures:' -ForegroundColor White
Write-Host '   1 Tap  -> Open Microsoft Teams' -ForegroundColor Gray
Write-Host '   2 Taps -> Open Visual Studio Code' -ForegroundColor Gray
Write-Host "`nListening for structural strikes...`n" -ForegroundColor DarkGray

$listener = New-Object AudioHelper.TapListener
$listener.Start()

$state = 'IDLE'
$sw = New-Object System.Diagnostics.Stopwatch

try {
    while ($true) {
        $peak = $listener.ReadPeak()
        
        if ($peak -gt $RawVolumeThreshold) {
            if ($state -eq 'IDLE') {
                Write-Host "⚡ Tap 1 registered ($peak)!" -ForegroundColor Yellow
                $sw.Restart()
                $state = 'WAITING_FOR_SECOND_TAP'
            }
            elseif ($state -eq 'WAITING_FOR_SECOND_TAP' -and $sw.ElapsedMilliseconds -gt 60) {
                Write-Host "⚡ Tap 2 registered ($peak) -> VSCode!" -ForegroundColor Green
                Invoke-MappedAction 'VSCode'
                $state = 'COOLDOWN'
                $sw.Restart()
            }
        }

        # Check timeout for single tap confirmation
        if ($state -eq 'WAITING_FOR_SECOND_TAP' -and $sw.ElapsedMilliseconds -gt $DoubleTapWindowMs) {
            Write-Host 'Single tap confirmed -> Teams!' -ForegroundColor DarkGreen
            Invoke-MappedAction 'Teams'
            $state = 'COOLDOWN'
            $sw.Restart()
        }

        # Reset state after short cooldown
        if ($state -eq 'COOLDOWN' -and $sw.ElapsedMilliseconds -gt 700) {
            while ($listener.ReadPeak() -ne 0) {} # Clear residual vibration buffer
            $state = 'IDLE'
            Write-Host 'Listening...' -ForegroundColor DarkGray
        }

        Start-Sleep -Milliseconds 5
    }
}
finally {
    $listener.Stop()
    $listener.Dispose()
}
