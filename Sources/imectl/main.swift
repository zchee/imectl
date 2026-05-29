import Darwin
import IMECore

let args = Array(CommandLine.arguments.dropFirst())
let output = DaemonRouting.run(args)

let rendered = CLI.render(output)
if let out = rendered.stdout { fputs(out, stdout) }
if let err = rendered.stderr { fputs(err, stderr) }
exit(output.code)
