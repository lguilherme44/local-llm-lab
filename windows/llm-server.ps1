<#
.SYNOPSIS
  llm-server — LLM local servido em HTTP (API compatível com OpenAI) no Windows,
  via llama.cpp com CUDA.

.DESCRIPTION
  Equivalente Windows do llm-server.command (macOS/MLX). O runtime é diferente
  porque MLX é exclusivo de Apple Silicon: aqui usamos llama.cpp, que fala CUDA
  nativamente e expõe a mesma API OpenAI na porta 8080.

  Hardware alvo: RTX 3060 Ti (8 GB VRAM), 16 GB RAM, SSD 1 TB.

  O limite real aqui é a VRAM, não a RAM. Os 8 GB da 3060 Ti definem tudo:
  o modelo mais o cache KV precisam caber, senão camadas vazam para a CPU e a
  velocidade cai por um fator grande. Os perfis abaixo já respeitam esse teto.

.PARAMETER Command
  setup    baixa e instala o llama.cpp com CUDA em %LOCALAPPDATA%\llm-server
  start    sobe o servidor (padrão: agent)
  stop     derruba e libera a VRAM
  restart  troca de modelo
  status   estado, VRAM em uso, modelo carregado
  logs     acompanha o log ao vivo
  ask      manda uma pergunta e imprime a resposta com tok/s
  models   lista os perfis e o que já foi baixado
  pull     só baixa os pesos
  bench    mede tokens/s reais nesta máquina
  vram     mostra o orçamento de VRAM por perfil

.EXAMPLE
  .\llm-server.ps1 setup
  .\llm-server.ps1 start agent
  .\llm-server.ps1 ask "Escreva um debounce genérico em TypeScript"

.NOTES
  Requer: driver NVIDIA recente (nvidia-smi funcionando) e PowerShell 5.1+.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'start', 'stop', 'restart', 'status', 'logs', 'ask',
                 'models', 'pull', 'bench', 'vram', 'help')]
    [string]$Command = 'start',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── ajustes ──────────────────────────────────────────────────────────────────
$Port           = if ($env:LLM_PORT) { [int]$env:LLM_PORT } else { 8080 }
# Padrão só local. LLM_HOST='0.0.0.0' serve o modelo para a rede — útil para
# atender outra máquina (ex.: um Mac sem RAM sobrando), mas leia o aviso:
# `--api-key local` sobre HTTP puro não protege nada de quem está na mesma LAN.
# Nesse caso, restrinja também o firewall à sua faixa de IP.
$BindHost       = if ($env:LLM_HOST) { $env:LLM_HOST } else { '127.0.0.1' }
# Endereço que ESTE script usa para falar com o servidor (health check, ask).
# Com bind em 0.0.0.0, pedir http://0.0.0.0:8080 é frágil — sonde 127.0.0.1.
$ProbeHost      = if ($BindHost -in @('0.0.0.0', '::', '*')) { '127.0.0.1' } else { $BindHost }
$DefaultProfile = 'agent'

$Root    = Join-Path $env:LOCALAPPDATA 'llm-server'
$BinDir  = Join-Path $Root 'llama.cpp'
$LogFile = Join-Path $Root 'server.log'
$PidFile = Join-Path $Root 'server.pid'
$ProfFile= Join-Path $Root 'current-profile'
$ModelDir= Join-Path $Root 'models'

# Variante do CUDA. 12.4 cobre drivers mais antigos; 13.3 exige driver recente.
$CudaVariant = if ($env:LLM_CUDA) { $env:LLM_CUDA } else { '12.4' }

# Chave local. Não é segredo — serve para o servidor recusar chamadas sem header
# e para os clientes (pi, Continue) terem um valor a enviar.
$ApiKey  = 'local'
$Headers = @{ 'Content-Type' = 'application/json'; 'Authorization' = "Bearer $ApiKey" }

