<#
.SYNOPSIS
  Configura o pi e o Continue (VSCode) para usar o LLM local do llm-server.ps1.

.DESCRIPTION
  Escreve dois arquivos:
    %USERPROFILE%\.pi\agent\models.json    provider custom "llama-local" para o pi
    %USERPROFILE%\.continue\config.yaml    modelos locais para a extensão Continue

  Faz backup de qualquer arquivo existente antes de sobrescrever.

  POR QUE UM PROVIDER CUSTOM E NAO O NATIVO 'llama.cpp' DO PI:
  o provider nativo espera o llama-server em *router mode* — iniciado SEM -m/-hf,
  com --models-dir, expondo os endpoints /llama para listar e carregar modelos.
  O llm-server.ps1 roda em *single-model mode* (usa -hf para baixar e fixar um
  modelo), que é mais simples e previsível. Em single-model os endpoints /llama
  não existem, então o provider nativo não enxerga nada. O provider custom fala
  direto com /v1/chat/completions, que funciona nos dois modos.

.PARAMETER Port
  Porta do servidor local. Padrão 8080 (igual ao llm-server.ps1).

.PARAMETER ApiKey
  Chave que o llm-server.ps1 exige. Padrão 'local'.

.PARAMETER Force
  Sobrescreve sem perguntar (ainda faz backup).

.EXAMPLE
  .\llm-clients-setup.ps1
  .\llm-clients-setup.ps1 -Port 8081 -Force
#>

