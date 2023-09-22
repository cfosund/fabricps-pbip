$currentPath = (Split-Path $MyInvocation.MyCommand.Definition -Parent)

Set-Location $currentPath

Import-Module ".\FabricPS-PBIP.psm1" -Force

# https://msit.powerbi.com/groups/d020f53d-eb41-421d-af50-8279882524f3

$workspaceId = "d020f53d-eb41-421d-af50-8279882524f3"
$newTheme = "$currentPath\Theme_dark.json"
$exportFolder = "$currentPath\exportThemeSwap"

Export-FabricItems -workspaceId $workspaceId -path $exportFolder -itemTypes @("report")

$themeFiles = Get-ChildItem  -Path $exportFolder -recurse |? {
    $_.FullName -like "*StaticResources\RegisteredResources\*.json"
}

#Swap theme file

foreach($themeFile in $themeFiles)
{
    Write-Host "Changing theme: '$themeFile'"

    $newThemeContent = Get-Content $newTheme

    $newThemeContent | Out-File $themeFile -Force
}

Import-FabricItems -workspaceId $workspaceId -path $exportFolder