# ─── perfis ───────────────────────────────────────────────────────────────────
# VramGB = modelo + cache KV em q8_0 no contexto indicado. Calculado, não chutado:
# o Qwen3-8B tem 36 camadas, 8 kv-heads e head_dim 128, o que dá 144 KB/token em
# f16 e metade disso em q8_0. Em 16k de contexto: 5.03 (modelo) + 1.21 = 6.24 GB.
#
# Tools = o modelo emite tool_calls estruturado, ou seja: serve como AGENTE.
# Testado no equivalente MLX: Qwen2.5-Coder emite a tag errada (<tools> em vez de
# <tool_call>) e o tool_calls volta null. O fine-tune para código degradou isso.
$Profiles = @(
    [pscustomobject]@{
        Name = 'agent'; Repo = 'Qwen/Qwen3-8B-GGUF'; Quant = 'Q4_K_M'
        FileGB = 5.03; Ctx = 16384; VramGB = 6.24; Tools = $true
        Desc = 'Qwen3 8B. Tool calling validado (ciclo completo), ~19 tok/s. Melhor qualidade com tools. Padrao.'
    },
    [pscustomobject]@{
        Name = 'fast'; Repo = 'bartowski/Qwen2.5-Coder-7B-Instruct-GGUF'; Quant = 'Q4_K_M'
        FileGB = 4.68; Ctx = 16384; VramGB = 5.7; Tools = $false
        Desc = 'Qwen2.5 Coder 7B. Escreve codigo melhor, mas NAO serve como agente. Ideal para chat/edit no VSCode.'
    },
    [pscustomobject]@{
        Name = 'quality'; Repo = 'bartowski/Qwen2.5-Coder-14B-Instruct-GGUF'; Quant = 'Q4_K_M'
        FileGB = 8.99; Ctx = 8192; VramGB = 9.6; Tools = $false
        Desc = 'Qwen2.5 Coder 14B. NAO CABE nos 8 GB: parte das camadas vai para a CPU e fica lento. Use so se aceitar a queda.'
    },
    [pscustomobject]@{
        Name = 'tiny'; Repo = 'Qwen/Qwen3-4B-GGUF'; Quant = 'Q4_K_M'
        FileGB = 2.50; Ctx = 32768; VramGB = 4.1; Tools = $true
        Desc = 'Qwen3 4B. Tool calling validado e ~33 tok/s — quase 2x o 8B. Cabe com folga em 8 GB. Comece por este.'
    }
)

