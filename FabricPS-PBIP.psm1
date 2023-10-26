$script:apiUrl = "https://api.fabric.microsoft.com/v1"
$script:resourceUrl = "https://api.fabric.microsoft.com" 
$script:fabricToken = $null

function Get-FabricAuthToken {
    [CmdletBinding()]
    param
    (
    )

    if (!$script:fabricToken)
    {                
        Set-FabricAuthToken
    }
    
    Write-Output $script:fabricToken
}

function Set-FabricAuthToken {
    [CmdletBinding()]
    param
    (
        [string]$servicePrincipalId        
        ,
        [string]$servicePrincipalSecret
        ,
        [string]$tenantId 
        ,
        [switch]$reset
    )

    if (!$reset)
    {
        $azContext = Get-AzContext
    }

    if (!$azContext) {
        
        Write-Host "Getting authentication token"
        
        if ($servicePrincipalId) {
            $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $servicePrincipalId, ($servicePrincipalSecret | ConvertTo-SecureString -AsPlainText -Force)

            Connect-AzAccount -ServicePrincipal -TenantId $tenantId -Credential $credential

            Set-AzContext -Tenant $tenantId
        }
        else {
            Connect-AzAccount    
        }

        $azContext = Get-AzContext        
    }

    Write-Host "Connnected: $($azContext.Account)"

    $script:fabricToken = (Get-AzAccessToken -ResourceUrl $script:resourceUrl).Token
}

Function Invoke-FabricAPIRequest {
    [CmdletBinding()]		
    param(									
        [Parameter(Mandatory = $false)] [string] $authToken,
        [Parameter(Mandatory = $true)] [string] $uri,
        [Parameter(Mandatory = $false)] [ValidateSet('Get', 'Post', 'Delete', 'Put', 'Patch')] [string] $method = "Get",
        [Parameter(Mandatory = $false)] $body,        
        [Parameter(Mandatory = $false)] [string] $contentType = "application/json; charset=utf-8",
        [Parameter(Mandatory = $false)] [int] $timeoutSec = 240,
        [Parameter(Mandatory = $false)] [string] $outFile
            
    )

    if ([string]::IsNullOrEmpty($authToken)) {
        $authToken = Get-FabricAuthToken
    }	

    $fabricHeaders = @{
        'Content-Type'  = $contentType
        'Authorization' = "Bearer {0}" -f $authToken
    }

    try {
        
        $requestUrl = "$($script:apiUrl)/$uri"

        $response = Invoke-WebRequest -Headers $fabricHeaders -Method $method -Uri $requestUrl -Body $body  -TimeoutSec $timeoutSec -OutFile $outFile

        if ($response.StatusCode -eq 202)
        {
            do
            {                
                $asyncUrl = [string]$response.Headers.Location

                Write-Host "Waiting for request to complete. Sleeping..."

                Start-Sleep -Seconds 10

                $response = Invoke-WebRequest -Headers $fabricHeaders -Method Get -Uri $asyncUrl 

            }
            while($response.StatusCode -eq 202)
            
            $response = Invoke-WebRequest -Headers $fabricHeaders -Method Get -Uri "$asyncUrl/result"
            
        }

        #if ($response.StatusCode -in @(200,201) -and $response.Content)        
        if ($response.Content)
        {            
            $contentBytes = $response.RawContentStream.ToArray()

            # Test for BOM

            if ($contentBytes[0] -eq 0xef -and $contentBytes[1] -eq 0xbb -and $contentBytes[2] -eq 0xbf)
            {
                $contentText = [System.Text.Encoding]::UTF8.GetString($contentBytes[3..$contentBytes.Length])                
            }
            else
            {
                $contentText = $response.Content
            }

            Write-Output $contentText | ConvertFrom-Json -NoEnumerate
        }        
    }
    catch {
        $ex = $_.Exception

        try {
            if ($ex.Response -ne $null) {

                $errorContent = $ex.Response.Content.ReadAsStringAsync().Result;
        
                $message = "$($ex.Message) - StatusCode: '$($ex.Response.StatusCode)'; Content: '$errorContent'"
            }
            else {
                $message = "$($ex.Message)"
            }
            
            #Write-Error -Exception $ex -Message $message

            throw $message
        }
        catch {
            throw;
        }    		
    }

}

Function New-FabricWorkspace {
    [CmdletBinding()]
    param
    (
        [string]$name
        ,
        [switch]$skipErrorIfExists        
    )

    $itemRequest = @{ 
        displayName = $name
    } | ConvertTo-Json

    try {        
        $createResult = Invoke-FabricAPIRequest -Uri ("{0}/workspaces" -f $baseUrl) -Method Post -Body $itemRequest

        Write-Host "Workspace created"

        Write-Output $createResult.id
    }
    catch {
        $ex = $_.Exception

        if ($skipErrorIfExists) {
            if ($ex.Message -ilike "*409*") {
                Write-Host "Workspace already exists"

                $listWorkspaces = Invoke-FabricAPIRequest -Uri ("{0}/workspaces" -f $baseUrl) -Method Get

                $workspace = $listWorkspaces | ? { $_.displayName -ieq $name }

                if (!$workspace) {
                    throw "Cannot find workspace '$name'"
                }
                
                Write-Output $workspace.id
            }
            else {
                throw
            }
        }        
    }
    
}

