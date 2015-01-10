﻿properties { 
  $zipFileName = "JsonSchema10r1.zip"
  $majorVersion = "1.0"
  $majorWithReleaseVersion = "1.0.1"
  $version = GetVersion $majorWithReleaseVersion
  $signAssemblies = $false
  $signKeyPath = "C:\Development\Releases\newtonsoft.snk"
  $buildDocumentation = $false
  $buildNuGet = $true
  $treatWarningsAsErrors = $false
  $workingName = if ($workingName) {$workingName} else {"Working"}
  
  $baseDir  = resolve-path ..
  $buildDir = "$baseDir\Build"
  $sourceDir = "$baseDir\Src"
  $toolsDir = "$baseDir\Tools"
  $docDir = "$baseDir\Doc"
  $releaseDir = "$baseDir\Release"
  $workingDir = "$baseDir\$workingName"
  $builds = @(
    @{Name = "Newtonsoft.Json.Schema"; TestsName = "Newtonsoft.Json.Schema.Tests"; TestsFunction = "NUnitTests"; Constants=$null; FinalDir="Net45"; NuGetDir = "net45"; Framework="net-4.0"; Sign=$true},
    @{Name = "Newtonsoft.Json.Schema.Net40"; TestsName = "Newtonsoft.Json.Schema.Net40.Tests"; TestsFunction = "NUnitTests"; Constants="NET40"; FinalDir="Net40"; NuGetDir = "net40"; Framework="net-4.0"; Sign=$true},
    @{Name = "Newtonsoft.Json.Schema.Portable"; TestsName = "Newtonsoft.Json.Schema.Tests.Portable"; TestsFunction = "NUnitTests"; Constants="PORTABLE"; FinalDir="Portable"; NuGetDir = "portable-net45+wp80+win8+wpa81+aspnetcore50"; Framework="net-4.0"; Sign=$true}
  )
}

framework '4.0x86'

task default -depends Test

# Ensure a clean working directory
task Clean {
  Set-Location $baseDir
  
  if (Test-Path -path $workingDir)
  {
    Write-Output "Deleting Working Directory"
    
    del $workingDir -Recurse -Force
  }
  
  New-Item -Path $workingDir -ItemType Directory
}

# Build each solution, optionally signed
task Build -depends Clean { 
  Write-Host -ForegroundColor Green "Updating assembly version"
  Write-Host
  Update-AssemblyInfoFiles $sourceDir ($majorVersion + '.0.0') $version

  foreach ($build in $builds)
  {
    $name = $build.Name
    if ($name -ne $null)
    {
      $finalDir = $build.FinalDir
      $sign = ($build.Sign -and $signAssemblies)

      Write-Host -ForegroundColor Green "Building " $name
      Write-Host -ForegroundColor Green "Signed " $sign

      Write-Host
      Write-Host "Restoring"
      try
      {
        $xmlPath = "$sourceDir\NuGet.Config"
        $xml = [xml](Get-Content $xmlPath)
        $xpath = "/configuration/packageSources/add[@key='Json.NET']/@value"

        $jsonNetPackageSourceOld = $xml.SelectSingleNode($xpath).Value
        $jsonNetPackageSource = if ($sign) { "https://www.myget.org/F/json-net/api/v2" } else { "https://www.myget.org/F/json-net-unsigned/api/v2" }

        Write-Host "Updating Json.NET package source to " $jsonNetPackageSource

        Edit-XmlNodes -doc $xml -xpath $xpath -value $jsonNetPackageSource
        $xml.save($xmlPath)

        exec { .\Tools\NuGet\NuGet.exe restore ".\Src\$name.sln" "-NoCache" | Out-Default } "Error restoring $name"
      }
      finally
      {
        Write-Host "Resetting Json.NET package source back to " $jsonNetPackageSourceOld

        Edit-XmlNodes -doc $xml -xpath $xpath -value $jsonNetPackageSourceOld
        $xml.save($xmlPath)
      }

      Write-Host
      Write-Host "Building"
      exec { msbuild "/t:Clean;Rebuild" /p:Configuration=Release "/p:Platform=Any CPU" /p:OutputPath=bin\Release\$finalDir\ /p:AssemblyOriginatorKeyFile=$signKeyPath "/p:SignAssembly=$sign" "/p:TreatWarningsAsErrors=$treatWarningsAsErrors" "/p:VisualStudioVersion=12.0" (GetConstants $build.Constants $sign) ".\Src\$name.sln" | Out-Default } "Error building $name"
    }
  }
}

