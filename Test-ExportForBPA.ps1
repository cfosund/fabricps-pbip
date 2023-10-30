$currentPath = (Split-Path $MyInvocation.MyCommand.Definition -Parent)

Set-Location $currentPath

Import-Module ".\FabricPS-PBIP" -Force

$workspaces = @("c45c04b0-4fe8-4566-bc78-0f768872aeaf", "152bf87a-d715-46cd-bed2-a14d8f2ad72a")
$exportLocation = "$currentPath\export\rules"
$skipWorkspaceExport = $true

# Download tools
                
$tabularEditorPath = "$currentPath\_tools\TE\TabularEditor.exe"
$tabularEditorRulesPath = "$currentPath\_tools\TE\rules.json" 
if (!(Test-Path $tabularEditorPath))
{
    $toolPath = "$currentPath\_tools\TE"
    New-Item -ItemType Directory -Path $toolPath -ErrorAction SilentlyContinue | Out-Null              

    Write-Host "Downloading Tabular Editor binaries"
    $downloadUrl = "https://github.com/TabularEditor/TabularEditor/releases/latest/download/TabularEditor.Portable.zip"
    $zipFile = "$toolPath\TabularEditor.zip"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile
    Expand-Archive -Path $zipFile -DestinationPath $toolPath -Force            

    Write-Host "Downloading Dataset default rules"
    $downloadUrl = "https://raw.githubusercontent.com/microsoft/Analysis-Services/master/BestPracticeRules/BPARules.json"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tabularEditorRulesPath
}

$pbiInspectorPath = "$currentPath\_tools\PBIInspector\win-x64\CLI\PBIXInspectorCLI.exe" 
$pbiInspectorRulesPath = "$currentPath\_tools\PBIInspector\rules.json" 

if (!(Test-Path $pbiInspectorPath))
{        
    $toolPath = "$currentPath\_Tools\PBIInspector"
    New-Item -ItemType Directory -Path $toolPath -ErrorAction SilentlyContinue | Out-Null

    Write-Host "##[debug]Downloading PBI Inspector"
    $downloadUrl = "https://github.com/NatVanG/PBI-Inspector/releases/latest/download/win-x64-CLI.zip" 
    $zipFile = "$toolPath\PBIXInspector.zip"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile
    Expand-Archive -Path $zipFile -DestinationPath $toolPath -Force                            

    Write-Host "##[debug]Downloading Report default rules"
    $downloadUrl = "https://raw.githubusercontent.com/NatVanG/PBI-Inspector/main/Rules/Base-rules.json"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $pbiInspectorRulesPath    
}

# Export Fabric content

if (!$skipWorkspaceExport)
{
    foreach($workspaceId in $workspaces)
    {
        Export-FabricItems -workspaceId $workspaceId -path $exportLocation
    }
}

# Run Rules for each dataset and report and persist output in file

$itemsFolders = Get-ChildItem  -Path $exportLocation -recurse -include *.pbir, *.pbidataset

# Datasets first

$itemsFolders = $itemsFolders | Select-Object  @{n="Order";e={ if ($_.Name -like "*.pbidataset") {1} else {2} }}, * | sort-object Order    

foreach ($itemFolder in $itemsFolders) {	
        
    # Get the parent folder

    $itemFolderPath = $itemFolder.Directory.FullName
    $workspaceId = $itemFolder.Directory.Parent.Name

    $itemMetadata = Get-Content "$itemFolderPath\item.metadata.json" | ConvertFrom-Json

    $itemName = $itemMetadata.displayName
    $itemType = $itemMetadata.type

    Write-Host "Running rules for '$itemFolderPath' ($itemName - $itemType)"

    $toolOutputPath = "$exportLocation\rulesOutput\$($itemType)_$($workspaceId)_$($itemName).txt"
    New-Item -ItemType Directory -Path (Split-Path $toolOutputPath) -ErrorAction SilentlyContinue | Out-Null    

    if ($itemType -ieq "dataset")
    {
        $modelPath = "$itemFolderPath\model.bim"

        Start-Process -FilePath "$tabularEditorPath" -ArgumentList """$modelPath"" -A ""$tabularEditorRulesPath"" -V" -NoNewWindow -Wait -RedirectStandardOutput $toolOutputPath
    }
    elseif ($itemType -ieq "report")
    {
        $reportPath = "$itemFolderPath\report.json"

        Start-Process -FilePath "$pbiInspectorPath" -ArgumentList "-pbipreport ""$reportPath"" -rules ""$pbiInspectorRulesPath"" -formats ""ADO""" -NoNewWindow -Wait -RedirectStandardOutput $toolOutputPath
    }
    else {
        throw "Invalid item type: $itemType"
    }

}