# ─── saída ────────────────────────────────────────────────────────────────────
function Write-Head($t) { Write-Host "`n$t" -ForegroundColor White }
function Write-Ok($t)   { Write-Host "OK  " -ForegroundColor Green -NoNewline; Write-Host $t }
function Write-Warn2($t){ Write-Host "!   " -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Write-Err2($t) { Write-Host "X   " -ForegroundColor Red -NoNewline; Write-Host $t }
function Write-Dim($t)  { Write-Host $t -ForegroundColor DarkGray }

function Get-LlmProfile([string]$name) {
    if (-not $name) { $name = $DefaultProfile }
    $p = $Profiles | Where-Object Name -EQ $name
    if (-not $p) {
        Write-Err2 "Perfil desconhecido: '$name'. Rode: .\llm-server.ps1 models"
        exit 1
    }
    $p
}

function Get-ServerExe { Join-Path $BinDir 'llama-server.exe' }

function Get-FreeDiskGB {
    $d = Get-PSDrive -Name ($env:LOCALAPPDATA.Substring(0, 1)) -ErrorAction SilentlyContinue
    if ($d) { [math]::Round($d.Free / 1GB, 1) } else { 0 }
}

# VRAM real pelo nvidia-smi. Sem driver NVIDIA nada aqui faz sentido.
function Get-VramInfo {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return $null }
    try {
        $out = & nvidia-smi --query-gpu=name,memory.total,memory.used `
                            --format=csv,noheader,nounits 2>$null
        if (-not $out) { return $null }
        $f = ($out -split ',').Trim()
        [pscustomobject]@{
            Name     = $f[0]
            TotalGB  = [math]::Round([double]$f[1] / 1024, 1)
            UsedGB   = [math]::Round([double]$f[2] / 1024, 1)
            FreeGB   = [math]::Round(([double]$f[1] - [double]$f[2]) / 1024, 1)
        }
    } catch { $null }
}

function Get-ServerProcess {
    if (-not (Test-Path $PidFile)) { return $null }
    $procId = Get-Content $PidFile -ErrorAction SilentlyContinue
    if (-not $procId) { return $null }
    Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue
}

function Test-PortBusy {
    $null -ne (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

# Onde os GGUF baixados por -hf realmente ficam. Verificado na prática: o
# llama.cpp reaproveita o cache do Hugging Face (~/.cache/huggingface/hub), NÃO
# um diretório próprio. Olhar no lugar errado faria o script rebaixar 5 GB por
# nada, achando que o arquivo não existe.
function Get-CachePaths {
    $paths = @()
    if ($env:LLAMA_CACHE) { $paths += $env:LLAMA_CACHE }
    if ($env:HF_HOME)     { $paths += (Join-Path $env:HF_HOME 'hub') }
    $paths += (Join-Path $env:USERPROFILE '.cache\huggingface\hub')
    $paths += (Join-Path $env:LOCALAPPDATA 'llama.cpp')
    $paths | Where-Object { $_ -and (Test-Path $_) }
}

function Test-ModelDownloaded($prof) {
    $needle = ($prof.Repo -split '/')[-1]
    foreach ($cache in (Get-CachePaths)) {
        # O blob baixado leva o nome do repo no diretório e o quant no arquivo;
        # arquivos .downloadInProgress são descartados de propósito.
        $hit = Get-ChildItem $cache -Filter '*.gguf' -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -like "*$needle*" -and $_.Name -notlike '*downloadInProgress*' }
        if ($hit) { return $true }
        $byRepo = Join-Path $cache ("models--" + ($prof.Repo -replace '/', '--'))
        if (Test-Path $byRepo) {
            $blobs = Get-ChildItem $byRepo -Recurse -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Length -gt 1GB -and $_.Name -notlike '*downloadInProgress*' }
            if ($blobs) { return $true }
        }
    }
    $false
}

# ─── setup ────────────────────────────────────────────────────────────────────
function Invoke-Setup {
    Write-Head 'Instalando llama.cpp com CUDA'

    $vram = Get-VramInfo
    if (-not $vram) {
        Write-Err2 'nvidia-smi nao encontrado. Instale o driver NVIDIA antes de continuar.'
        Write-Dim  'https://www.nvidia.com/Download/index.aspx'
        exit 1
    }
    Write-Ok "GPU: $($vram.Name) — $($vram.TotalGB) GB de VRAM"

    New-Item -ItemType Directory -Force -Path $Root, $BinDir, $ModelDir | Out-Null

    # winget install llama.cpp entrega build CPU/Vulkan, SEM CUDA. Por isso vamos
    # direto no release do GitHub pegar o zip com CUDA.
    Write-Dim 'Consultando o ultimo release do llama.cpp...'
    $rel = Invoke-RestMethod 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest' `
                             -Headers @{ 'User-Agent' = 'llm-server-ps1' }
    Write-Ok "release $($rel.tag_name)"

    $binAsset = $rel.assets | Where-Object { $_.name -like "*bin-win-cuda-$CudaVariant-x64.zip" } | Select-Object -First 1
    $rtAsset  = $rel.assets | Where-Object { $_.name -like "cudart-*win-cuda-$CudaVariant-x64.zip" } | Select-Object -First 1

    if (-not $binAsset) {
        Write-Err2 "Nao achei build CUDA $CudaVariant neste release."
        Write-Dim  'Variantes disponiveis:'
        $rel.assets | Where-Object { $_.name -like '*win-cuda*' } | ForEach-Object { Write-Dim "  $($_.name)" }
        Write-Dim  'Escolha outra com: $env:LLM_CUDA="13.3"; .\llm-server.ps1 setup'
        exit 1
    }

    foreach ($a in @($binAsset, $rtAsset)) {
        if (-not $a) { continue }
        $zip = Join-Path $env:TEMP $a.name
        Write-Host "  baixando $($a.name) ($([math]::Round($a.size/1MB)) MB)..."
        Invoke-WebRequest $a.browser_download_url -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $BinDir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }

    $exe = Get-ServerExe
    if (-not (Test-Path $exe)) {
        # Alguns zips extraem dentro de subpasta; localiza e normaliza.
        $found = Get-ChildItem $BinDir -Filter 'llama-server.exe' -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) {
            Copy-Item (Join-Path $found.DirectoryName '*') $BinDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path (Get-ServerExe)) {
        Write-Ok "llama-server instalado em $BinDir"
        Write-Dim ((& (Get-ServerExe) --version 2>&1 | Select-Object -First 1))
        Write-Host ''
        Write-Ok 'Pronto. Agora: .\llm-server.ps1 start agent'
    } else {
        Write-Err2 "Extraiu mas nao achei llama-server.exe em $BinDir"
        exit 1
    }
}

# ─── informação ───────────────────────────────────────────────────────────────
function Invoke-Models {
    Write-Head 'Perfis'
    $rows = foreach ($p in $Profiles) {
        [pscustomobject]@{
            PERFIL  = $p.Name
            ARQUIVO = "$($p.FileGB) GB"
            VRAM    = "$($p.VramGB) GB"
            CTX     = $p.Ctx
            TOOLS   = if ($p.Tools) { 'sim' } else { 'nao' }
            ESTADO  = if (Test-ModelDownloaded $p) { 'baixado' } else { 'ausente' }
            MODELO  = "$($p.Repo):$($p.Quant)"
        }
    }
    $rows | Format-Table -AutoSize

    foreach ($p in $Profiles) { Write-Dim "  $($p.Name.PadRight(8)) $($p.Desc)" }

    $vram = Get-VramInfo
    Write-Host ''
    if ($vram) {
        Write-Dim "Padrao: $DefaultProfile · GPU: $($vram.Name) $($vram.TotalGB) GB (livre $($vram.FreeGB) GB) · disco: $(Get-FreeDiskGB) GB"
    } else {
        Write-Warn2 'nvidia-smi indisponivel — rode: .\llm-server.ps1 setup'
    }
    Write-Dim 'TOOLS=sim -> serve como agente (pi, Cline). TOOLS=nao -> so chat/edit.'
}

function Invoke-Vram {
    Write-Head 'Orcamento de VRAM'
    $vram = Get-VramInfo
    if (-not $vram) { Write-Err2 'nvidia-smi nao encontrado.'; return }

    Write-Host "  GPU: $($vram.Name)"
    Write-Host "  total $($vram.TotalGB) GB · em uso $($vram.UsedGB) GB · livre $($vram.FreeGB) GB`n"

    foreach ($p in $Profiles) {
        $fits = $p.VramGB -le ($vram.TotalGB - 0.8)   # ~0.8 GB reservado ao desktop
        $tag  = if ($fits) { 'cabe   ' } else { 'ESTOURA' }
        $col  = if ($fits) { 'Green' } else { 'Red' }
        Write-Host "  $($p.Name.PadRight(8)) $($p.VramGB) GB  " -NoNewline
        Write-Host $tag -ForegroundColor $col -NoNewline
        Write-Host "  (modelo $($p.FileGB) GB + KV q8_0 em ctx $($p.Ctx))"
    }
    Write-Host ''
    Write-Dim 'Quando estoura, o llama.cpp joga camadas para a CPU: funciona, mas fica'
    Write-Dim 'varias vezes mais lento. Prefira um perfil que caiba inteiro na VRAM.'
}

# ─── ciclo de vida ────────────────────────────────────────────────────────────
function Invoke-Pull($name) {
    $p = Get-LlmProfile $name
    if (Test-ModelDownloaded $p) { Write-Ok "$($p.Name) ja baixado"; return }
    $exe = Get-ServerExe
    if (-not (Test-Path $exe)) { Write-Err2 'llama.cpp ausente. Rode: .\llm-server.ps1 setup'; exit 1 }

    $free = Get-FreeDiskGB
    if ($free -lt ($p.FileGB + 3)) {
        Write-Err2 "Disco insuficiente: precisa ~$($p.FileGB) GB (+3 de folga), ha $free GB."
        exit 1
    }
    Write-Head "Baixando $($p.Name) — $($p.FileGB) GB"
    Write-Dim "$($p.Repo):$($p.Quant)"
    # O próprio llama-server baixa via -hf; --no-warmup evita gastar tempo depois.
    & $exe -hf "$($p.Repo):$($p.Quant)" --no-warmup -c 512 -ngl 0 --port 0 2>&1 |
        Select-String -Pattern 'download|%|error' | Select-Object -Last 5
    if (Test-ModelDownloaded $p) { Write-Ok 'Pesos prontos.' } else { Write-Warn2 'Nao confirmei o download; tente start.' }
}

function Wait-Ready([int]$procId, [string]$alias, [int]$timeoutSec = 420) {
    # /health responde antes do modelo estar pronto para gerar. Só uma geração real
    # prova que subiu — mesma lição do lado macOS.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Host '  carregando' -NoNewline -ForegroundColor DarkGray
    $body = @{ model = $alias; messages = @(@{ role = 'user'; content = 'ok' }); max_tokens = 1 } | ConvertTo-Json -Depth 5
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
            Write-Host ''; return 'died'
        }
        try {
            Invoke-RestMethod "http://${ProbeHost}:$Port/v1/chat/completions" -Method Post `
                -Headers $Headers -Body $body -TimeoutSec 10 | Out-Null
            Write-Host ''
            return [int]$sw.Elapsed.TotalSeconds
        } catch { }
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
    }
    Write-Host ''
    return 'timeout'
}

function Invoke-Start($name) {
    $p = Get-LlmProfile $name
    $exe = Get-ServerExe
    if (-not (Test-Path $exe)) { Write-Err2 'llama.cpp ausente. Rode: .\llm-server.ps1 setup'; exit 1 }

    $existing = Get-ServerProcess
    if ($existing) {
        $cur = if (Test-Path $ProfFile) { Get-Content $ProfFile } else { '?' }
        Write-Warn2 "Ja rodando (PID $($existing.Id) · perfil $cur) em http://${BindHost}:$Port"
        Write-Dim  "Para trocar: .\llm-server.ps1 restart $($p.Name)"
        return
    }
    if (Test-PortBusy) {
        Write-Err2 "Porta $Port ocupada. Use: `$env:LLM_PORT=8081; .\llm-server.ps1 start"
        exit 1
    }

    New-Item -ItemType Directory -Force -Path $Root | Out-Null

    $vram = Get-VramInfo
    if ($vram -and $p.VramGB -gt ($vram.FreeGB)) {
        Write-Warn2 "Perfil pede $($p.VramGB) GB e ha $($vram.FreeGB) GB livres na GPU."
        Write-Warn2 'Camadas vao vazar para a CPU e a geracao fica lenta. Feche jogos/navegador,'
        Write-Warn2 "ou use um perfil menor: .\llm-server.ps1 start tiny"
    }

    Write-Head "Subindo $($p.Name) em http://${BindHost}:$Port"
    Write-Dim "$($p.Repo):$($p.Quant) · ctx $($p.Ctx) · alias $($p.Name)"

    # -ngl 999  manda todas as camadas para a VRAM (o llama.cpp reduz se nao couber)
    # -ctk/-ctv q8_0  corta o cache KV pela metade: e o que faz 16k de contexto
    #                 caber em 8 GB junto com o modelo
    # -fa on    flash attention, menos memoria e mais velocidade em Ampere
    # --jinja   usa o template embutido no GGUF; e o que habilita tool calling
    #           (ja e o padrao nas versoes atuais, explicito aqui de proposito)
    # NAO chamar esta variavel de $args: no PowerShell $args e automatica e
    # reservada; atribuir a ela dentro de funcao gera comportamento estranho.
    $serverArgs = @(
        '-hf', "$($p.Repo):$($p.Quant)"
        '--host', $BindHost, '--port', "$Port"
        '-c', "$($p.Ctx)"
        '-ngl', '999'
        '-ctk', 'q8_0', '-ctv', 'q8_0'
        '-fa', 'on'
        '--jinja'
        '-a', $p.Name
        # O llama-server libera CORS para '*' e nao exige chave por padrao. Como
        # so escutamos em 127.0.0.1, o risco e baixo, mas fechamos de todo jeito.
        '--api-key', 'local'
    )

    $proc = Start-Process -FilePath $exe -ArgumentList $serverArgs -PassThru -NoNewWindow `
                          -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err"
    $proc.Id  | Set-Content $PidFile
    $p.Name   | Set-Content $ProfFile

    $r = Wait-Ready $proc.Id $p.Name
    switch ($r) {
        'died' {
            Write-Err2 'O servidor morreu ao subir. Ultimas linhas:'
            Get-Content $LogFile, "$LogFile.err" -Tail 20 -ErrorAction SilentlyContinue
            Remove-Item $PidFile, $ProfFile -ErrorAction SilentlyContinue
            exit 1
        }
        'timeout' { Write-Warn2 "Sem resposta no tempo limite. Processo vivo (PID $($proc.Id)). Veja: .\llm-server.ps1 logs" }
        default {
            Write-Ok "No ar em ${r}s — http://${BindHost}:$Port"
            Show-Usage $p
        }
    }
}

function Show-Usage($p) {
    Write-Head 'Como usar'
    Write-Dim '# pergunta rapida'
    Write-Host "  .\llm-server.ps1 ask `"Escreva um debounce generico em TypeScript`""
    Write-Host ''
    Write-Dim '# pi (agente de codigo)'
    Write-Host "  pi --provider llama-local --model $($p.Name) --api-key $ApiKey"
    Write-Dim  '  (configure uma vez com: .\llm-clients-setup.ps1)'
    Write-Dim  '  NAO use --provider llama.cpp: esse provider nativo exige o servidor em'
    Write-Dim  '  router mode (sem -hf), e este script roda em single-model mode.'
    Write-Host ''
    Write-Dim '# qualquer cliente compativel com OpenAI (Continue, Cline, Aider)'
    Write-Host "  `$env:OPENAI_BASE_URL = 'http://${BindHost}:$Port/v1'"
    Write-Host "  `$env:OPENAI_API_KEY  = '$ApiKey'"
    Write-Host ''
    if (-not $p.Tools) {
        Write-Warn2 "Perfil '$($p.Name)' NAO emite tool_calls: serve para chat/edit, nao para agente."
        Write-Dim  "Para agente: .\llm-server.ps1 restart agent"
    }
    Write-Dim 'O modelo fica residente: a carga e paga uma vez, nao a cada pedido.'
}

