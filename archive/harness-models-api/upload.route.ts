import { NextResponse } from "next/server"
import { writeFile, mkdir } from "fs/promises"
import path from "path"
import os from "os"
import { execFile } from "child_process"
import { promisify } from "util"

const execFileAsync = promisify(execFile)

export async function POST(request: Request) {
  try {
    const formData = await request.formData()
    const file = formData.get("file") as File | null

    if (!file) {
      return NextResponse.json(
        { status: "error", message: "Nenhum arquivo enviado." },
        { status: 400 }
      )
    }

    const uploadDir = path.resolve(
      os.homedir(),
      ".local/state/llm-server/uploads"
    )
    await mkdir(uploadDir, { recursive: true })

    // Sanitização estrita do nome do arquivo (evita Directory Traversal)
    const baseName = path.basename(file.name)
    const sanitizeFilename = baseName
      .replace(/\.\.+/g, ".")
      .replace(/[^a-zA-Z0-9_.-]/g, "_")

    const filePath = path.resolve(uploadDir, sanitizeFilename)

    // Garantia estrita de que o caminho final permanece dentro de uploadDir
    if (!filePath.startsWith(uploadDir + path.sep) && filePath !== uploadDir) {
      return NextResponse.json(
        {
          status: "error",
          message:
            "Nome de arquivo inválido (Tentativa de Directory Traversal detectada)."
        },
        { status: 400 }
      )
    }

    const arrayBuffer = await file.arrayBuffer()
    const buffer = Buffer.from(arrayBuffer)

    await writeFile(filePath, buffer)

    // Invocação segura usando execFile (sem passar por interpolação de shell)
    const scriptPath = path.resolve(
      process.cwd(),
      "../macos/llm-server.command"
    )
    let importOutput = ""
    try {
      const { stdout } = await execFileAsync(scriptPath, ["import", filePath])
      importOutput = stdout
    } catch (e: any) {
      importOutput = e.message || "Falha ao registrar import automaticamente."
    }

    return NextResponse.json({
      status: "success",
      filename: sanitizeFilename,
      path: filePath,
      size_bytes: file.size,
      import_output: importOutput
    })
  } catch (error: any) {
    return NextResponse.json(
      {
        status: "error",
        message: error.message || "Falha ao realizar upload do modelo"
      },
      { status: 500 }
    )
  }
}
