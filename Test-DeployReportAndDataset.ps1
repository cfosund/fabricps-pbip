$currentPath = (Split-Path $MyInvocation.MyCommand.Definition -Parent)

Set-Location $currentPath

Import-Module ".\FabricPS-PBIP.psm1" -Force

$workspaceName = "RR - PlatformAPIs - Temp"
$datasetName = "Sales"
$reportName = "Sales"
$pbipDatasetPath = "$currentPath\SamplePBIP\Sales.Dataset"
$pbipReportPath = "$currentPath\SamplePBIP\Sales.Report"

# Ensure workspace

$workspaceId = New-FabricWorkspace  -name $workspaceName -skipErrorIfExists

# Deploy Dataset

$fileDatasetOverrides = @{    
    "item.metadata.json" = @{
        "type" = "dataset"
        "displayName" = $datasetName
    } | ConvertTo-Json
}

$datasetId = Import-FabricItems -workspaceId $workspaceId -path $pbipDatasetPath -fileOverrides $fileDatasetOverrides

# Deploy Report

$fileReportOverrides = @{
    
    # Change the connected dataset

    "definition.pbir" = @{
        "version" = "1.0"
        "datasetReference" = @{          
            "byConnection" =  @{
            "connectionString" = "Data Source=\""powerbi://api.powerbi.com/v1.0/myorg/$workspaceName\"";Initial Catalog=$datasetName;Integrated Security=ClaimsToken"                
            "pbiServiceModelId" = $null
            "pbiModelVirtualServerName" = "sobe_wowvirtualserver"
            "pbiModelDatabaseName" = "$datasetId"                
            "name" = "EntityDataSource"
            "connectionType" = "pbiServiceXmlaStyleLive"
            }
        }
    } | ConvertTo-Json

    # Change logo

    "_7abfc6c7-1a23-4b5f-bd8b-8dc472366284171093267.jpg" = [System.IO.File]::ReadAllBytes("$currentPath\sample-resources\logo2.jpg")

    # Change theme
    "Light4437032645752863.json" = [System.IO.File]::ReadAllBytes("$currentPath\sample-resources\theme_dark.json")

    # Report Name

    "item.metadata.json" = @{
            "type" = "report"
            "displayName" = $reportName
        } | ConvertTo-Json
}

$reportId = Import-FabricItems -workspaceId $workspaceId -path $pbipReportPath -fileOverrides $fileReportOverrides






