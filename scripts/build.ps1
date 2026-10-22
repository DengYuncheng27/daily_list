param(
    [ValidateSet("web","windows","apk","test")]
    [string]$Target = "web",
    [string]$Flutter = "flutter",
    [string]$ApiBaseUrl = ""
)
$ErrorActionPreference = "Stop"
$projectDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\client"))
Push-Location $projectDirectory
try {
    & $Flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed." }
    if ($Target -eq "test") {
        & $Flutter analyze --no-pub
        if ($LASTEXITCODE -ne 0) { throw "Static analysis failed." }
        & $Flutter test --no-pub
    } else {
        $buildArguments = @("build", $Target, "--no-pub")
        if ($Target -eq "apk") { $buildArguments += "--debug" }
        else { $buildArguments += "--release" }
        if ($ApiBaseUrl) { $buildArguments += "--dart-define=API_BASE_URL=$ApiBaseUrl" }
        & $Flutter @buildArguments
    }
    if ($LASTEXITCODE -ne 0) { throw "Flutter command failed." }
} finally {
    Pop-Location
}
