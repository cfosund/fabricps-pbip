#Requires -Modules Az.Accounts

function Get-Token
{
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

    Write-Output $fabricHeaders
}

Function Export-FabricItems 
{
    [CmdletBinding()]
    param
    (
        [string]$baseUrl = "https://api.fabric.microsoft.com/v1"
        ,
        [string]$path = '.\pbipOutput'
        ,
        [string]$workspaceId = 'd020f53d-eb41-421d-af50-8279882524f3'
        ,
        $itemTypes = @("report", "dataset")
	)
   
    $fabricHeaders = Get-Token

    $workspaceitemsUri = "{0}/workspaces/{1}/items" -f $baseUrl, $workspaceId

    $items = Invoke-RestMethod -Uri $workspaceitemsUri -Method Get -Headers $fabricHeaders

    if ($itemTypes)
    {
        $items = $items |? { $itemTypes -contains $_.type }
    }

    Write-Host "Existing items: $($items.Count)"

    foreach($item in $items)
    {
        $itemId = $item.objectId
        $itemName = $item.displayName
        $itemType = $item.type
        $itemOutputPath = "$path\$workspaceId\$($itemName).$($itemType)"

        if ($itemType -in @("report", "dataset"))
        {
            Write-Host "Getting definition of: $itemId"

            #POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items/{itemId}/getDefinition

            $response = $null
            $response = Invoke-RestMethod -Uri "$baseUrl/workspaces/$workspaceId/items/$itemId/getDefinition" -Method Post -Headers $fabricHeaders

            Write-Host "Parts: $($response.definition.parts.Count)"

            foreach($part in $response.definition.parts)
            {
                Write-Host "Saving part: $($part.path)"

                #$outputFilePath = "$outputPath\$workspaceId\$itemId\$($part.path.Replace("/", "\"))"
                $outputFilePath = "$itemOutputPath\$($part.path.Replace("/", "\"))"

                New-Item -ItemType Directory -Path (Split-Path $outputFilePath -Parent) -ErrorAction SilentlyContinue | Out-Null

                $bytes = [Convert]::FromBase64String($part.payload)

                [IO.File]::WriteAllBytes($outputFilePath, $bytes)
            }

            @{
                "type" = $itemType
                "displayName" = $itemName

            } | ConvertTo-Json | Out-File "$itemOutputPath\item.metadata.json"
        }
        else {
            Write-Host "Type '$itemType' not available for export."
        }
    }
}


Function Import-FabricItems 
{
    [CmdletBinding()]
    param
    (
        [string]$baseUrl = "https://api.fabric.microsoft.com/v1"
        ,
        [string]$path = '.\pbipOutput'
        ,
        [string]$workspaceId = 'd020f53d-eb41-421d-af50-8279882524f3'
        ,
        [string]$filter = $null
	)
   
    $fabricHeaders = Get-Token

    # Search for folders with .pbir and .pbidataset in it

    $itemsFolders = Get-ChildItem  -Path $path -recurse -include *.pbir,*.pbidataset

    if ($filter)
    {
        $itemsFolders = $itemsFolders |? {$_.Directory.FullName -like $filter}
    }

    # Get existing items of the workspace

    $items = Invoke-RestMethod -Uri ("{0}/workspaces/{1}/items" -f $baseUrl, $workspaceId) -Method Get -Headers $fabricHeaders

    Write-Host "Existing items: $($items.Count)"

    foreach($itemFolder in $itemsFolders)
    {	
        # Get the parent folder
        
        $itemPath = $itemFolder.Directory.FullName

        write-host "Processing item: '$itemPath'"

        $files = Get-ChildItem -Path $itemPath -Recurse -Attributes !Directory

        # Remove files not required for the API: item.*.json; cache.abf; .pbi folder

        $files = $files |? {$_.Name -notlike "item.*.json" -and $_.Name -notlike "*.abf" -and $_.Directory.Name -notlike ".pbi" }

        # There must be a item.metadata.json in the item folder containing the item type and displayname, necessary for the item creation

        $itemMetadata = Get-Content "$itemPath\item.metadata.json" | ConvertFrom-Json
        
        $itemType = $itemMetadata.type
        $displayName = $itemMetadata.displayName
        $itemId = $null
        # Check if there is already an item with same displayName and type
        
        $foundItem = $items |? {$_.type -ieq $itemType -and $_.displayName -ieq $displayName}

        if ($foundItem)
        {
            Write-Host "Item '$displayName' of type '$itemType' already exists." -ForegroundColor Yellow

            $itemId = $foundItem.objectId
        }

        $itemPathAbs = Resolve-Path $itemPath

        $parts = $files |% {
            
            $filePath = $_.FullName

            $partPath = $filePath.Replace($itemPathAbs,"").TrimStart("\").Replace("\","/")

            if ($filePath -like "*.pbir")
            {          
                # TODO: Resolve byPath folder; find dataset with same displayName; build the byCOnnection JSON

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
    }

}

Function Remove-FabricItems 
{
    [CmdletBinding()]
    param
    (
        [string]$baseUrl = "https://api.fabric.microsoft.com/v1"
        ,
        [string]$workspaceId = $null
        ,
        [string]$filter = $null
	)
   
    $items = Invoke-RestMethod -Uri ("{0}/workspaces/{1}/items" -f $baseUrl, $workspaceId) -Method Get -Headers $fabricHeaders

    Write-Host "Existing items: $($items.Count)"

    if ($filter)
    {
        $items = $items |? {$_.DisplayName -like $filter}
    }

    foreach($item in $items)
    {
        $itemId = $item.objectId
        $itemName = $item.displayName

        Write-Host "Removing item '$itemName' ($itemId)"
        
        Invoke-RestMethod -Uri ("{0}/workspaces/{1}/items/{2}" -f $baseUrl, $workspaceId, $itemId) -Method Delete -Headers $fabricHeaders
    }
    
}