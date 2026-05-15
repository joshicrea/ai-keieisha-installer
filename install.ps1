# AI Keieisha installer for Windows
#
# Usage: paste this into Claude Code or PowerShell:
#   iwr -useb https://raw.githubusercontent.com/joshicrea/ai-keieisha-installer/master/install.ps1 | iex
#
# What it does:
#   1. Install GitHub CLI gh via winget if missing
#   2. Run gh auth login --web if not authenticated
#   3. Download AI Keieisha private repo via gh auth token
#   4. Extract to Claude plugin cache
#   5. Update installed_plugins.json and settings.json
#   6. Replace placeholders in plugin files
#   7. Create user data directory
#
# Auth model: seller adds buyer email as collaborator on private repo.
# Buyer just authorizes via gh auth login --web. No PAT needed.

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

Write-Host ""
Write-Host "AI経営者プラグインをインストールしています..." -ForegroundColor Cyan
Write-Host ""

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Update-EnvPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# --- GitHub CLI gh check / install ---
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "GitHub CLI (gh) をインストールしています..." -ForegroundColor Yellow
    winget install --id GitHub.cli --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
    Update-EnvPath
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host "エラー: GitHub CLI のインストールに失敗しました。" -ForegroundColor Red
        Write-Host "https://cli.github.com/ から手動でインストールしてください。"
        exit 1
    }
    Write-Host "[OK] GitHub CLI インストール完了" -ForegroundColor Green
}

# --- GitHub 認証確認 ---
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "GitHubへのログインが必要です。" -ForegroundColor Yellow
    Write-Host "次の手順で進めてください:"
    Write-Host "  1. このあと表示される8桁のコードをコピー"
    Write-Host "  2. 自動で開くブラウザでコードを貼り付け"
    Write-Host "  3. 「Authorize github」をクリック"
    Write-Host ""
    gh auth login --web --git-protocol https --hostname github.com
    if ($LASTEXITCODE -ne 0) {
        Write-Host "エラー: GitHub認証に失敗しました。" -ForegroundColor Red
        exit 1
    }
}

# --- トークンを取得（gh が保持しているもの・PATではない） ---
$Pat = (gh auth token).Trim()
if (-not $Pat) {
    Write-Host "エラー: gh auth token の取得に失敗しました。" -ForegroundColor Red
    exit 1
}

# --- OS判定・パス設定 ---
if ($IsWindows -or ($PSVersionTable.PSVersion.Major -lt 6)) {
    $HomeDir = $env:USERPROFILE
} else {
    $HomeDir = $env:HOME
}

$PluginName  = "joshicrea-ai-keieisha"
$DataDirName = "ai-keieisha"

$TempDir    = [IO.Path]::GetTempPath()
$ClaudeDir  = [IO.Path]::Combine($HomeDir, ".claude")
$PluginsDir = [IO.Path]::Combine($ClaudeDir, "plugins")
$CacheDir   = [IO.Path]::Combine($PluginsDir, "cache", "joshicrea", $PluginName)
$DataDir    = [IO.Path]::Combine($ClaudeDir, $DataDirName)
$LogDir     = [IO.Path]::Combine($ClaudeDir, "logs")
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
New-Item -ItemType Directory -Force -Path $DataDir  | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir   | Out-Null

# ============================================================
# Section 1: 本体プラグインをダウンロード・展開
# ============================================================
Write-Host "[1/4] プラグイン本体をダウンロード..." -ForegroundColor Cyan

$Headers = @{
    "Authorization" = "token $Pat"
    "User-Agent"    = "joshicrea-ai-keieisha-installer"
    "Accept"        = "application/vnd.github.v3+json"
}

try {
    $CommitInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/joshicrea/ai-keieisha/commits/master" -Headers $Headers -UseBasicParsing
    $FullSha    = $CommitInfo.sha
    $ShortSha   = $FullSha.Substring(0, 12)
} catch {
    Write-Host "GitHubへの接続に失敗しました: $_" -ForegroundColor Red
    Write-Host "GitHubアカウントが joshicrea/ai-keieisha のコラボレーターに招待されているか確認してください。"
    Write-Host "招待メールが届いている場合は GitHub上で承認してから再実行してください。"
    exit 1
}

$InstallPath = [IO.Path]::Combine($CacheDir, $ShortSha)

if (Test-Path $InstallPath) {
    Write-Host "  すでに最新版がダウンロード済み ($ShortSha)" -ForegroundColor Green
} else {
    $ZipUrl  = "https://api.github.com/repos/joshicrea/ai-keieisha/zipball/master"
    $ZipPath = [IO.Path]::Combine($TempDir, "ai-keieisha.zip")
    $ExtTemp = [IO.Path]::Combine($TempDir, "ai-keieisha-extract-$ShortSha")

    try {
        Invoke-WebRequest -Uri $ZipUrl -Headers $Headers -OutFile $ZipPath -UseBasicParsing
    } catch {
        Write-Host "ダウンロードに失敗しました: $_" -ForegroundColor Red
        exit 1
    }

    if (Test-Path $ExtTemp) { Remove-Item $ExtTemp -Recurse -Force }
    Expand-Archive -Path $ZipPath -DestinationPath $ExtTemp -Force
    $ExtractedFolder = Get-ChildItem $ExtTemp -Directory | Select-Object -First 1
    Move-Item $ExtractedFolder.FullName $InstallPath -Force
    Remove-Item $ExtTemp -Force -ErrorAction SilentlyContinue
    Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
    Write-Host "  ダウンロード完了 ($ShortSha)" -ForegroundColor Green
}