function Invoke-Stop {
    $proc = Get-ServerProcess
    if ($proc) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 700
        Remove-Item $PidFile, $ProfFile -ErrorAction SilentlyContinue
        Write-Ok "Derrubado (PID $($proc.Id)). VRAM liberada."
    } else {
        Remove-Item $PidFile, $ProfFile -ErrorAction SilentlyContinue
        Write-Host 'Nada rodando.'
        if (Test-PortBusy) { Write-Warn2 "Porta $Port ocupada por processo externo." }
    }
}

function Invoke-Status {
    Write-Head 'Estado'
    $proc = Get-ServerProcess
    if ($proc) {
        $cur = if (Test-Path $ProfFile) { Get-Content $ProfFile } else { '?' }
        Write-Ok "No ar — PID $($proc.Id) · perfil $cur · http://${BindHost}:$Port"
        # StartTime pode lançar por permissão em alguns contextos; não vale
        # derrubar o status por causa de um enfeite.
        try {
            $up = (Get-Date) - $proc.StartTime
            Write-Host ("  RAM do processo: {0:N2} GB · no ar ha: {1:hh\:mm\:ss}" -f ($proc.WorkingSet64 / 1GB), $up)
        } catch {
            Write-Host ("  RAM do processo: {0:N2} GB" -f ($proc.WorkingSet64 / 1GB))
        }
    } else {
        Write-Host '  parado.'
        if (Test-PortBusy) { Write-Warn2 "porta $Port ocupada por processo externo" }
    }
    $vram = Get-VramInfo
    if ($vram) {
        # A VRAM e o numero que importa: o peso do modelo vive nela, nao na RAM.
        Write-Host "  VRAM: $($vram.UsedGB) / $($vram.TotalGB) GB em uso (livre $($vram.FreeGB) GB)"
    }
    Write-Host "  disco livre: $(Get-FreeDiskGB) GB"
}