# Optional build documentation, add files to final zip
task Package -depends Build {
  foreach ($build in $builds)
  {
    $name = $build.TestsName
    $finalDir = $build.FinalDir
    
    robocopy "$sourceDir\Newtonsoft.Json.Schema\bin\Release\$finalDir" $workingDir\Package\Bin\$finalDir Newtonsoft.Json.Schema.dll Newtonsoft.Json.Schema.pdb Newtonsoft.Json.Schema.xml /NP /XO /XF *.CodeAnalysisLog.xml | Out-Default
  }
  
  if ($buildNuGet)
  {
    New-Item -Path $workingDir\NuGet -ItemType Directory    
    Copy-Item -Path "$buildDir\Newtonsoft.Json.Schema.nuspec" -Destination $workingDir\NuGet\Newtonsoft.Json.Schema.nuspec -recurse

    New-Item -Path $workingDir\NuGet\tools -ItemType Directory
    Copy-Item -Path "$buildDir\install.ps1" -Destination $workingDir\NuGet\tools\install.ps1 -recurse
    
    foreach ($build in $builds)
    {
      if ($build.NuGetDir)
      {
        $name = $build.TestsName
        $finalDir = $build.FinalDir
        $frameworkDirs = $build.NuGetDir.Split(",")
        
        foreach ($frameworkDir in $frameworkDirs)
        {
          robocopy "$sourceDir\Newtonsoft.Json.Schema\bin\Release\$finalDir" $workingDir\NuGet\lib\$frameworkDir Newtonsoft.Json.Schema.dll Newtonsoft.Json.Schema.pdb Newtonsoft.Json.Schema.xml /NP /XO /XF *.CodeAnalysisLog.xml | Out-Default
        }
      }
    }
  
    robocopy $sourceDir $workingDir\NuGet\src *.cs /S /NP /XD Newtonsoft.Json.Schema.Tests Newtonsoft.Json.Schema.TestConsole obj | Out-Default

    exec { .\Tools\NuGet\NuGet.exe pack $workingDir\NuGet\Newtonsoft.Json.Schema.nuspec -Symbols }
    move -Path .\*.nupkg -Destination $workingDir\NuGet
  }
  
  if ($buildDocumentation)
  {
    $mainBuild = $builds | where { $_.Name -eq "Newtonsoft.Json.Schema" } | select -first 1
    $mainBuildFinalDir = $mainBuild.FinalDir
    $documentationSourcePath = "$sourceDir\Newtonsoft.Json.Schema.Tests\bin\Release\$mainBuildFinalDir"
    Write-Host -ForegroundColor Green "Building documentation from $documentationSourcePath"

    # Sandcastle has issues when compiling with .NET 4 MSBuild - http://shfb.codeplex.com/Thread/View.aspx?ThreadId=50652
    exec { msbuild "/t:Clean;Rebuild" /p:Configuration=Release "/p:DocumentationSourcePath=$documentationSourcePath" $docDir\doc.shfbproj | Out-Default } "Error building documentation. Check that you have Sandcastle, Sandcastle Help File Builder and HTML Help Workshop installed."
    
    move -Path $workingDir\Documentation\LastBuild.log -Destination $workingDir\Documentation.log
  }
  
  Copy-Item -Path $docDir\readme.txt -Destination $workingDir\Package\
  Copy-Item -Path $docDir\license.txt -Destination $workingDir\Package\

  # exclude package directories but keep packages\repositories.config
  $packageDirs = gci $sourceDir\packages | where {$_.PsIsContainer} | Select -ExpandProperty Name

  robocopy $sourceDir $workingDir\Package\Source\Src /MIR /NP /XD bin obj TestResults AppPackages $packageDirs /XF *.suo *.user | Out-Default
  robocopy $buildDir $workingDir\Package\Source\Build /MIR /NP /XF runbuild.txt | Out-Default
  robocopy $docDir $workingDir\Package\Source\Doc /MIR /NP | Out-Default
  robocopy $toolsDir $workingDir\Package\Source\Tools /MIR /NP | Out-Default
  
  exec { .\Tools\7-zip\7za.exe a -tzip $workingDir\$zipFileName $workingDir\Package\* | Out-Default } "Error zipping"
}

# Unzip package to a location
task Deploy -depends Package {
  exec { .\Tools\7-zip\7za.exe x -y "-o$workingDir\Deployed" $workingDir\$zipFileName | Out-Default } "Error unzipping"
}

# Run tests on deployed files
task Test -depends Deploy {
  foreach ($build in $builds)
  {
    if ($build.TestsFunction -ne $null)
    {
      & $build.TestsFunction $build
    }
  }
}

function CoreClrTests($build)
{
  $name = $build.TestsName

  Write-Host -ForegroundColor Green "Ensuring latest CoreCLR is installed for $name"
  Write-Host
  exec { & $toolsDir\Kvm\kvm.ps1 upgrade -r CoreCLR -NoNative | Out-Default }

  Write-Host -ForegroundColor Green "Restoring packages for $name"
  Write-Host
  exec { kpm restore "$sourceDir\Newtonsoft.Json.Schema.Tests\project.json" | Out-Default }

  Write-Host -ForegroundColor Green "Ensuring test project builds for $name"
  Write-Host
  try
  {
    Set-Location "$sourceDir\Newtonsoft.Json.Schema.Tests"
    k --configuration Release test -parallel none | Tee-Object -file "$workingDir\$name.txt"
  }
  finally
  {
    Set-Location $baseDir
  }
}

