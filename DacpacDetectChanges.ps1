<# now before you run this script, you need to set all these variables to something meaningful for your system. #>
# needed if you use SQL Server authentication
# A data-tier application (DAC) supports the most commonly used Database Engine objects.
$DefaultUserName = 'BobDoe'; # the default name for any SQL Server Authentication
#this will be where you put all the sourcecode for all the databases
$PathToScripts = 'MyPath' # base of config management file structure
#the list of all the databases you DONT want to process
$DatabaseExclusionList = ('master', 'model', 'msdb', 'tempdb') # any databases we don't want
#The list of all the servers you don't want to do
#$ServerExclusionList 
$ServerExclusionList=('') # any servers we don't want
#you may use a different language.
$messagePrompt = 'Please can we have the username and password for' #

Trap
{
	# Handle the error
	$err = $_.Exception
	write-error $err.Message
	while ($err.InnerException)
	{
		$err = $err.InnerException
		write-error $err.Message
	};
	# End the script.
	break
}

set-psdebug -strict
$ErrorActionPreference = "stop" #
$VerbosePreference='Continue' #"SilentlyContinue"

If (!(Test-Path SQLSERVER:)) { Import-Module “sqlps” -DisableNameChecking }
If (!(Test-Path SQLSERVER:)) { throw "Cannot load SQLPS" }
# load the SQLPS module if it isn't already loaded.
add-type -path "C:\Program Files (x86)\Microsoft SQL Server\110\DAC\bin\Microsoft.SqlServer.Dac.dll"
#actually, it inly does so if necessary

If (!(Test-Path $PathToScripts))
{
	$null = New-Item -ItemType Directory -Force -path $PathToScripts #maybe create path
};
#now we get all the servers/instances out of the database server group
#in a working system this would probably be a server list from the CMS
 get-childitem 'SQLSERVER:\sqlregistration' -recurse|where {$_.GetType() -notlike '*ServerGroup*'} |
   Select servername, connectionstring, @{Name="Server";Expression={$_}} |
     sort-object -property servername -unique |
      foreach-object {
	#for each server, we make a connection
	#we need this to get the list of databases to do
    $sqlConnection = new-object System.Data.SqlClient.SqlConnection($_.connectionstring)
    $conn = new-object Microsoft.SqlServer.Management.Common.ServerConnection($sqlConnection)
	#if this was windows authentication, then the connection is actually made
	#there is an SMO 'GetConnectionObject' method on the objects returned by
	#get-childitem, but I haven't figured out how to use it AND make servername
	#unique
    
	if ($conn.TrueName -eq $null) #then the automatic connection wasn't made
	{
		#if so we require a SQL Server login.
		$theCredentials = Get-Credential -UserName "$DefaultUserName" -Message "$messagePrompt $($_.servername)"
		if ($TheCredentials -ne $null)
		{
			#unless he cancelled
			$conn = new-object Microsoft.SqlServer.Management.Common.ServerConnection ($_.ServerName, $theCredentials.UserName, $theCredentials.password)
		}
	}
    $srv = new-object Microsoft.SqlServer.Management.Smo.Server($conn)
	$TrueServerName = $conn.truename #this will be null if the connection still hasn't been made
    #"The Server name $TrueServerName is  $($srv.Name)"
	if ($TrueServerName -ne $null -and $ServerExclusionList -notcontains $TrueServerName)
	#if we definitely have a connection and it is a server we really want to 'sourcify'
	{
		$DacServices = new-object Microsoft.SqlServer.Dac.DacServices $srv.connectionContext.ConnectionString
        $ReportProgress= register-objectevent -in $DacServices -eventname Message -source "msg" -action {Out-Host -in $Event.SourceArgs[1].Message.Message }
		$InstancePath = "$PathToScripts\$($TrueServerName -replace '[\\\/\:\.]', '-')\"
		# we put it in a directory using the true server name
		$srv.databases.name | Where-Object { $DatabaseExclusionList -notcontains $_ } |
		#don't use any database that is in the exclusion list
		foreach-object {
			# for each database,  barring exclusions
			$DatabasePath = "$($InstancePath)$($_ -replace '[\\\/\:\.]', '-')" #make a legal pathname
			$DatabaseName = $_ # $_ is a bit fleeting so remember it!
			# place them in directories under each server
			#each database has its own directory.
            write-verbose "Accessing $TrueServerName.$DatabaseName"
			if (-not (Test-Path $DatabasePath)) #if the directory isn't there make it
			{ $null = New-Item -ItemType Directory -Force -path $DatabasePath } #create path if it doesn't exist
			# Specify the DAC metadata.
			#FileName,database Name,application Name,Version,application Description, tables, DacExtractOptions, cancellationToken
			if (-not (Test-Path "$DatabasePath\$databaseName.dacpac")) #if the DACPAC isn't there write it
			{
   			    "Writing initial dacpac for $DatabaseName to $DatabasePath\$databaseName.dacpac at $(Get-Date -Format F)" >>"$($DatabasePath).log" #write to the log
				$DacServices.extract("$DatabasePath\$databaseName.dacpac", $DatabaseName, "$DatabaseName", "1.2.3.4")
			}
			else # is it the latest?
			{
                $DeployOptions= new-object Microsoft.SqlServer.Dac.DacDeployOptions 
                $DeployOptions.IgnoreWithNocheckOnCheckConstraints=$true #and whatever other knobs you want to tweak
                $ExistingPackage = [Microsoft.SqlServer.Dac.DacPackage]::Load("$DatabasePath\$databaseName.dacpac")

                $XML=[xml]$DacServices.GenerateDeployReport($ExistingPackage, "$DatabaseName" ,$DeployOptions,$null)
                if ($XML.DeploymentReport.Operations -eq $null) 
                    {"No drift detected for $DatabaseName on $(Get-Date -Format F)" >>"$($DatabasePath).log"}
                else
                    {
                    <# here you do your alerting such as sending email with the report #>
                    "Drift was detected for $DatabaseName on $(Get-Date -Format F)" >>"$($DatabasePath).log"
                    #move what was there into a directory with the date in its name
                    $now=Get-Date -Format dddMMMYY-Hmm #get the date
                    if (-not (Test-Path $DatabasePath\$now)) #if the directory isn't there make it
			            { $null = New-Item -ItemType Directory -Force -path $DatabasePath\$now }
                    Move-Item "$($DatabasePath)\*.*" "$DatabasePath\$now" #archive everything
                    $XML.Save("$DatabasePath\$DatabaseName-drift.xml") #Save the deploy report
                    #and now we write out the new dacpac
   			        "Writing new dacpac for $DatabaseName to $DatabasePath\$databaseName.dacpac at $(Get-Date -Format F)" >>"$($DatabasePath).log" #write to the log
				    $DacServices.extract("$DatabasePath\$databaseName.dacpac", $DatabaseName, "$DatabaseName", "1.2.3.4")
                    
                }
            }
 		}
        UnRegister-event $ReportProgress.Name #unregister the event you set up	
   }
}

 
 