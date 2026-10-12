[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$variants = @(
    @{Language='C'; Mode='O2'; Path='c\bin\hello-c.exe'},
    @{Language='C-no-CRT'; Mode='O2, nostdlib'; Path='c\bin-nostdlib\hello-c-nostdlib.exe'},
    @{Language='C++'; Mode='O2'; Path='cpp\bin\hello-cpp.exe'},
    @{Language='Rust'; Mode='opt-level=2'; Path='rust\bin\hello-rust.exe'},
    @{Language='Go'; Mode='default'; Path='go\bin\hello-go.exe'},
    @{Language='Zig'; Mode='ReleaseSafe'; Path='zig\bin\hello-zig.exe'},
    @{Language='Zig'; Mode='ReleaseSmall'; Path='zig\bin\hello-zig-small.exe'}
)
$rows = foreach ($variant in $variants) {
    $file = Get-Item -LiteralPath (Join-Path $PSScriptRoot $variant.Path)
    [pscustomobject]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        Language = $variant.Language
        Mode = $variant.Mode
        ExecutableBytes = $file.Length
        ExecutableKiB = [math]::Round($file.Length / 1KB, 3)
        Executable = $file.FullName
    }
}
$resultPath = Join-Path $PSScriptRoot ('disk-sizes-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$rows | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding UTF8
$rows | Format-Table Language, Mode, ExecutableBytes, ExecutableKiB -AutoSize
Write-Host "Disk sizes saved to $resultPath"