function WinRTTests($build)
{
  $name = $build.TestsName
  $finalDir = $build.FinalDir

  $testCmd = "C:\Program Files (x86)\Microsoft Visual Studio 12.0\Common7\IDE\CommonExtensions\Microsoft\TestWindow\vstest.console.exe"
  $outDir = "$workingDir\Deployed\Bin\$finalDir"

  Write-Host -ForegroundColor Green "Packaging test assembly $name to deployed directory"
  Write-Host
  exec { msbuild "$sourceDir\Newtonsoft.Json.Schema.Tests\$name.csproj" /p:OutDir=$outDir | Out-Default }

  Write-Host -ForegroundColor Green "Running MSTest tests " $name
  Write-Host
  exec { &($testCmd) $outDir\$name\AppPackages\$($name)_1.0.0.0_AnyCPU_Debug_Test\$($name)_1.0.0.0_AnyCPU_Debug.appx /InIsolation | Tee-Object -file "$workingDir\$name.txt" } "Error running $name tests"
}

function NUnitTests($build)
{
  $name = $build.TestsName
  $finalDir = $build.FinalDir
  $framework = $build.Framework

  Write-Host -ForegroundColor Green "Copying test assembly $name to deployed directory"
  Write-Host
  robocopy ".\Src\Newtonsoft.Json.Schema.Tests\bin\Release\$finalDir" $workingDir\Deployed\Bin\$finalDir /MIR /NP /XO | Out-Default

  Copy-Item -Path ".\Src\Newtonsoft.Json.Schema.Tests\bin\Release\$finalDir\Newtonsoft.Json.Schema.Tests.dll" -Destination $workingDir\Deployed\Bin\$finalDir\

  Write-Host -ForegroundColor Green "Running NUnit tests " $name
  Write-Host
  exec { .\Tools\NUnit\nunit-console.exe "$workingDir\Deployed\Bin\$finalDir\Newtonsoft.Json.Schema.Tests.dll" /framework=$framework /xml:$workingDir\$name.xml | Out-Default } "Error running $name tests"
}

function GetConstants($constants, $includeSigned)
{
  $signed = switch($includeSigned) { $true { ";SIGNED" } default { "" } }

  return "/p:DefineConstants=`"CODE_ANALYSIS;TRACE;$constants$signed`""
}

function GetVersion($majorVersion)
{
    $now = [DateTime]::Now
    
    $year = $now.Year - 2000
    $month = $now.Month
    $totalMonthsSince2000 = ($year * 12) + $month
    $day = $now.Day
    $minor = "{0}{1:00}" -f $totalMonthsSince2000, $day
    
    $hour = $now.Hour
    $minute = $now.Minute
    $revision = "{0:00}{1:00}" -f $hour, $minute
    
    return $majorVersion + "." + $minor
}

function Update-AssemblyInfoFiles ([string] $sourceDir, [string] $assemblyVersionNumber, [string] $fileVersionNumber)
{
    $assemblyVersionPattern = 'AssemblyVersion\("[0-9]+(\.([0-9]+|\*)){1,3}"\)'
    $fileVersionPattern = 'AssemblyFileVersion\("[0-9]+(\.([0-9]+|\*)){1,3}"\)'
    $assemblyVersion = 'AssemblyVersion("' + $assemblyVersionNumber + '")';
    $fileVersion = 'AssemblyFileVersion("' + $fileVersionNumber + '")';
    
    Get-ChildItem -Path $sourceDir -r -filter AssemblyInfo.cs | ForEach-Object {
        
        $filename = $_.Directory.ToString() + '\' + $_.Name
        Write-Host $filename
        $filename + ' -> ' + $version
    
        (Get-Content $filename) | ForEach-Object {
            % {$_ -replace $assemblyVersionPattern, $assemblyVersion } |
            % {$_ -replace $fileVersionPattern, $fileVersion }
        } | Set-Content $filename
    }
}

function Edit-XmlNodes {
param (
    [xml] $doc,
    [string] $xpath = $(throw "xpath is a required parameter"),
    [string] $value = $(throw "value is a required parameter")
)
    $nodes = $doc.SelectNodes($xpath)
    
    foreach ($node in $nodes) {
        if ($node -ne $null) {
            if ($node.NodeType -eq "Element") {
                $node.InnerXml = $value
            }
            else {
                $node.Value = $value
            }
        }
    }
}