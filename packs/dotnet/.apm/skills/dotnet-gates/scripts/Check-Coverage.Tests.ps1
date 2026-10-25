#requires -Version 7.4

Describe 'Check-Coverage' {
    BeforeAll {
        $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' 'ai-sdlc-gates' 'scripts'
        if (-not (Test-Path -LiteralPath $aiSdlcGates)) { $aiSdlcGates = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' '..' 'core' '.apm' 'skills' 'ai-sdlc-gates' 'scripts' }
        Import-Module (Join-Path $aiSdlcGates 'DocToolTestHarness.psm1') -Force
        $script:ScriptUnderTest = Join-Path -Path $PSScriptRoot -ChildPath 'Check-Coverage.ps1'

        function Invoke-Gate {
            param([hashtable]$GateArgs)
            $out = & $script:ScriptUnderTest @GateArgs *>&1 | Out-String
            return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        }

        function New-OpenCoverReport {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][int]$NumSequencePoints,
                [Parameter(Mandatory)][int]$VisitedSequencePoints
            )
            $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<CoverageSession>
  <Summary numSequencePoints="$NumSequencePoints" visitedSequencePoints="$VisitedSequencePoints" />
  <Modules>
    <Module>
      <ModuleName>Shared.StockLevel</ModuleName>
      <Summary numSequencePoints="$NumSequencePoints" visitedSequencePoints="$VisitedSequencePoints" />
    </Module>
  </Modules>
</CoverageSession>
"@
            Set-Content -LiteralPath $Path -Value $xml -Encoding utf8
        }

        function New-OpenCoverReportRaw {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$Xml
            )
            Set-Content -LiteralPath $Path -Value $Xml -Encoding utf8
        }

        function New-DotnetCoverageReport {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][int]$LinesCovered,
                [Parameter(Mandatory)][int]$LinesPartiallyCovered,
                [Parameter(Mandatory)][int]$LinesNotCovered
            )
            $total = $LinesCovered + $LinesPartiallyCovered + $LinesNotCovered
            $lineCoverage = if ($total -gt 0) { [math]::Round($LinesCovered / $total * 100, 2) } else { 0 }
            $xml = @"
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<results>
  <modules>
    <module name="Shared.StockLevel.Tests.dll" line_coverage="$lineCoverage" lines_covered="$LinesCovered" lines_partially_covered="$LinesPartiallyCovered" lines_not_covered="$LinesNotCovered" />
  </modules>