function Invoke-Logs {
    if (-not (Test-Path $LogFile)) { Write-Err2 "Sem log em $LogFile"; exit 1 }
    Write-Dim "$LogFile — Ctrl-C para sair"
    Get-Content $LogFile -Wait -Tail 30
}

function Invoke-Ask([string]$question) {
    if (-not $question) { Write-Err2 'Uso: .\llm-server.ps1 ask "sua pergunta"'; exit 1 }
    if (-not (Get-ServerProcess)) { Write-Err2 'Servidor parado. Suba com: .\llm-server.ps1 start'; exit 1 }

    $alias = if (Test-Path $ProfFile) { Get-Content $ProfFile } else { $DefaultProfile }
    $body = @{
        model      = $alias
        messages   = @(@{ role = 'user'; content = $question })
        max_tokens = 2048
    } | ConvertTo-Json -Depth 5

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod "http://${ProbeHost}:$Port/v1/chat/completions" -Method Post `
                 -Headers $Headers -Body $body -TimeoutSec 1800
    } catch {
        Write-Err2 "Falhou: $($_.Exception.Message)"
        exit 1
    }
    $sw.Stop()

    $txt = $r.choices[0].message.content
    # Alguns modelos vazam o token de fim de turno na resposta.
    foreach ($t in '<|im_end|>', '<end_of_turn>', '<|endoftext|>') { $txt = $txt -replace [regex]::Escape($t), '' }
    Write-Host $txt.Trim()

    $n = $r.usage.completion_tokens
    $s = $sw.Elapsed.TotalSeconds
    $rate = if ($n -and $s -gt 0) { " · {0:N1} tok/s" -f ($n / $s) } else { '' }
    Write-Dim ("`n[{0:N1}s{1}]" -f $s, $rate)
}

