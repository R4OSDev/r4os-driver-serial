param()
$ErrorActionPreference='Stop'
$arguments=@($args)
$builder=Join-Path $PSScriptRoot '../../SDK/Tools/BuildModule.ps1'
& $builder -ModuleRoot $PSScriptRoot -BuildArguments $arguments
exit $LASTEXITCODE
