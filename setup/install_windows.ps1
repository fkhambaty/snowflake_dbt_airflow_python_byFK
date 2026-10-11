$ErrorActionPreference = "Stop"

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error @"
winget was not found. Install or update 'App Installer' from Microsoft Store,
then reopen PowerShell as Administrator and run this script again.
"@
}

$packages = @(
    @{ Id = "Git.Git"; Name = "Git" },
    @{ Id = "Python.Python.3.12"; Name = "Python 3.12" },
    @{ Id = "Docker.DockerDesktop"; Name = "Docker Desktop" },
    @{ Id = "dbeaver.dbeaver"; Name = "DBeaver Community" },
    @{ Id = "Anysphere.Cursor"; Name = "Cursor" },
    @{ Id = "Hashicorp.Terraform"; Name = "Terraform" }
)

foreach ($package in $packages) {
    winget list --id $package.Id --exact --accept-source-agreements | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Already installed: $($package.Name)" -ForegroundColor DarkGreen
        continue
    }

    Write-Host "Installing $($package.Name)..." -ForegroundColor Cyan
    winget install `
        --id $package.Id `
        --exact `
        --accept-package-agreements `
        --accept-source-agreements `
        --silent

    if ($LASTEXITCODE -ne 0) {
        throw "winget could not install $($package.Name) ($($package.Id))."
    }
}

Write-Host ""
Write-Host "Local tools are installed." -ForegroundColor Green
Write-Host @"

Next:
1. Restart Windows if Docker Desktop asks you to.
2. Open Docker Desktop and enable its WSL 2 engine.
3. Wait until Docker says the engine is running.
4. Open a new PowerShell window in the repository and run:

   py -3.12 setup\verify_setup.py
   py -3.12 setup\start_postgres.py

Next, continue at setup\WINDOWS_SETUP.md.
Astro CLI is installed in the Airflow episode, when it is first needed.
Snowflake is a browser account and is created in the Snowflake episode.
"@
