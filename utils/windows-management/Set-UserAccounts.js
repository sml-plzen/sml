function shellQuote(str) {
	str = str.replace(/(\\*)"/g, "$1$1\\\"")
	str = str.replace(/(\\+)$/, "$1$1")
	str = str.replace(/%/g, "%\"\"")
	return "\"" + str + "\""
}

function getPowerShellScriptName() {
	var fso = new ActiveXObject("Scripting.FileSystemObject")
	var fullName = WScript.ScriptFullName

	return fso.BuildPath(fso.GetParentFolderName(fullName), fso.GetBaseName(fullName) + ".ps1")
}

var commandLine = "PowerShell -Version 2.0 -ExecutionPolicy Bypass -File"
commandLine += " " + shellQuote(getPowerShellScriptName())

var args = WScript.Arguments
for(var i = 0; i < args.length; ++i)
	commandLine += " " + shellQuote(args(i))

new ActiveXObject("WScript.Shell").Run(commandLine, 0, false)
