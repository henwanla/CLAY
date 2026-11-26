param(
    [Parameter(Mandatory)][string]$DesktopBuild,
    [Parameter(Mandatory)][string]$PortableExe,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $repo 'VERSION') -Raw).Trim()
$revision = (git -C $repo rev-parse --verify HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^\d+\.\d+\.\d+$' -or $revision -notmatch '^[0-9a-f]{40}$') {
    throw 'A numeric VERSION and a valid Git checkout are required.'
}

$name = "CLAY-$version-windows-x64-$($revision.Substring(0, 7))-preview.zip"
$target = (New-Item -ItemType Directory -Path $OutputDirectory -Force).FullName
$archive = Join-Path $target $name
$stage = Join-Path ([IO.Path]::GetTempPath()) ('clay-win-package-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $stage)

try {
    $files = @(
        'Clay.Windows.exe', 'Clay.Windows.dll', 'Clay.Windows.deps.json', 'Clay.Windows.runtimeconfig.json'
    )
    foreach ($file in $files) {
        Copy-Item -LiteralPath (Join-Path $DesktopBuild $file) -Destination (Join-Path $stage $file)
    }
    Copy-Item -LiteralPath $PortableExe -Destination (Join-Path $stage 'clay-portable.exe')
    Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination (Join-Path $stage 'LICENSE-CLAY.txt')
    Copy-Item -LiteralPath (Join-Path $repo 'Vendor/Yams/LICENSE') -Destination (Join-Path $stage 'LICENSE-Yams.txt')
    Copy-Item -LiteralPath (Join-Path $repo 'Vendor/Yams/LICENSE-libyaml') -Destination (Join-Path $stage 'LICENSE-libyaml.txt')
    $instructions = @"
CLAY $version · Windows x64 preview
Source commit: $revision

Requires the .NET 10 Desktop Runtime and the Swift runtime from the verified Swift toolchain.
Extract the archive and run Clay.Windows.exe. It uses the adjacent clay-portable.exe.
Load a local profile, select a trusted Mihomo executable, and enter its expected SHA-256.
Set the displayed loopback proxy address in the client app. Use the tray to switch or stop.

此预览需要 .NET 10 Desktop Runtime 和经验证的 Swift 工具链所带的 Swift 运行时。
解压后运行 Clay.Windows.exe，选择本地节点、可信的 Mihomo 并填写其 SHA-256。
在需要代理的客户端中手动填写回环地址，可从系统托盘切换或停止代理。

This is an unsigned CI preview. Neither Mihomo nor any profile is bundled.
这是未签名的 CI 预览，不包含 Mihomo 或任何节点配置。
"@
    Set-Content -LiteralPath (Join-Path $stage 'START-HERE.txt') -Value $instructions -Encoding utf8
    $wanted = $files + @('clay-portable.exe', 'LICENSE-CLAY.txt', 'LICENSE-Yams.txt', 'LICENSE-libyaml.txt', 'START-HERE.txt')

    foreach ($exe in @('Clay.Windows.exe', 'clay-portable.exe')) {
        $stream = [IO.File]::OpenRead((Join-Path $stage $exe))
        try {
            $read = [IO.BinaryReader]::new($stream)
            if ($read.ReadUInt16() -ne 0x5A4D) { throw "$exe is not a Windows executable." }
            $stream.Position = 0x3C
            $pe = $read.ReadUInt32()
            if ($pe -gt $stream.Length - 6) { throw "$exe has an invalid PE header." }
            $stream.Position = $pe
            if ($read.ReadUInt32() -ne 0x4550 -or $read.ReadUInt16() -ne 0x8664) { throw "$exe is not Windows x64." }
        } finally { $stream.Dispose() }
    }

    $draft = Join-Path $stage $name
    $inputs = $wanted | ForEach-Object { Join-Path $stage $_ }
    Compress-Archive -LiteralPath $inputs -DestinationPath $draft -CompressionLevel Optimal
    $zip = [IO.Compression.ZipFile]::OpenRead($draft)
    try {
        $actual = @($zip.Entries | ForEach-Object FullName)
        if ($actual.Count -ne $wanted.Count -or @(Compare-Object -ReferenceObject $wanted -DifferenceObject $actual).Count -ne 0) {
            throw 'Windows package content does not match the allowlist.'
        }
    } finally { $zip.Dispose() }
    Move-Item -LiteralPath $draft -Destination $archive -Force
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$archive.sha256" -Value "$hash  $name" -Encoding ascii
    Write-Output $archive
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