[CmdletBinding()]
param(
    [int]$Port = 8080,
    [string]$ApiKey = 'local',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$BindHost = '127.0.0.1'
$BaseUrl  = "http://${BindHost}:$Port/v1"

function Write-Head($t) { Write-Host "`n$t" -ForegroundColor White }
function Write-Ok($t)   { Write-Host 'OK  ' -ForegroundColor Green -NoNewline; Write-Host $t }
function Write-Warn2($t){ Write-Host '!   ' -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Write-Dim($t)  { Write-Host $t -ForegroundColor DarkGray }

# Grava com backup datado. Nunca sobrescrever configuração alheia em silêncio.
function Save-Config([string]$path, [string]$content) {
    $dir = Split-Path $path -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    if (Test-Path $path) {
        if (-not $Force) {
            Write-Warn2 "Ja existe: $path"
            $ans = Read-Host '    sobrescrever? (s/N)'
            if ($ans -notmatch '^[sSyY]') { Write-Dim '    mantido como estava.'; return $false }
        }
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$path.bak-$stamp"
        Copy-Item $path $backup -Force
        Write-Dim "    backup: $backup"
    }
    # UTF8 sem BOM: o parser YAML do Continue engasga com BOM.
    [IO.File]::WriteAllText($path, $content, (New-Object Text.UTF8Encoding $false))
    Write-Ok "escrito: $path"
    $true
}

# ─── pi ───────────────────────────────────────────────────────────────────────
# Vai em models.json, NAO em models-store.json — esse segundo é cache de catálogo
# e é sobrescrito quando o pi atualiza os providers.
#
# O `id` de cada modelo é o ALIAS que o llm-server.ps1 passa em -a (o nome do
# perfil), não o repo do Hugging Face. Em single-model mode o llama-server serve
# um alias por vez: o que estiver carregado responde, os outros ficam listados
# aqui só para você trocar sem editar arquivo (troque com: llm-server.ps1 restart).
#
# compat.supportsDeveloperRole = false porque o llama-server não entende o papel
# 'developer' usado por modelos com reasoning; sem isso o system prompt se perde.
$piConfig = @"
{
  "providers": {
    "llama-local": {
      "baseUrl": "$BaseUrl",
      "api": "openai-completions",
      "apiKey": "$ApiKey",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false,
        "supportsStore": false,
        "maxTokensField": "max_tokens"
      },
      "models": [
        {
          "id": "agent",
          "name": "Qwen3 8B (local, CUDA) - tool calling OK",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 16384,
          "maxTokens": 4096,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        },
        {
          "id": "fast",
          "name": "Qwen2.5 Coder 7B (local) - SEM tools, so chat",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 16384,
          "maxTokens": 4096,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        },
        {
          "id": "tiny",
          "name": "Qwen3 4B (local) - leve, tool calling OK",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 32768,
          "maxTokens": 4096,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        },
        {
          "id": "quality",
          "name": "Qwen2.5 Coder 14B (local) - estoura 8GB de VRAM",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 8192,
          "maxTokens": 4096,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
"@

# ─── Continue (VSCode) ────────────────────────────────────────────────────────
# provider: openai vale para QUALQUER endpoint compatível — não manda nada para a
# OpenAI, quem decide é o apiBase. contextLength fica dentro de
# defaultCompletionOptions, não na raiz (erro comum que faz o modelo truncar).
$continueConfig = @"
name: Local Config
version: 1.0.0
schema: v1

# Modelos servidos por llm-server.ps1 (llama.cpp + CUDA) na porta $Port.
# Suba o servidor antes: .\llm-server.ps1 start agent
#
# O campo 'model' e o ALIAS do perfil (-a no llama-server), nao o repo do HF.
# Só UM perfil fica carregado por vez: trocar de entrada aqui nao troca o modelo
# servido. Para trocar de verdade: .\llm-server.ps1 restart <perfil>
models:
  # Unico perfil que emite tool_calls estruturado — necessario para modo Agent
  # e para Cline. Validado com o ciclo completo (pede tool, recebe, usa).
  - name: Qwen3 8B (local) - agente
    provider: openai
    apiBase: $BaseUrl
    apiKey: $ApiKey
    model: agent
    roles:
      - chat
      - edit
      - apply
    defaultCompletionOptions:
      contextLength: 16384
      maxTokens: 4096
      temperature: 0

  # Escreve codigo melhor, porem tool_calls volta null: so chat/edit.
  - name: Qwen2.5 Coder 7B (local)
    provider: openai
    apiBase: $BaseUrl
    apiKey: $ApiKey
    model: fast
    roles:
      - chat
      - edit
      - apply
    defaultCompletionOptions:
      contextLength: 16384
      maxTokens: 4096
      temperature: 0

  - name: Qwen3 4B (local) - leve
    provider: openai
    apiBase: $BaseUrl
    apiKey: $ApiKey
    model: tiny
    roles:
      - chat
      - edit
    defaultCompletionOptions:
      contextLength: 32768
      maxTokens: 4096
      temperature: 0

# Autocomplete fica de fora de proposito: dispara a cada tecla e competiria pela
# MESMA VRAM do chat. Numa 3060 Ti de 8 GB isso empurra camadas para a CPU e
# derruba tudo. Se quiser, suba um segundo servidor com o perfil tiny em outra
# porta e aponte para la:
#
#   `$env:LLM_PORT=8081; .\llm-server.ps1 start tiny
#
#   - name: Autocomplete tiny (local)
#     provider: openai
#     apiBase: http://${BindHost}:8081/v1
#     apiKey: $ApiKey
#     model: tiny
#     roles: [autocomplete]
"@

# ─── execução ─────────────────────────────────────────────────────────────────
Write-Head "Configurando clientes para http://${BindHost}:$Port"

$piPath       = Join-Path $env:USERPROFILE '.pi\agent\models.json'
$continuePath = Join-Path $env:USERPROFILE '.continue\config.yaml'

Write-Head 'pi'
if (-not (Get-Command pi -ErrorAction SilentlyContinue)) {
    Write-Warn2 'pi nao encontrado no PATH. A config sera escrita de todo jeito.'
    Write-Dim   'Instale com: npm install -g @earendil-works/pi-coding-agent'
}
$piOk = Save-Config $piPath $piConfig

Write-Head 'Continue (VSCode)'
if (-not (Test-Path (Join-Path $env:USERPROFILE '.vscode\extensions'))) {
    Write-Warn2 'Nao achei extensoes do VSCode. A config sera escrita de todo jeito.'
}
$contOk = Save-Config $continuePath $continueConfig

# ─── verificação ──────────────────────────────────────────────────────────────
Write-Head 'Servidor esta no ar?'
try {
    $r = Invoke-RestMethod "http://${BindHost}:$Port/v1/models" `
            -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSec 5
    $ids = ($r.data | ForEach-Object { $_.id }) -join ', '
    Write-Ok "responde — modelo carregado: $ids"
} catch {
    Write-Warn2 "nao responde em $BaseUrl"
    Write-Dim   'Suba com: .\llm-server.ps1 start agent'
}

Write-Head 'Como usar'
if ($piOk) {
    Write-Host '  pi:' -NoNewline; Write-Host "  pi --provider llama-local --model agent --api-key $ApiKey"
    Write-Dim  '      --api-key nao e opcional: o pi esconde do /model qualquer modelo sem auth.'
}
if ($contOk) {
    Write-Host '  VSCode:' -NoNewline; Write-Host '  recarregue a janela (Ctrl+Shift+P -> Reload Window)'
    Write-Dim  '      os modelos aparecem no seletor do Continue (Ctrl+L)'
}
Write-Host ''
Write-Warn2 'Use o perfil "agent" para pi/Cline. O "fast" escreve codigo melhor,'
Write-Warn2 'mas nao emite tool_calls e nao funciona como agente.'
Write-Host ''
