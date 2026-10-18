import { Dir } from '@engine/std/io'

export async function main(api) {
  const fs = await api.fs.request({ root: ".", write: true })
  const file = await Dir.cwd().createFile(fs.async, "test")
  const data = Uint8Array.fromHex("68656c6c6f20776f726c64")
  const res = await file.writeStreamingAll(fs.async, data)
}
