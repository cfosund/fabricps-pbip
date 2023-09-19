$currentPath = (Split-Path $MyInvocation.MyCommand.Definition -Parent)

Set-Location $currentPath

Import-Module ".\FabricPS-PBIP.psm1" -Force

# https://msit.powerbi.com/groups/cdfc383c-5eaa-4f39-91de-0eb26fdd2401

$workspaceId = "d020f53d-eb41-421d-af50-8279882524f3"

Export-FabricItems -workspaceId $workspaceId -outputPath '.\output'