Function Export-FabricItems {
    [CmdletBinding()]
    param
    (
        [string]$path = '.\pbipOutput'
        ,
        [string]$workspaceId = ''
        ,
        [array]$itemTypes = @("report", "dataset")
    )    

    $items = Invoke-FabricAPIRequest -Uri "workspaces/$workspaceId/items" -Method Get

    if ($itemTypes) {
        $items = $items | ? { $itemTypes -contains $_.type }
    }

    Write-Host "Existing items: $($items.Count)"

    foreach ($item in $items) {
        $itemId = $item.id
        $itemName = $item.displayName
        $itemType = $item.type
        $itemOutputPath = "$path\$workspaceId\$($itemName).$($itemType)"

        if ($itemType -in @("report", "dataset")) {
            Write-Host "Getting definition of: $itemId / $itemName / $itemType"

            #POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items/{itemId}/getDefinition

            $response = $null

            $response = Invoke-FabricAPIRequest -Uri "workspaces/$workspaceId/items/$itemId/getDefinition" -Method Post

            Write-Host "Parts: $($response.definition.parts.Count)"

            foreach ($part in $response.definition.parts) {
                Write-Host "Saving part: $($part.path)"

                #$outputFilePath = "$outputPath\$workspaceId\$itemId\$($part.path.Replace("/", "\"))"
                $outputFilePath = "$itemOutputPath\$($part.path.Replace("/", "\"))"

                New-Item -ItemType Directory -Path (Split-Path $outputFilePath -Parent) -ErrorAction SilentlyContinue | Out-Null

                $bytes = [Convert]::FromBase64String($part.payload)

                [IO.File]::WriteAllBytes($outputFilePath, $bytes)
            }

            @{
                "type"        = $itemType
                "displayName" = $itemName

            } | ConvertTo-Json | Out-File "$itemOutputPath\item.metadata.json"
        }
        else {
            Write-Host "Type '$itemType' not available for export."
        }
    }
}