# ============================================================
# Section 2: Claude Code にプラグイン登録
# ============================================================
Write-Host ""
Write-Host "[2/4] Claude Code にプラグイン登録..." -ForegroundColor Cyan

$InstalledPath = [IO.Path]::Combine($PluginsDir, "installed_plugins.json")
if (Test-Path $InstalledPath) {
    $Installed = [System.IO.File]::ReadAllText($InstalledPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
} else {
    New-Item -ItemType Directory -Force -Path $PluginsDir | Out-Null
    $Installed = [PSCustomObject]@{ version = 2; plugins = [PSCustomObject]@{} }
}

$PluginEntry = [PSCustomObject]@{
    scope        = "user"
    installPath  = $InstallPath
    version      = $ShortSha
    installedAt  = (Get-Date -Format "o")
    lastUpdated  = (Get-Date -Format "o")
    gitCommitSha = $FullSha
}
$Key = "$PluginName@joshicrea"
if ($Installed.plugins.PSObject.Properties[$Key]) {
    $Installed.plugins.PSObject.Properties[$Key].Value = @($PluginEntry)
} else {
    $Installed.plugins | Add-Member -Name $Key -Value @($PluginEntry) -MemberType NoteProperty
}
Write-Utf8NoBom -Path $InstalledPath -Content ($Installed | ConvertTo-Json -Depth 10)

$SettingsPath = [IO.Path]::Combine($ClaudeDir, "settings.json")
if (Test-Path $SettingsPath) {
    $Settings = [System.IO.File]::ReadAllText($SettingsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
} else {
    $Settings = [PSCustomObject]@{}
}
if (-not ($Settings.PSObject.Properties["enabledPlugins"])) {
    $Settings | Add-Member -Name "enabledPlugins" -Value ([PSCustomObject]@{}) -MemberType NoteProperty
}
if ($Settings.enabledPlugins.PSObject.Properties[$Key]) {
    $Settings.enabledPlugins.PSObject.Properties[$Key].Value = $true
} else {
    $Settings.enabledPlugins | Add-Member -Name $Key -Value $true -MemberType NoteProperty
}
Write-Utf8NoBom -Path $SettingsPath -Content ($Settings | ConvertTo-Json -Depth 10)
Write-Host "  プラグイン登録完了" -ForegroundColor Green

# ============================================================
# Section 3: プレースホルダー置換
# ============================================================
Write-Host ""
Write-Host "[3/4] プラグイン内のプレースホルダーを実パスに置換..." -ForegroundColor Cyan

$replacePairs = @(
    @{ Token = "{{KEIEISHA_PLUGIN_ROOT}}"; Value = $InstallPath },
    @{ Token = "{{KEIEISHA_BASE_DIR}}";   Value = $DataDir }
)
$targetFiles = Get-ChildItem -Path $InstallPath -Recurse -File -Include "*.md","*.json","*.txt" -ErrorAction SilentlyContinue
foreach ($f in $targetFiles) {
    $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    $changed = $false
    foreach ($pair in $replacePairs) {
        if ($content.Contains($pair.Token)) {
            $content = $content.Replace($pair.Token, $pair.Value)
            $changed = $true
        }
    }
    if ($changed) {
        Write-Utf8NoBom -Path $f.FullName -Content $content
    }
}
Write-Host "  プレースホルダー置換完了" -ForegroundColor Green

# ============================================================
# Section 4: ユーザーデータディレクトリ準備
# ============================================================
Write-Host ""
Write-Host "[4/4] ユーザーデータ領域を準備..." -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path ([IO.Path]::Combine($DataDir, "ナレッジ")) | Out-Null

$statusPath = [IO.Path]::Combine($DataDir, ".setup-status")
if (-not (Test-Path $statusPath)) {
    Write-Utf8NoBom -Path $statusPath -Content "in_progress"
}

$profilePath = [IO.Path]::Combine($DataDir, "user-profile.md")
if (-not (Test-Path $profilePath)) {
    $template = @"
# AI経営者 ユーザープロフィール

<!-- セッション開始時に Claude が自動で記入します -->

name:
business:
setup_date:
"@
    Write-Utf8NoBom -Path $profilePath -Content $template
}
Write-Host "  ユーザーデータ準備完了" -ForegroundColor Green

# ============================================================
# 検証
# ============================================================
$verifyOk = $true
$claudeMd = [IO.Path]::Combine($InstallPath, "CLAUDE.md")
if (-not (Test-Path $claudeMd)) {
    Write-Host "エラー: CLAUDE.md が見つかりません: $claudeMd" -ForegroundColor Red
    $verifyOk = $false
} else {
    $cmContent = [System.IO.File]::ReadAllText($claudeMd, [System.Text.Encoding]::UTF8)
    if ($cmContent.Contains("{{KEIEISHA_PLUGIN_ROOT}}") -or $cmContent.Contains("{{KEIEISHA_BASE_DIR}}")) {
        Write-Host "エラー: CLAUDE.md のプレースホルダー置換が不完全です" -ForegroundColor Red
        $verifyOk = $false
    }
}
if (-not $verifyOk) {
    Write-Host ""
    Write-Host "インストールに問題が発生しました。もう一度試してください。" -ForegroundColor Red
    exit 1
}

# ============================================================
# 完了
# ============================================================
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "インストール完了！" -ForegroundColor Green
Write-Host ""
Write-Host "次の手順:"
Write-Host "  1. Claude Code を完全に閉じる"
Write-Host "  2. Claude Code を再度開く"
Write-Host "  3. チャットに「はじめまして」と送るとセットアップが始まります"
Write-Host "     （AI秘書セットアップ済みなら呼び名・事業内容が自動引き継ぎされます）"
Write-Host ""
