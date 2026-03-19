param(
  [ValidateSet('auto', 'wsl', 'native')]
  [string]$Mode = 'auto',
  [switch]$NoInput,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$script:Changed = $false
$script:SessionApiKey = $null
$script:Result = 'already ready'

$script:NodeStatus = 'missing'
$script:NpmStatus = 'missing'
$script:CodexStatus = 'missing'
$script:AuthStatus = 'missing'

$MirrorNpm = 'https://registry.npmmirror.com'
$OfficialNpm = 'https://registry.npmjs.org'
$NodeMirrorIndex = 'https://npmmirror.com/mirrors/node/index.json'
$NodeOfficialIndex = 'https://nodejs.org/dist/index.json'

function Write-Log {
  param([string]$Message)
  Write-Host "[codex-init] $Message"
}

function Write-WarnLog {
  param([string]$Message)
  Write-Warning $Message
}

function Test-CommandExists {
  param([string]$Name)
  return [bool](Get-ToolCommand $Name)
}

function Get-ToolCommand {
  param([string]$Name)

  foreach ($candidate in @("$Name.cmd", "$Name.exe", $Name)) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($command) {
      return $command.Source
    }
  }

  return $null
}

function Test-AuthPresent {
  return -not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)
}

function Set-Statuses {
  $script:NodeStatus = if (Test-CommandExists 'node') { 'installed' } else { 'missing' }
  $script:NpmStatus = if (Test-CommandExists 'npm') { 'installed' } else { 'missing' }
  $script:CodexStatus = if (Test-CommandExists 'codex') { 'installed' } else { 'missing' }

  if ((Test-AuthPresent) -or $script:SessionApiKey) {
    $script:AuthStatus = 'installed'
  } elseif ($NoInput) {
    $script:AuthStatus = 'skipped'
  } else {
    $script:AuthStatus = 'missing'
  }
}

function Convert-ToWslPath {
  param([string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if ($fullPath -match '^([A-Za-z]):\\(.*)$') {
    $drive = $Matches[1].ToLowerInvariant()
    $rest = $Matches[2] -replace '\\', '/'
    return "/mnt/$drive/$rest"
  }

  throw "无法转换为 WSL 路径: $Path"
}

function Invoke-WslBootstrap {
  $bootstrapPath = Join-Path $PSScriptRoot 'bootstrap.sh'
  if (-not (Test-Path $bootstrapPath)) {
    throw '缺少 bootstrap.sh，无法进入 WSL 分支。'
  }

  $wslScriptPath = Convert-ToWslPath $bootstrapPath
  $wslRepoPath = Convert-ToWslPath $PSScriptRoot
  $argList = @()
  if ($NoInput) { $argList += '--no-input' }
  if ($Force) { $argList += '--force' }
  $joinedArgs = ($argList -join ' ')
  $command = "cd '$wslRepoPath' && chmod +x '$wslScriptPath' && '$wslScriptPath' $joinedArgs"

  & wsl.exe bash -lc $command
  return $LASTEXITCODE
}

function Test-WslAvailable {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    return $false
  }

  try {
    $null = & wsl.exe -l -q 2>$null
    return $LASTEXITCODE -eq 0
  } catch {
    return $false
  }
}

function Get-NodeArchiveInfo {
  param(
    [string]$IndexUrl,
    [string]$BaseUrl
  )

  $index = Invoke-RestMethod -Uri $IndexUrl -TimeoutSec 30
  $entry = $index |
    Where-Object { $_.lts -and $_.files -contains 'win-x64-zip' } |
    Sort-Object { [version]($_.version.TrimStart('v')) } -Descending |
    Select-Object -First 1

  if (-not $entry) {
    throw "无法从 $IndexUrl 获取 Node.js 版本。"
  }

  [pscustomobject]@{
    Version = $entry.version
    Url = "$BaseUrl/$($entry.version)/node-$($entry.version)-win-x64.zip"
  }
}

function Add-SessionPath {
  $paths = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'),
    (Join-Path $env:APPDATA 'npm')
  )

  foreach ($item in $paths) {
    if ((Test-Path $item) -and ($env:Path -notlike "*$item*")) {
      $env:Path = "$item;$env:Path"
    }
  }
}

