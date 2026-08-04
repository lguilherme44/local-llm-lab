import { NextResponse } from "next/server"
import { execFile } from "child_process"
import { promisify } from "util"
import path from "path"

const execFileAsync = promisify(execFile)

export async function GET() {
  try {
    const scriptPath = path.resolve(
      process.cwd(),
      "../macos/llm-server.command"
    )
    const { stdout } = await execFileAsync(scriptPath, ["models"])

    return NextResponse.json({
      status: "success",
      output: stdout
    })
  } catch (error: any) {
    return NextResponse.json(
      { status: "error", message: error.message || "Failed to list models" },
      { status: 500 }
    )
  }
}
