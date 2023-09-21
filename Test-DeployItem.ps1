#Requires -Modules Az.Accounts

$ErrorActionPreference = "Stop"
$currentPath = (Split-Path $MyInvocation.MyCommand.Definition -Parent)

Set-Location $currentPath

# https://msit.powerbi.com/groups/cdfc383c-5eaa-4f39-91de-0eb26fdd2401

$baseUrl = "https://api.fabric.microsoft.com/v1"
$itemPath = "$currentPath\SamplePBIP\Sales.Report"
$workspaceId = "cdfc383c-5eaa-4f39-91de-0eb26fdd2401"

if (!(Get-AzContext))
{
    Connect-AzAccount
}
else
{
    Write-Host "Already connnected: $((Get-AzContext).Account)"
}

$fabricToken = (Get-AzAccessToken -ResourceUrl "https://analysis.windows.net/powerbi/api").Token

$fabricHeaders = @{
    'Content-Type' = "application/json"
    'Authorization' = "Bearer {0}" -f $fabricToken
}

# Get items to figure out the id of the item

$items = Invoke-RestMethod -Uri ("{0}/workspaces/{1}/items" -f $baseUrl, $workspaceId) -Method Get -Headers $fabricHeaders

Write-Host "Existing items: $($items.Count)"

$files = Get-ChildItem -Path $itemPath -Recurse -Attributes !Directory

# Remove files not required for the API: item.*.json; cache.abf; .pbi folder

$files = $files |? {$_.Name -notlike "item.*.json" -and $_.Name -notlike "*.abf" -and $_.Directory.Name -notlike ".pbi" }

# There must be a item.metadata.json in the item folder containing the item type and displayname, necessary for the item creation

$itemMetadata = Get-Content "$itemPath\item.metadata.json" | ConvertFrom-Json

$itemType = $itemMetadata.type
$displayName = $itemMetadata.displayName
$itemId = $null

$foundItem = $items |? {$_.type -ieq $itemType -and $_.displayName -ieq $displayName}

if ($foundItem)
{
    Write-Host "Item '$displayName' of type '$itemType' already exists." -ForegroundColor Yellow

    $itemId = $foundItem.objectId
}

$itemPathAbs = Resolve-Path $itemPath

# build the 'parts' payload

$parts = $files |% {
    
    $filePath = $_.FullName

    $partPath = $filePath.Replace($itemPathAbs,"").TrimStart("\").Replace("\","/")

    if ($filePath -like "*.pbir")
    {          
        $pbirJson = Get-Content -Path $filePath | ConvertFrom-Json

        if ($pbirJson.datasetReference.byPath -and $pbirJson.datasetReference.byPath.path)
        {
            throw "Item API dont support byPath connection, switch to byConnection"
        }
    }

    $fileContent = Get-Content -Path $filePath -AsByteStream -Raw

    $fileEncodedContent = [Convert]::ToBase64String($fileContent)
    
    Write-Output @{
                Path = $partPath
                Payload = $fileEncodedContent
                PayloadType = "InlineBase64"
            }				
}

if ($itemId -eq $null)
{
    write-host "Creating a new item"

    # Prepare the request

    $itemRequest = @{ 
        displayName = $displayName
        type = $itemType    
        definition = @{
            Parts = $parts
        }
    } | ConvertTo-Json -Depth 3		

    $createItemResult = Invoke-RestMethod -Uri ("{0}/workspaces/{1}/items" -f $baseUrl, $workspaceId) -Method Post -Headers $fabricHeaders -Body $itemRequest

    $itemId = $createItemResult.objectId

    write-host "Created a new item with ID '$itemId' $([datetime]::Now.ToString("s"))" -ForegroundColor Green
}
else
{
    write-host "Updating item definition"

    $itemRequest = @{ 
        definition = @{
            Parts = $parts
        }			
    } | ConvertTo-Json -Depth 3		

    $updateItemResult = Invoke-RestMethod -Uri ("{0}/workspaces/{1}/items/{2}/updateDefinition" -f $baseUrl, $workspaceId, $itemId) -Method Post -Headers $fabricHeaders -Body $itemRequest

    write-host "Updated new item with ID '$itemId' $([datetime]::Now.ToString("s"))" -ForegroundColor Green
}