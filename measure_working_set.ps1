<#
Launch each already-built triangle, wait, capture memory counters, and close it.
Examples:
  .\measure_working_set.ps1
  .\measure_working_set.ps1 -Api DX12
  .\measure_working_set.ps1 -Api All -Repetitions 3 -DelaySeconds 2

WorkingSetBytes includes shared and private resident pages.
PrivateWorkingSetBytes measures private resident RAM (Task Manager's per-process memory metric).
PrivateBytes measures private committed memory, not private resident memory.
These process counters do not measure GPU VRAM.
Requires Windows 10/11 22H2 with the September 2023 update or later.
#>
[CmdletBinding()]
param(
    [ValidateSet('OpenGL', 'DX11', 'DX12', 'Vulkan', 'All')]
    [string]$Api = 'All',
    [ValidateRange(0.1, 300)]
    [double]$DelaySeconds = 2,
    [ValidateRange(1, 100)]
    [int]$Repetitions = 1,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Read all memory counters in one native snapshot, avoiding performance-counter
# refresh delays. Compile the helper before launching any measured process.
# https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex2
if (-not ('TinyMemoryCounters' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct TinyProcessMemoryCountersEx2 {
    public uint cb;
    public uint PageFaultCount;
    public UIntPtr PeakWorkingSetSize;
    public UIntPtr WorkingSetSize;
    public UIntPtr QuotaPeakPagedPoolUsage;
    public UIntPtr QuotaPagedPoolUsage;
    public UIntPtr QuotaPeakNonPagedPoolUsage;
    public UIntPtr QuotaNonPagedPoolUsage;
    public UIntPtr PagefileUsage;
    public UIntPtr PeakPagefileUsage;
    public UIntPtr PrivateUsage;
    public UIntPtr PrivateWorkingSetSize;
    public ulong SharedCommitUsage;
}

public static class TinyMemoryCounters {
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool K32GetProcessMemoryInfo(
        IntPtr process, ref TinyProcessMemoryCountersEx2 counters, uint size);

    public static TinyProcessMemoryCountersEx2 Read(IntPtr process) {
        var counters = new TinyProcessMemoryCountersEx2();
        counters.cb = (uint)Marshal.SizeOf(typeof(TinyProcessMemoryCountersEx2));
        if (!K32GetProcessMemoryInfo(process, ref counters, counters.cb))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return counters;
    }
}
'@
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot ('working-set-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

$samples = @(
    [pscustomobject]@{ Api = 'OpenGL'; Language = 'C++'; Path = 'hello_opengl.exe' },
    [pscustomobject]@{ Api = 'OpenGL'; Language = 'Rust'; Path = 'rust-opengl\target\release\hello-opengl-rust.exe' },
    [pscustomobject]@{ Api = 'OpenGL'; Language = 'Zig'; Path = 'hello-opengl\zig-out\bin\hello-opengl-zig.exe' },
    [pscustomobject]@{ Api = 'DX12'; Language = 'C++'; Path = 'hello_dx12.exe' },
    [pscustomobject]@{ Api = 'DX12'; Language = 'Rust'; Path = 'rust-dx12\target\release\hello-dx12-rust.exe' },
    [pscustomobject]@{ Api = 'DX12'; Language = 'Zig'; Path = 'hello-dx12\zig-out\bin\hello-dx12.exe' },
    [pscustomobject]@{ Api = 'DX11'; Language = 'C++'; Path = 'hello_dx11.exe' },
    [pscustomobject]@{ Api = 'DX11'; Language = 'Rust'; Path = 'rust-dx11\target\release\hello-dx11-rust.exe' },
    [pscustomobject]@{ Api = 'DX11'; Language = 'Zig'; Path = 'hello-dx11\zig-out\bin\hello-dx11-zig.exe' },
    [pscustomobject]@{ Api = 'Vulkan'; Language = 'C++'; Path = 'hello_vulkan.exe' },
    [pscustomobject]@{ Api = 'Vulkan'; Language = 'Rust'; Path = 'rust-vulkan\target\release\hello-vulkan-rust.exe' },
    [pscustomobject]@{ Api = 'Vulkan'; Language = 'Zig'; Path = 'hello-vulkan\zig-out\bin\hello-vulkan-zig.exe' }
) | Where-Object { $Api -eq 'All' -or $_.Api -eq $Api }

# Check all paths before starting the first measurement.
foreach ($sample in $samples) {
    $exePath = Join-Path $PSScriptRoot $sample.Path
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "Missing executable: $exePath. Run the corresponding build batch file first."
    }
}
if (-not (Test-Path -LiteralPath (Split-Path -Parent $OutputPath) -PathType Container)) {
    throw "Output directory does not exist: $(Split-Path -Parent $OutputPath)"
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "Output file already exists: $OutputPath. Choose a new filename."
}

$rows = [System.Collections.Generic.List[object]]::new()
for ($runNumber = 1; $runNumber -le $Repetitions; $runNumber++) {
    foreach ($sample in $samples) {
        $exePath = Join-Path $PSScriptRoot $sample.Path
        $triangleProcess = $null
        Write-Host "Launching $($sample.Api) $($sample.Language), run $runNumber..."
        try {
            # Launch the EXE directly: compiler, cargo, zig, and shell memory are excluded.
            $triangleProcess = Start-Process -FilePath $exePath -WorkingDirectory $PSScriptRoot -PassThru
            Start-Sleep -Milliseconds ([int]($DelaySeconds * 1000))
            $triangleProcess.Refresh()
            if ($triangleProcess.HasExited) {
                throw "Sample exited before measurement (exit code $($triangleProcess.ExitCode))."
            }

            $memory = [TinyMemoryCounters]::Read($triangleProcess.Handle)
            $workingSet = $memory.WorkingSetSize.ToUInt64()
            $privateBytes = $memory.PrivateUsage.ToUInt64()
            $privateWorkingSet = $memory.PrivateWorkingSetSize.ToUInt64()
            $row = [pscustomobject]@{
                TimestampUtc = [DateTime]::UtcNow.ToString('o')
                Api = $sample.Api
                Language = $sample.Language
                Run = $runNumber
                ProcessId = $triangleProcess.Id
                RequestedDelaySeconds = $DelaySeconds
                ProcessAgeSeconds = [math]::Round(([DateTime]::Now - $triangleProcess.StartTime).TotalSeconds, 3)
                WorkingSetBytes = $workingSet
                WorkingSetMiB = [math]::Round($workingSet / 1MB, 3)
                PrivateWorkingSetBytes = $privateWorkingSet
                PrivateWorkingSetMiB = [math]::Round($privateWorkingSet / 1MB, 3)
                PrivateBytes = $privateBytes
                PrivateMiB = [math]::Round($privateBytes / 1MB, 3)
                PeakWorkingSetBytes = $memory.PeakWorkingSetSize.ToUInt64()
                ExecutableBytes = (Get-Item -LiteralPath $exePath).Length
                Executable = $exePath
            }
            # Save each result immediately so completed measurements survive later failures.
            if ($rows.Count -eq 0) {
                $row | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
            } else {
                $row | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8 -Append
            }
            $rows.Add($row)
        } finally {
            # Only close the process created for this measurement.
            if ($null -ne $triangleProcess) {
                try {
                    $triangleProcess.Refresh()
                    if (-not $triangleProcess.HasExited) {
                        $null = $triangleProcess.CloseMainWindow()
                        if (-not $triangleProcess.WaitForExit(3000)) {
                            $triangleProcess.Kill()
                            $triangleProcess.WaitForExit()
                        }
                    }
                } finally {
                    $triangleProcess.Dispose()
                }
            }
        }
    }
}

$rows | Format-Table Api, Language, Run, WorkingSetMiB, PrivateWorkingSetMiB, PrivateMiB, ProcessAgeSeconds -AutoSize
Write-Host "Results saved to $OutputPath"
