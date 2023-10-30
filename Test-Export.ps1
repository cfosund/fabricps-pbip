$currentPath = (Split-Path $MyInvocation.MyCommand.Definition -Parent)

Set-Location $currentPath

Import-Module ".\FabricPS-PBIP" -Force

# Set-FabricAuthToken -reset

$workspaceId = "c45c04b0-4fe8-4566-bc78-0f768872aeaf"

Export-FabricItems -workspaceId $workspaceId -path '.\export'
