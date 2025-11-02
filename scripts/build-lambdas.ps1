#!/usr/bin/env pwsh
<#
.SYNOPSIS
Build and package Lambda functions for AWS deployment

.DESCRIPTION
This script compiles the Go Lambda functions and packages them as ZIP files
ready for deployment to AWS Lambda.
#>

param()

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$BuildDir = Join-Path $ProjectRoot "build\lambdas"
$LambdasDir = Join-Path $ProjectRoot "cmd\lambdas"

Write-Host "Building Lambda functions..." -ForegroundColor Yellow

# Create build directory
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

# List of Lambda functions to build
$Functions = @("wake", "sleep", "kill")

foreach ($func in $Functions) {
    Write-Host "`n=== Building $func Lambda ===" -ForegroundColor Green
    
    $FuncDir = Join-Path $LambdasDir $func
    $OutputDir = Join-Path $BuildDir $func
    
    if (-not (Test-Path $FuncDir)) {
        Write-Host "[ERROR] Lambda function directory not found: $FuncDir" -ForegroundColor Red
        exit 1
    }
    
    # Create output directory
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    
    # Build for Linux (Lambda runtime)
    Write-Host "Compiling Go binary for Linux..." -ForegroundColor Yellow
    Push-Location $FuncDir
    $env:GOOS = "linux"
    $env:GOARCH = "amd64"
    $env:CGO_ENABLED = "0"
    go build -ldflags="-s -w" -o (Join-Path $OutputDir "bootstrap") .
    Pop-Location
    
    $BootstrapPath = Join-Path $OutputDir "bootstrap"
    if (-not (Test-Path $BootstrapPath)) {
        Write-Host "[ERROR] Failed to build $func Lambda" -ForegroundColor Red
        exit 1
    }
    
    # Package as ZIP
    Write-Host "Packaging as ZIP..." -ForegroundColor Yellow
    $ZipPath = Join-Path $BuildDir "$func.zip"
    if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
    
    Compress-Archive -Path $BootstrapPath -DestinationPath $ZipPath -CompressionLevel Optimal
    Remove-Item $BootstrapPath -Force
    Remove-Item $OutputDir -Force -Recurse
    
    # Show size
    $Size = (Get-Item $ZipPath).Length / 1MB
    Write-Host "[OK] Created $func.zip ($([math]::Round($Size, 2)) MB)" -ForegroundColor Green
}

Write-Host "`n=== Build Summary ===" -ForegroundColor Green
Get-ChildItem "$BuildDir\*.zip" | Format-Table Name, @{Label="Size (MB)"; Expression={[math]::Round($_.Length / 1MB, 2)}}

Write-Host "[OK] All Lambda functions built successfully" -ForegroundColor Green
Write-Host "Output directory: $BuildDir" -ForegroundColor Gray
