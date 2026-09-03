<#
.SYNOPSIS
    Load KEY=VALUE pairs from the repo-root `.env` into the current
    PowerShell session as environment variables.

.DESCRIPTION
    Every demo-*.ps1, deploy script, and bicepparam file in this repo reads
    from `$env:<VAR>` set by this loader. Keeping the loader dot-sourced
    means there is exactly ONE place tenant IDs / mailbox UPNs / workspace
    GUIDs are ever configured — the root `.env`.

    Comments (`#`) and blank lines are ignored. Values are trimmed. Values
    wrapped in single or double quotes have the quotes stripped.

.EXAMPLE
    . .\scripts\load-env.ps1
    # Now $env:AZURE_TENANT_ID, $env:MAILBOX_UPN, etc. are populated.

.EXAMPLE
    . .\scripts\load-env.ps1 -Path .\deploy\ci.env
#>
[CmdletBinding()]
param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'

if (-not $Path) {
    # Repo root is the parent of the scripts/ folder.
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $Path     = Join-Path $repoRoot '.env'
}

if (-not (Test-Path -LiteralPath $Path)) {
    throw "No .env file at $Path. Copy .env.example to .env and fill in the values."
}

$loaded = 0
foreach ($line in Get-Content -LiteralPath $Path) {
    $trim = $line.Trim()
    if (-not $trim) { continue }
    if ($trim.StartsWith('#')) { continue }
    $eq = $trim.IndexOf('=')
    if ($eq -lt 1) { continue }
    $key = $trim.Substring(0, $eq).Trim()
    $val = $trim.Substring($eq + 1).Trim()
    # Strip a matching pair of surrounding quotes.
    if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
        ($val.StartsWith("'") -and $val.EndsWith("'"))) {
        $val = $val.Substring(1, $val.Length - 2)
    }
    # Strip inline comment after a value (only when preceded by whitespace).
    if ($val -match '^(?<v>[^#]*?)\s+#') { $val = $matches['v'].Trim() }
    Set-Item -Path ("Env:{0}" -f $key) -Value $val
    $loaded++
}

Write-Host ("Loaded {0} variables from {1}" -f $loaded, $Path) -ForegroundColor Green
