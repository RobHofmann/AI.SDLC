#requires -Version 7.4

Describe 'Get-BicepFacts' {
    BeforeAll {
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Get-BicepFacts.ps1'

        function New-BicepRepo {
            param([hashtable]$Files)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('bfacts-' + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'aisdlc.json') -Value '{}'
            foreach ($rel in $Files.Keys) {
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
                Set-Content -LiteralPath $full -Value $Files[$rel] -Encoding utf8
            }
            return $root
        }

        $script:Arm = @'
{
  "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
  "languageVersion": "2.0",
  "parameters": {
    "location": { "type": "string", "defaultValue": "westeurope", "metadata": { "description": "Where the hub goes." } },
    "hubName": { "type": "string" }
  },
  "resources": {
    "rg": { "type": "Microsoft.Resources/resourceGroups", "apiVersion": "2024-03-01" },
    "old": { "type": "Microsoft.Network/virtualWans", "apiVersion": "2023-04-01", "existing": true },
    "hub": {
      "type": "Microsoft.Resources/deployments", "apiVersion": "2022-09-01",
      "properties": { "template": { "resources": [
        { "type": "Microsoft.Network/virtualHubs", "apiVersion": "2023-04-01" },
        { "type": "Microsoft.Network/virtualHubs", "apiVersion": "2023-04-01" }
      ] } }
    }
  },
  "outputs": { "hubId": { "type": "string", "metadata": { "description": "The resource id of the hub." } } }
}
'@
        $arm = $script:Arm
        $script:ArmBuilder = { param($Path) $arm }.GetNewClosure()
        $script:Source = @"
targetScope = 'subscription'
@description('Where the hub goes.')
param location string = 'westeurope'
param hubName string
module hub './modules/hub.bicep' = { name: 'hub' }
"@
    }

    AfterAll {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'bfacts-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reads the scope, the parameters, the outputs and the resource types from the compiled template' {
        $root = New-BicepRepo -Files @{ 'building-blocks/vwan/main.bicep' = $script:Source }

        $facts = & $script:ScriptUnderTest -Unit 'building-blocks/vwan' -RepoRoot $root -Builder $script:ArmBuilder
        $text = $facts -join "`n"

        $text | Should -Match 'TEMPLATE: building-blocks/vwan/main.bicep \(scope: subscription; read from the compiled template\)'
        $text | Should -Match 'param location: string, has a default - Where the hub goes\.'
        $text | Should -Match 'param hubName: string, required'
        $text | Should -Match 'output hubId: string - The resource id of the hub\.'
        $text | Should -Match 'deploys Microsoft.Network/virtualHubs@2023-04-01 \(x2\)'
        $text | Should -Match 'deploys Microsoft.Resources/resourceGroups@2024-03-01'
    }

    It 'names the user-defined type of a parameter, which the compiled template holds as a reference' {
        $root = New-BicepRepo -Files @{ 'building-blocks/auto/main.bicep' = "param vars AutomationVariables`n" }
        $typed = '{ "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#", "languageVersion": "2.0", "definitions": { "AutomationVariables": { "type": "array" } }, "parameters": { "vars": { "$ref": "#/definitions/AutomationVariables" } }, "resources": {} }'
        $builder = { param($Path) $typed }.GetNewClosure()

        $text = (& $script:ScriptUnderTest -Unit 'building-blocks/auto' -RepoRoot $root -Builder $builder) -join "`n"

        $text | Should -Match 'param vars: AutomationVariables, required'
    }

    It 'leaves out a resource the template only reads, and the nested deployment itself' {
        $root = New-BicepRepo -Files @{ 'building-blocks/vwan/main.bicep' = $script:Source }

        $text = (& $script:ScriptUnderTest -Unit 'building-blocks/vwan' -RepoRoot $root -Builder $script:ArmBuilder) -join "`n"

        $text | Should -Not -Match 'virtualWans'
        $text | Should -Not -Match 'deploys Microsoft.Resources/deployments'
    }

    It 'names the modules a template calls, read from the Bicep source' {
        $root = New-BicepRepo -Files @{ 'building-blocks/vwan/main.bicep' = $script:Source }

        $text = (& $script:ScriptUnderTest -Unit 'building-blocks/vwan' -RepoRoot $root -Builder $script:ArmBuilder) -join "`n"

        $text | Should -Match 'calls module ./modules/hub.bicep'
    }

    It 'reads a template that does not build from its source, and says so' {
        $root = New-BicepRepo -Files @{ 'building-blocks/vwan/main.bicep' = $script:Source + "`nresource r 'Microsoft.Network/virtualWans@2023-04-01' = {}`noutput id string = r.id`n" }

        $text = (& $script:ScriptUnderTest -Unit 'building-blocks/vwan' -RepoRoot $root -Builder { param($Path) $null }) -join "`n"

        $text | Should -Match 'scope: subscription; read from source \(it did not build here\)'
        $text | Should -Match 'param location: string, has a default - Where the hub goes\.'
        $text | Should -Match 'deploys Microsoft.Network/virtualWans@2023-04-01'
        $text | Should -Match 'output id: string'
    }

    It 'lists the other files of the unit, with the synopsis of a PowerShell script' {
        $root = New-BicepRepo -Files @{
            'building-blocks/runbooks/start-vm.ps1' = "<#`n.SYNOPSIS`n    Starts the tagged virtual machines.`n#>`n"
            'building-blocks/runbooks/config.xml'   = '<x/>'
        }

        $text = (& $script:ScriptUnderTest -Unit 'building-blocks/runbooks' -RepoRoot $root -Builder { param($Path) $null }) -join "`n"

        $text | Should -Match 'building-blocks/runbooks/start-vm.ps1 - Starts the tagged virtual machines\.'
        $text | Should -Match 'building-blocks/runbooks/config.xml'
    }

    It 'returns one object per template with -AsObject' {
        $root = New-BicepRepo -Files @{ 'building-blocks/vwan/main.bicep' = $script:Source }

        $objects = @(& $script:ScriptUnderTest -Unit 'building-blocks/vwan' -RepoRoot $root -AsObject -Builder $script:ArmBuilder)

        $objects.Count | Should -Be 1
        $objects[0].Scope | Should -Be 'subscription'
        $objects[0].Parameters.Name | Should -Be @('hubName', 'location')
    }

    It 'refuses a unit that does not exist' {
        $root = New-BicepRepo -Files @{ 'building-blocks/vwan/main.bicep' = $script:Source }

        { & $script:ScriptUnderTest -Unit 'building-blocks/gone' -RepoRoot $root -Builder { param($Path) $null } } | Should -Throw '*does not exist*'
    }

    It 'refuses a unit that resolves outside the repository' {
        $root = New-BicepRepo -Files @{ 'building-blocks/vwan/main.bicep' = $script:Source }
        $outside = New-BicepRepo -Files @{ 'x/main.bicep' = $script:Source }

        { & $script:ScriptUnderTest -Unit ("../" + (Split-Path $outside -Leaf) + "/x") -RepoRoot $root -Builder { param($Path) $null } } | Should -Throw '*outside the repository*'
    }
}
