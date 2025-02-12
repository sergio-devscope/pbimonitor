#Requires -Modules MicrosoftPowerBIMgmt.Profile

param(               
    [psobject]$config
    ,
    [string]$stateFilePath     
)

try {
    Write-Host "Starting Power BI Report Fetch"

    $stopwatch = [System.Diagnostics.Stopwatch]::new()
    $stopwatch.Start()   

    if ($config.ActivityFileBatchSize)
    {
        $outputBatchCount = $config.ActivityFileBatchSize
    }
    else {
        $outputBatchCount = 5000   
    }    

    $rootOutputPath = "$($config.OutputPath)\Reports"
    New-Item -ItemType Directory -Path $rootOutputPath -ErrorAction SilentlyContinue | Out-Null

    $outputPath = "$rootOutputPath\{0:yyyy}\{0:MM}"    
    
    if (!$stateFilePath) {
        $stateFilePath = "$($config.OutputPath)\state.json"
    }

    if (Test-Path $stateFilePath) {
        $state = Get-Content $stateFilePath | ConvertFrom-Json
    }
    else {
        $state = New-Object psobject 
    }
    

    if ($state.Reports.LastRun) {
        if (!($state.Reports.LastRun -is [datetime])) {
            $state.Reports.LastRun = [datetime]::Parse($state.Reports.LastRun).ToUniversalTime()
        }
        $pivotDate = $state.Reports.LastRun
    }
    else {
        $state | Add-Member -NotePropertyName "Reports" -NotePropertyValue @{"LastRun" = $null } -Force
    }
    
    Write-Host "Since: $($pivotDate.ToString("s"))"
    Write-Host "OutputBatchCount: $outputBatchCount"
    $pivotDate = [datetime]::UtcNow.Date
    Write-Host "Getting OAuth Token"

    if ($config.ServicePrincipal.AppId)
    {
        $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $config.ServicePrincipal.AppId, ($config.ServicePrincipal.AppSecret | ConvertTo-SecureString -AsPlainText -Force)

        $pbiAccount = Connect-PowerBIServiceAccount -ServicePrincipal -Tenant $config.ServicePrincipal.TenantId -Credential $credential -Environment $config.ServicePrincipal.Environment
    }
    else {
        $pbiAccount = Connect-PowerBIServiceAccount
    }

    Write-Host "Login with: $($pbiAccount.UserName)"
    
    # Gets audit data for each day

    while ($pivotDate -le [datetime]::UtcNow) {           
        Write-Host "Getting audit data for: '$($pivotDate.ToString("yyyyMMdd"))'"        
            
        $reportsAPIUrl = "admin/reports"

        $audits = @()                  
        $pageIndex = 1
        $flagNoActivity = $true

        do
        {          
            if (!$result.continuationUri)
            {
                $result = Invoke-PowerBIRestMethod -Url $reportsAPIUrl -method Get | ConvertFrom-Json
                Write-Host "Resultado1: '$result'" 
            }
            else {
                $result = Invoke-PowerBIRestMethod -Url $result.continuationUri -method Get | ConvertFrom-Json
            }            
                                
            if ($result.value)
            {
                $audits += @($result.value)               
            }
            Write-Host "result.reportsEntities: '$($result.value.id)'" 
            Write-Host "audits.Count: '$($audits.Count)'"   
            Write-Host "outputBatchCount: '$outputBatchCount'" 
            Write-Host "result.continuationToken: '$($result.continuationToken)'" 
            if ($audits.Count -ne 0 -and ($audits.Count -ge $outputBatchCount -or $null -eq $result.continuationToken))
            {
                # To avoid duplicate data on existing files, first dont append pageindex to overwrite existing full file

                if ($pageIndex -eq 1)
                {
                    $outputFilePath = ("$outputPath\{0:yyyyMMdd}.json" -f $pivotDate)                        
                }
                else {
                    $outputFilePath = ("$outputPath\{0:yyyyMMdd}_$pageIndex.json" -f $pivotDate)
                }  
                
                Write-Host "Writing '$($audits.Count)' audits"

                New-Item -Path (Split-Path $outputFilePath -Parent) -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    
                ConvertTo-Json @($audits) -Compress -Depth 10 | Out-File $outputFilePath -force

                if ($config.StorageAccountConnStr -and (Test-Path $outputFilePath)) {
                    Write-Host "Writing to Blob Storage"
                    
                    $storageRootPath = "$($config.StorageAccountContainerRootPath)/reports"
        
                    Add-FileToBlobStorage -storageAccountConnStr $config.StorageAccountConnStr -storageContainerName $config.StorageAccountContainerName -storageRootPath $storageRootPath -filePath $outputFilePath -rootFolderPath $rootOutputPath         

                    Write-Host "Deleting local file '$outputFilePath'"

                    Remove-Item $outputFilePath -Force
                }
                
                $flagNoActivity = $false

                $pageIndex++

                $audits = @()
            }
        }
        while($null -ne $result.continuationToken)

        if ($flagNoActivity)
        {
            Write-Warning "No audit logs for date: '$($pivotDate.ToString("yyyyMMdd"))'"
        }    

        $state.Reports.LastRun = $pivotDate.Date.ToString("o")

        $pivotDate = $pivotDate.AddDays(1)

        # Save state 

        Write-Host "Saving state"
        
        New-Item -Path (Split-Path $stateFilePath -Parent) -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        
        ConvertTo-Json $state | Out-File $stateFilePath -force -Encoding utf8        
    }

}
finally {
    $stopwatch.Stop()

    Write-Host "Ellapsed: $($stopwatch.Elapsed.TotalSeconds)s"
}