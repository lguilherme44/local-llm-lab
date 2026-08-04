import { NextResponse } from "next/server"
import { execFile } from "child_process"
import { promisify } from "util"
import path from "path"

const execFileAsync = promisify(execFile)

export async function POST(request: Request) {
  try {
    const body = await request.json()
    const { repo, target = "windows", filename: customFilename } = body

    if (!repo || typeof repo !== "string") {
      return NextResponse.json(
        { status: "error", message: "Parâmetro 'repo' é obrigatório." },
        { status: 400 }
      )
    }

    // Sanitização estrita do repositório: bloqueia '..' e caracteres de injeção de shell
    if (
      !/^[a-zA-Z0-9_-]+(\/[a-zA-Z0-9_.-]+)?$/.test(repo) ||
      repo.includes("..")
    ) {
      return NextResponse.json(
        { status: "error", message: "Formato de repositório/perfil inválido." },
        { status: 400 }
      )
    }

    // Sanitização estrita do nome de arquivo customizado (se informado)
    let sanitizedCustomFilename: string | undefined = undefined
    if (customFilename && typeof customFilename === "string") {
      const base = path.basename(customFilename.trim())
      if (!/^[a-zA-Z0-9_.-]+$/.test(base) || base.includes("..")) {
        return NextResponse.json(
          {
            status: "error",
            message:
              "Nome de arquivo customizado inválido. Use apenas caracteres alfanuméricos, ponto, traço ou underline."
          },
          { status: 400 }
        )
      }
      sanitizedCustomFilename = base
    }

    const isWindowsTarget =
      target === "windows" || repo.toLowerCase().includes("gguf")

    if (isWindowsTarget) {
      // 1. Resolver o nome exato do arquivo .gguf via API do Hugging Face se não informado
      let resolvedGguf = sanitizedCustomFilename
      if (!resolvedGguf) {
        try {
          const hfRes = await fetch(
            `https://huggingface.co/api/models/${repo}`,
            { signal: AbortSignal.timeout(5000) }
          )
          if (hfRes.ok) {
            const hfData = await hfRes.json()
            const siblings = hfData.siblings || []
            const ggufFile = siblings.find(
              (s: any) => s.rfilename && s.rfilename.endsWith(".gguf")
            )
            if (ggufFile && typeof ggufFile.rfilename === "string") {
              const baseName = path.basename(ggufFile.rfilename)
              if (/^[a-zA-Z0-9_.-]+$/.test(baseName)) {
                resolvedGguf = baseName
              }
            }
          }
        } catch (e) {
          console.warn("Não foi possível consultar a API do HuggingFace:", e)
        }
      }

      // Se ainda assim não resolveu, usa o nome do repo + .gguf sanitizado
      if (!resolvedGguf) {
        resolvedGguf = `${path.basename(repo)}.gguf`
      }

      // Garantia final de sanitização estrita de resolvedGguf
      resolvedGguf = path
        .basename(resolvedGguf)
        .replace(/[^a-zA-Z0-9_.-]/g, "_")

      const fileUrl = `https://huggingface.co/${repo}/resolve/main/${resolvedGguf}`
      const safeFileName = resolvedGguf

      // Execução com argumentos totalmente sanitizados sem metacaracteres shell
      const winCmd = `powershell -Command "New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA\\llm-server\\models | Out-Null; Write-Host 'Baixando ${safeFileName}...'; curl.exe -L -C - --retry 5 --progress-bar -o ''$env:LOCALAPPDATA\\llm-server\\models\\${safeFileName}'' ''${fileUrl}''; if ((Get-Item ''$env:LOCALAPPDATA\\llm-server\\models\\${safeFileName}'').Length -lt 10MB) { Remove-Item ''$env:LOCALAPPDATA\\llm-server\\models\\${safeFileName}'' -Force; Write-Error 'Download Incompleto ou Erro 404 do Hugging Face (arquivo menor que 10MB)'; exit 1 } else { Write-Host 'Download Concluído com Sucesso!' }"`

      const { stdout, stderr } = await execFileAsync("ssh", ["windows", winCmd])

      return NextResponse.json({
        status: "success",
        target: "windows",
        repo,
        resolved_file: safeFileName,
        output: stdout || stderr
      })
    }

    // Download local no macOS via llm-server.command
    const scriptPath = path.resolve(
      process.cwd(),
      "../macos/llm-server.command"
    )
    const { stdout, stderr } = await execFileAsync(scriptPath, ["pull", repo])

    return NextResponse.json({
      status: "success",
      target: "local",
      repo,
      output: stdout || stderr
    })
  } catch (error: any) {
    return NextResponse.json(
      {
        status: "error",
        message:
          error.message ||
          "Falha ao baixar o modelo. Verifique se o arquivo .gguf existe no repositório."
      },
      { status: 500 }
    )
  }
}