Function Import-FabricItems {
    [CmdletBinding()]
    param
    (
        [string]$path = '.\pbipOutput'
        ,
        [string]$workspaceId
        ,
        [string]$filter = $null
        ,
        [hashtable] $fileOverrides
    )

    # Search for folders with .pbir and .pbidataset in it

    $itemsFolders = Get-ChildItem  -Path $path -recurse -include *.pbir, *.pbidataset

    if ($filter) {
        $itemsFolders = $itemsFolders | ? { $_.Directory.FullName -like $filter }
    }

    # Get existing items of the workspace

    $items = Invoke-FabricAPIRequest -Uri ("{0}/workspaces/{1}/items" -f $baseUrl, $workspaceId) -Method Get

    Write-Host "Existing items: $($items.Count)"

    # Datasets first 

    $itemsFolders = $itemsFolders | Select-Object  @{n="Order";e={ if ($_.Name -like "*.pbidataset") {1} else {2} }}, * | sort-object Order    

    $datasetReferences = @{}

    foreach ($itemFolder in $itemsFolders) {	
        
        # Get the parent folder

        $itemPath = $itemFolder.Directory.FullName

        write-host "Processing item: '$itemPath'"

        $files = Get-ChildItem -Path $itemPath -Recurse -Attributes !Directory

        # Remove files not required for the API: item.*.json; cache.abf; .pbi folder

        $files = $files | ? { $_.Name -notlike "item.*.json" -and $_.Name -notlike "*.abf" -and $_.Directory.Name -notlike ".pbi" }

        # There must be a item.metadata.json in the item folder containing the item type and displayname, necessary for the item creation

        $itemMetadataStr = Get-Content "$itemPath\item.metadata.json" 
        
        $fileOverrideMatch = $fileOverrides.GetEnumerator() |? { "$itemPath\item.metadata.json" -ilike $_.Name  } | select -First 1

        if ($fileOverrideMatch) {
            $itemMetadataStr = $fileOverrideMatch.Value
        }
        
        $itemMetadata = $itemMetadataStr | ConvertFrom-Json
        $itemType = $itemMetadata.type
        $displayName = $itemMetadata.displayName

        $itemPathAbs = Resolve-Path $itemPath

        $parts = $files | % {
            
            $fileName = $_.Name
            $filePath = $_.FullName   
            
            $fileOverrideMatch = $fileOverrides.GetEnumerator() |? { $filePath -ilike $_.Name  } | select -First 1

            if ($fileOverrideMatch) {
                $fileContent = $fileOverrideMatch.Value

                # convert to byte array

                if ($fileContent -is [string]) {
                    $fileContent = [system.Text.Encoding]::UTF8.GetBytes($fileContent)
                }
                elseif (!($fileContent -is [byte[]])) {
                    throw "FileOverrides value type must be string or byte[]"
                }
            }
            else {                
                if ($filePath -like "*.pbir") {                  
    
                    $pbirJson = Get-Content -Path $filePath | ConvertFrom-Json

                    if ($pbirJson.datasetReference.byPath -and $pbirJson.datasetReference.byPath.path) {

                        # try to swap byPath to byConnection

                        $reportDatasetPath = (Resolve-path (Join-Path $itemPath $pbirJson.datasetReference.byPath.path.Replace("/", "\"))).Path

                        $datasetReference = $datasetReferences[$reportDatasetPath]       
                        
                        if ($datasetReference)
                        {
                            $datasetName = $datasetReference.name
                            $datasetId = $datasetReference.id
                            
                            $newPBIR = @{
                                "version" = "1.0"
                                "datasetReference" = @{          
                                    "byConnection" =  @{
                                    "connectionString" = $null                
                                    "pbiServiceModelId" = $null
                                    "pbiModelVirtualServerName" = "sobe_wowvirtualserver"
                                    "pbiModelDatabaseName" = "$datasetId"                
                                    "name" = "EntityDataSource"
                                    "connectionType" = "pbiServiceXmlaStyleLive"
                                    }
                                }
                            } | ConvertTo-Json
                            
                            $fileContent = [system.Text.Encoding]::UTF8.GetBytes($newPBIR)

                        }
                        else
                        {
                            throw "Item API dont support byPath connection, switch the connection in the *.pbir file to 'byConnection'."
                        }
                    }
                }
                else
                {
                    $fileContent = Get-Content -Path $filePath -AsByteStream -Raw                
                }
            }

            $partPath = $filePath.Replace($itemPathAbs, "").TrimStart("\").Replace("\", "/")

            $fileEncodedContent = [Convert]::ToBase64String($fileContent)
            
            Write-Output @{
                Path        = $partPath
                Payload     = $fileEncodedContent
                PayloadType = "InlineBase64"
            }				
        }

        $itemId = $null

        # Check if there is already an item with same displayName and type
        
        $foundItem = $items | ? { $_.type -ieq $itemType -and $_.displayName -ieq $displayName }

        if ($foundItem) {
            if ($foundItem.Count -gt 1) {
                throw "Found more than one item for displayName '$displayName'"
            }

            Write-Host "Item '$displayName' of type '$itemType' already exists." -ForegroundColor Yellow

            $itemId = $foundItem.id
        }

        if ($itemId -eq $null) {
            write-host "Creating a new item"

            # Prepare the request

            $itemRequest = @{ 
                displayName = $displayName
                type        = $itemType    
                definition  = @{
                    Parts = $parts
                }
            } | ConvertTo-Json -Depth 3		

            $createItemResult = Invoke-FabricAPIRequest -uri "workspaces/$workspaceId/items"  -method Post -body $itemRequest

            $itemId = $createItemResult.id

            write-host "Created a new item with ID '$itemId' $([datetime]::Now.ToString("s"))" -ForegroundColor Green

            Write-Output $itemId
        }
        else {
            write-host "Updating item definition"

            $itemRequest = @{ 
                definition = @{
                    Parts = $parts
                }			
            } | ConvertTo-Json -Depth 3		
            
            Invoke-FabricAPIRequest -Uri "workspaces/$workspaceId/items/$itemId/updateDefinition" -Method Post -Body $itemRequest

            write-host "Updated new item with ID '$itemId' $([datetime]::Now.ToString("s"))" -ForegroundColor Green

            Write-Output $itemId
        }

        # Save dataset references to swap byPath to byConnection

        if ($itemType -ieq "dataset")
        {
            $datasetReferences[$itemPath] = @{"id" = $itemId; "name" = $displayName}
        }
    }

}

Function Remove-FabricItems {
    [CmdletBinding()]
    param
    (
        [string]$workspaceId = $null
        ,
        [string]$filter = $null 
    )
   
    if (!$fabricHeaders) {
        $fabricHeaders = Get-FabricHeaders
    }

    $items = Invoke-FabricAPIRequest -Uri ("{0}/workspaces/{1}/items" -f $baseUrl, $workspaceId) -Method Get

    Write-Host "Existing items: $($items.Count)"

    if ($filter) {
        $items = $items | ? { $_.DisplayName -like $filter }
    }

    foreach ($item in $items) {
        $itemId = $item.id
        $itemName = $item.displayName

        Write-Host "Removing item '$itemName' ($itemId)"
        
        Invoke-FabricAPIRequest -Uri ("{0}/workspaces/{1}/items/{2}" -f $baseUrl, $workspaceId, $itemId) -Method Delete
    }
    
}