function Invoke-Bench {
    if (-not (Get-ServerProcess)) { Write-Err2 'Servidor parado. Suba com: .\llm-server.ps1 start'; exit 1 }
    $cur = if (Test-Path $ProfFile) { Get-Content $ProfFile } else { '?' }
    Write-Head "Medindo nesta maquina (perfil $cur)"
    Invoke-Ask 'Implemente quicksort em Python com comentarios curtos.' | Out-Null
}

function Invoke-Help {
    Write-Head 'llm-server — LLM local em HTTP via llama.cpp + CUDA'
    @'
  setup            baixa e instala o llama.cpp com CUDA
  start [perfil]   sobe o servidor (padrao: agent)
  stop             derruba e libera a VRAM
  restart [perfil] troca de modelo
  status           estado, VRAM em uso
  logs             acompanha o log
  ask "..."        pergunta e imprime a resposta com tok/s
  models           perfis e o que ja foi baixado
  pull <perfil>    so baixa os pesos
  bench            mede tokens/s reais aqui
  vram             orcamento de VRAM por perfil
'@ | Write-Host
    Write-Dim "Porta: $Port (altere com `$env:LLM_PORT=8081) · escuta so em $BindHost"
}

# ─── entrada ──────────────────────────────────────────────────────────────────
$arg1 = if ($Rest -and $Rest.Count -gt 0) { $Rest[0] } else { $null }

switch ($Command) {
    'setup'   { Invoke-Setup }
    'start'   { Invoke-Start $arg1 }
    'stop'    { Invoke-Stop }
    'restart' { Invoke-Stop; Start-Sleep -Seconds 1; Invoke-Start $arg1 }
    'status'  { Invoke-Status }
    'logs'    { Invoke-Logs }
    'ask'     { Invoke-Ask ($Rest -join ' ') }
    'models'  { Invoke-Models }
    'pull'    { Invoke-Pull $arg1 }
    'bench'   { Invoke-Bench }
    'vram'    { Invoke-Vram }
    'help'    { Invoke-Help }
}