</results>
"@
            Set-Content -LiteralPath $Path -Value $xml -Encoding utf8
        }

        function New-BaselineFile {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$Body
            )
            Set-Content -LiteralPath $Path -Value $Body -Encoding utf8
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-AiSdlcTestConfig -Root $script:Root
        $script:CoverageFile = Join-Path -Path $script:Root -ChildPath 'coverage.opencover.xml'
        $script:BaselineFile = Join-Path -Path $script:Root -ChildPath 'coverage-baseline.json'
    }

    Context 'OpenCover format' {
        It 'passes when coverage meets the baseline (exit 0)' {
            New-OpenCoverReport -Path $script:CoverageFile -NumSequencePoints 100 -VisitedSequencePoints 95
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 80 }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'C04 OK'
        }

        It 'fails when coverage is below the baseline (exit 1)' {
            New-OpenCoverReport -Path $script:CoverageFile -NumSequencePoints 100 -VisitedSequencePoints 40
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 80 }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'C04 coverage gate FAILED'
        }

        It 'fails when overall coverage is unreadable because numSequencePoints is zero (exit 1)' {
            $xml = @'
<?xml version="1.0" encoding="utf-8"?>
<CoverageSession>
  <Summary numSequencePoints="0" visitedSequencePoints="0" />
  <Modules>
    <Module>
      <ModuleName>Shared.StockLevel</ModuleName>
      <Summary numSequencePoints="0" visitedSequencePoints="0" />
    </Module>
  </Modules>
</CoverageSession>
'@
            New-OpenCoverReportRaw -Path $script:CoverageFile -Xml $xml
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 80 }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'could not read overall line coverage'
        }

        It 'passes using the sequenceCoverage fallback when count attributes are absent (exit 0)' {
            $xml = @'
<?xml version="1.0" encoding="utf-8"?>
<CoverageSession>
  <Summary sequenceCoverage="91.5" />
  <Modules>
    <Module>
      <ModuleName>Shared.StockLevel</ModuleName>
      <Summary sequenceCoverage="91.5" />
    </Module>
  </Modules>
</CoverageSession>
'@
            New-OpenCoverReportRaw -Path $script:CoverageFile -Xml $xml
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 80 }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'C04 OK'
        }

        It 'renders n/a for a module whose summary is unreadable while overall is readable (exit 0)' {
            $xml = @'
<?xml version="1.0" encoding="utf-8"?>
<CoverageSession>
  <Summary numSequencePoints="100" visitedSequencePoints="95" />
  <Modules>
    <Module>
      <ModuleName>Shared.StockLevel</ModuleName>
      <Summary numSequencePoints="0" visitedSequencePoints="0" />
    </Module>
  </Modules>
</CoverageSession>
'@
            New-OpenCoverReportRaw -Path $script:CoverageFile -Xml $xml
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 80 }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'n/a'
            $result.Output | Should -Match 'C04 OK'
        }
    }

    Context 'dotnet-coverage XML format' {
        It 'passes when coverage meets the baseline (exit 0)' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 95 -LinesPartiallyCovered 0 -LinesNotCovered 5
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 80 }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'C04 OK'
        }

        It 'fails when coverage is below the baseline (exit 1)' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 40 -LinesPartiallyCovered 0 -LinesNotCovered 60
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 80 }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'C04 coverage gate FAILED'
        }

        It 'partially covered lines do not count as covered when computing overall coverage (exit 1)' {
            # 50 covered + 30 partial + 20 not = 50/100 = 50%, below 80%
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 50 -LinesPartiallyCovered 30 -LinesNotCovered 20
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 80 }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'C04 coverage gate FAILED'
        }

        It 'fails when no lines are recorded across all modules (exit 1)' {
            $xml = @'
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<results>
  <modules>
    <module name="Shared.StockLevel.Tests.dll" line_coverage="0" lines_covered="0" lines_partially_covered="0" lines_not_covered="0" />
  </modules>
</results>
'@
            New-OpenCoverReportRaw -Path $script:CoverageFile -Xml $xml
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 80 }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'no lines recorded'
        }

        It 'aggregates coverage correctly across multiple modules (exit 0)' {
            $xml = @'
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<results>
  <modules>
    <module name="Shared.StockLevel.dll" line_coverage="100.00" lines_covered="50" lines_partially_covered="0" lines_not_covered="0" />
    <module name="Shared.Demo.dll" line_coverage="70.00" lines_covered="70" lines_partially_covered="0" lines_not_covered="30" />
  </modules>
</results>
'@
            New-OpenCoverReportRaw -Path $script:CoverageFile -Xml $xml
            # overall: (50+70) / (50+0+0 + 70+0+30) = 120/150 = 80%
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 80 }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'C04 OK'
        }

        It 'fails when a module has malformed line-count attributes (exit 1)' {
            $xml = @'
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<results>
  <modules>
    <module name="Shared.StockLevel.dll" line_coverage="100.00" lines_covered="NOT_A_NUMBER" lines_partially_covered="0" lines_not_covered="0" />
  </modules>
</results>
'@
            New-OpenCoverReportRaw -Path $script:CoverageFile -Xml $xml
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 80 }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'malformed line-count attributes'
        }
    }

    Context 'the ratchet' {
        It 'passes when coverage sits exactly on the baseline' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 42 -LinesPartiallyCovered 0 -LinesNotCovered 58
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 42 }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'holds the 42\.00% baseline'
        }

        It 'passes and asks for the baseline to be raised when coverage beats it' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 55 -LinesPartiallyCovered 0 -LinesNotCovered 45
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 42 }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Ratchet it up'
            $result.Output | Should -Match 'set lineCoveragePercent to 55\.00'
        }

        It 'passes when the drop is inside the tolerance' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 4190 -LinesPartiallyCovered 0 -LinesNotCovered 5810
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 42; Tolerance = 0.25 }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'C04 OK'
        }

        It 'fails when the drop is outside the tolerance' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 4100 -LinesPartiallyCovered 0 -LinesNotCovered 5900
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 42; Tolerance = 0.25 }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'dropped below the 42\.00% baseline'
        }

        It 'reports the distance to the ambition without gating on it' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 42 -LinesPartiallyCovered 0 -LinesNotCovered 58
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 42; Target = 80 }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Distance to the 80\.00% ambition: 38\.00 points'
            $result.Output | Should -Match 'gated by SonarCloud on new code'
        }
    }

    Context 'the baseline file' {
        It 'reads the baseline from the file when no explicit baseline is given' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 42 -LinesPartiallyCovered 0 -LinesNotCovered 58
            New-BaselineFile -Path $script:BaselineFile -Body '{ "lineCoveragePercent": 42, "recordedOn": "2026-09-02" }'
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; BaselineFile = $script:BaselineFile }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'recorded 2026-09-02'
            $result.Output | Should -Match 'C04 OK'
        }

        It 'fails against a baseline read from the file when coverage has dropped' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 30 -LinesPartiallyCovered 0 -LinesNotCovered 70
            New-BaselineFile -Path $script:BaselineFile -Body '{ "lineCoveragePercent": 42, "recordedOn": "2026-09-02" }'
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; BaselineFile = $script:BaselineFile }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'C04 coverage gate FAILED'
        }

        It 'fails closed when the baseline file is missing' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 95 -LinesPartiallyCovered 0 -LinesNotCovered 5
            $absent = Join-Path $script:Root 'no-baseline-here.json'
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; BaselineFile = $absent }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'baseline file not found'
            $result.Output | Should -Match 'fails closed'
        }

        It 'fails closed when the baseline file has no numeric lineCoveragePercent' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 95 -LinesPartiallyCovered 0 -LinesNotCovered 5
            New-BaselineFile -Path $script:BaselineFile -Body '{ "lineCoveragePercent": "not a number" }'
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; BaselineFile = $script:BaselineFile }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'no numeric lineCoveragePercent property'
        }

        It 'fails closed when the baseline file is not valid JSON' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 95 -LinesPartiallyCovered 0 -LinesNotCovered 5
            New-BaselineFile -Path $script:BaselineFile -Body 'this is not json'
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; BaselineFile = $script:BaselineFile }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'failed to parse'
        }

        It 'falls back to the repository default path and fails closed when nothing is there' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 95 -LinesPartiallyCovered 0 -LinesNotCovered 5
            Set-AiSdlcTestConfig -Root $script:Root
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; RepoRoot = $script:Root }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'coverage-baseline\.json'
            $result.Output | Should -Match 'baseline file not found'
        }
    }

    Context 'culture independence' {
        It 'writes percentages with a dot under a comma-decimal culture, so the figure it names is valid JSON' {
            New-DotnetCoverageReport -Path $script:CoverageFile -LinesCovered 4104 -LinesPartiallyCovered 0 -LinesNotCovered 5896
            $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('nl-NL')
                $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 35 }
            }
            finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
            }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'set lineCoveragePercent to 41\.04'
            $result.Output | Should -Not -Match 'lineCoveragePercent to 41,04'
        }
    }

    Context 'format-agnostic' {
        It 'fails when the coverage file is missing (exit 1)' {
            $result = Invoke-Gate -GateArgs @{ CoverageFile = (Join-Path $script:Root 'absent.xml'); Baseline = 80 }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'coverage file not found'
        }

        It 'fails when the report has an unrecognized root element (exit 1)' {
            Set-Content -LiteralPath $script:CoverageFile -Value '<NotCoverage />' -Encoding utf8
            $result = Invoke-Gate -GateArgs @{ CoverageFile = $script:CoverageFile; Baseline = 80 }
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'unrecognized root element'
        }
    }
}
