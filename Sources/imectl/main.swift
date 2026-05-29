import Darwin
import IMECore

let args = Array(CommandLine.arguments.dropFirst())
let output = DaemonRouting.run(args)

switch output.stream {
case .out:
    fputs(output.text + "\n", stdout)
case .err:
    fputs(output.text + "\n", stderr)
}
exit(output.code)