function Install-NodeNative {
  Write-Log '安装 Node.js/npm。'
  $targetDir = Join-Path $env:LOCALAPPDATA 'Programs\nodejs'
  $zipPath = Join-Path $env:TEMP 'node-win-x64.zip'
  $extractDir = Join-Path $env:TEMP 'codex-node-extract'

  $archive = $null
  try {
    $archive = Get-NodeArchiveInfo -IndexUrl $NodeMirrorIndex -BaseUrl 'https://npmmirror.com/mirrors/node'
  } catch {
    Write-WarnLog 'Node 国内镜像失败，回退官方源。'
    $archive = Get-NodeArchiveInfo -IndexUrl $NodeOfficialIndex -BaseUrl 'https://nodejs.org/dist'
  }

  if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
  }
  if (Test-Path $extractDir) {
    Remove-Item $extractDir -Recurse -Force
  }

  Invoke-WebRequest -Uri $archive.Url -OutFile $zipPath
  Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

  $expanded = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
  if (-not $expanded) {
    throw 'Node.js 压缩包解压失败。'
  }

  if (Test-Path $targetDir) {
    Remove-Item $targetDir -Recurse -Force
  }

  Move-Item -Path $expanded.FullName -Destination $targetDir
  Add-SessionPath
  $script:Changed = $true
}

function Install-Codex {
  Write-Log '安装 Codex CLI。'
  $npm = Get-ToolCommand 'npm'
  if (-not $npm) {
    throw 'npm 不可用。'
  }

  & $npm install -g @openai/codex --registry $MirrorNpm | Out-Host
  if ($LASTEXITCODE -ne 0) {
    Write-WarnLog 'npm 国内镜像失败，回退官方源。'
    & $npm install -g @openai/codex --registry $OfficialNpm | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw 'Codex CLI 安装失败。'
    }
  }
  $script:Changed = $true
}

function Prompt-Auth {
  if ((Test-AuthPresent) -and (-not $Force)) {
    return
  }

  if ($NoInput) {
    return
  }

  $secure = Read-Host '请输入 OPENAI_API_KEY' -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }

  if ([string]::IsNullOrWhiteSpace($plain)) {
    Write-WarnLog '未输入 API Key，跳过认证。'
    return
  }

  $script:SessionApiKey = $plain
  $env:OPENAI_API_KEY = $plain
  if (Test-CommandExists 'codex') {
    $codex = Get-ToolCommand 'codex'
    if ($codex) {
      try {
        & $codex --version | Out-Null
      } catch {
      }
    }
  }
  $script:Changed = $true
}

function Show-AuthHint {
  if ($script:SessionApiKey) {
    Write-Log '如需持久化，请手动写入 PowerShell Profile:'
    Write-Host ('$env:OPENAI_API_KEY="{0}"' -f $script:SessionApiKey)
    Write-Host 'if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }'
    Write-Host 'notepad $PROFILE'
    return
  }

  if (Test-AuthPresent) {
    Write-Log '检测到当前会话已存在 OPENAI_API_KEY。'
  } else {
    Write-WarnLog '未检测到 OPENAI_API_KEY。你也可以用其他登录方式，但脚本未自动写入认证配置。'
  }
}

function Show-Summary {
  Set-Statuses

  if ($script:Changed) {
    $script:Result = 'initialized'
  }

  Write-Host ''
  Write-Host "node: $($script:NodeStatus)"
  Write-Host "npm: $($script:NpmStatus)"
  Write-Host "codex: $($script:CodexStatus)"
  Write-Host "auth: $($script:AuthStatus)"
  Write-Host "result: $($script:Result)"

  if (Test-CommandExists 'node') {
    $node = Get-ToolCommand 'node'
    Write-Host "node -v: $(& $node -v)"
  }
  if (Test-CommandExists 'npm') {
    $npm = Get-ToolCommand 'npm'
    Write-Host "npm -v: $(& $npm -v)"
  }
  if (Test-CommandExists 'codex') {
    $codex = Get-ToolCommand 'codex'
    Write-Host "codex --version: $(& $codex --version)"
  }
}

function Invoke-NativeBootstrap {
  Add-SessionPath

  if ($Force -or -not (Test-CommandExists 'node') -or -not (Test-CommandExists 'npm')) {
    Install-NodeNative
  }

  if (-not (Test-CommandExists 'node') -or -not (Test-CommandExists 'npm')) {
    throw 'Node.js/npm 安装失败。'
  }

  if ($Force -or -not (Test-CommandExists 'codex')) {
    Install-Codex
  }

  if (-not (Test-CommandExists 'codex')) {
    throw 'Codex CLI 安装失败。'
  }

  Prompt-Auth
  Show-Summary
  Show-AuthHint
}

if ($Mode -eq 'wsl') {
  if (-not (Test-WslAvailable)) {
    throw 'WSL 不可用。'
  }

  $code = Invoke-WslBootstrap
  exit $code
}

if ($Mode -eq 'auto' -and (Test-WslAvailable)) {
  Write-Log '检测到 WSL，优先走 WSL 分支。'
  $code = Invoke-WslBootstrap
  if ($code -eq 0) {
    exit 0
  }

  Write-WarnLog 'WSL 分支失败，回退原生 PowerShell。'
}

Invoke-NativeBootstrap
