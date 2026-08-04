import { NextResponse } from "next/server"
import { execFile } from "child_process"
import { promisify } from "util"

const execFileAsync = promisify(execFile)

export async function GET(request: Request) {
  try {
    const { searchParams } = new URL(request.url)
    const target = searchParams.get("target") || "windows"

    let activeLoadedModel = "desconhecido"
    let serverOnline = false

    const serverUrl =
      target === "windows"
        ? "http://192.168.3.51:8080/v1/models"
        : "http://127.0.0.1:8080/v1/models"

    try {
      const res = await fetch(serverUrl, { signal: AbortSignal.timeout(3000) })
      if (res.ok) {
        const data = await res.json()
        const activeItem = data?.data?.[0] || data?.models?.[0]
        if (activeItem) {
          activeLoadedModel =
            activeItem.id || activeItem.name || activeItem.model || "carregado"
          serverOnline = true
        }
      }
    } catch {
      serverOnline = false
    }

    let progressInfo: any = { status: "idle" }

    if (target === "windows") {
      try {
        const winCmd = `powershell -Command "Get-ChildItem $env:LOCALAPPDATA\\llm-server\\models -Filter '*.gguf' -ErrorAction SilentlyContinue | Select-Object Name, Length"`
        const { stdout } = await execFileAsync("ssh", ["windows", winCmd])
        progressInfo = {
          status: "ready",
          files_on_server: stdout.trim()
        }
      } catch (e: any) {
        progressInfo = { status: "error", error: e.message }
      }
    }

    return NextResponse.json({
      status: "success",
      server_online: serverOnline,
      active_loaded_model: activeLoadedModel,
      progress: progressInfo
    })
  } catch (error: any) {
    return NextResponse.json(
      {
        status: "error",
        message: error.message || "Falha ao obter status dos modelos"
      },
      { status: 500 }
    )
  }
}
