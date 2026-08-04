import { NextResponse } from "next/server"
import { execFile } from "child_process"
import { promisify } from "util"
import path from "path"
import fs from "fs"

const execFileAsync = promisify(execFile)

function getMacScriptPath(): string {
  const rootPath = path.resolve(process.cwd(), "macos/llm-server.command")
  if (fs.existsSync(rootPath)) return rootPath

  const harnessParentPath = path.resolve(
    process.cwd(),
    "../macos/llm-server.command"
  )
  if (fs.existsSync(harnessParentPath)) return harnessParentPath

  return rootPath
}

export async function POST(request: Request) {
  try {
    const body = await request.json()
    const { modelId, target = "windows" } = body

    if (!modelId || typeof modelId !== "string") {
      return NextResponse.json(
        { status: "error", message: "Parâmetro 'modelId' é obrigatório." },
        { status: 400 }
      )
    }

    // Sanitização estrita do ID/Perfil do modelo (anti injeção de shell)
    const sanitizedModelId = path
      .basename(modelId.trim())
      .replace(/[^a-zA-Z0-9_.-]/g, "_")
    if (!sanitizedModelId || sanitizedModelId.includes("..")) {
      return NextResponse.json(
        { status: "error", message: "Identificador de modelo inválido." },
        { status: 400 }
      )
    }

    if (target === "windows") {
      // Passagem segura de argumentos separados via SSH (evita interpolação de shell string única)
      const sshArgs = [
        "windows",
        "powershell",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "C:\\Users\\Admin\\wk\\local-llm-lab\\windows\\llm-server.ps1",
        "restart",
        sanitizedModelId,
        "-Lan"
      ]

      const { stdout, stderr } = await execFileAsync("ssh", sshArgs)

      return NextResponse.json({
        status: "success",
        target: "windows",
        active_model: sanitizedModelId,
        output: stdout || stderr
      })
    }

    // Troca de modelo no Mac local via llm-server.command com resolução resiliente do caminho
    const scriptPath = getMacScriptPath()
    const { stdout, stderr } = await execFileAsync(scriptPath, [
      "restart",
      sanitizedModelId
    ])

    return NextResponse.json({
      status: "success",
      target: "local",
      active_model: sanitizedModelId,
      output: stdout || stderr
    })
  } catch (error: any) {
    return NextResponse.json(
      {
        status: "error",
        message:
          error.message || "Falha ao carregar o modelo na VRAM do servidor"
      },
      { status: 500 }
    )
  }
}
