<#
    Compat - turns the 5.1 parse promise in the file headers into a test.

    THE FAILURE THIS EXISTS FOR
      scripts\*.ps1 and hooks\*.ps1 are invoked by the Claude Code hook through
      powershell.exe, which is Windows PowerShell 5.1. install.ps1 and
      bootstrap.ps1 are worse: they check $PSVersionTable and print a friendly
      "you need PowerShell 7" message, but a parse error happens before the
      first line runs, so 7-only syntax anywhere in the file turns that message
      into a ParserError stack trace. The gate cannot fire in a file that will
      not parse.

      Every one of those files says "no ternary, no ??, no && / ||" in its
      header. Until now that was a comment, and a comment does not fail a build.

    WHY THE AST AND NOT A REGEX
      Three of the guarded files MENTION ?? and && and || in prose, explaining
      why they avoid them - scripts\Test-Setup.ps1 line 10,
      scripts\zj-claude-project.ps1 line 13, install.ps1 line 97. A regex over
      the file text fails on that documentation, so the obvious test is one that
      is red on a clean repo and gets deleted within the week. The parser is the
      only thing that reliably tells an operator from a sentence about an
      operator, so this walks the AST instead. There is a test below asserting
      those prose mentions still exist, so that reasoning stays checkable.

    WHY THE PARSER HERE CANNOT BE THE JUDGE ON ITS OWN
      Parser::ParseFile running under pwsh 7 uses the 7 grammar, so `??` parses
      perfectly happily and reports zero errors. Zero parse errors under 7 is
      therefore necessary and nowhere near sufficient - hence the separate
      structural check for 7-only nodes, and, where a real Windows PowerShell
      is on the box, an actual 5.1 parse in a child process.

    Confirmed against PowerShell 7.6.4 and Windows PowerShell 5.1.26100,
    Pester 6.1.0.
#>

# Discovery scope on purpose. Pester 5/6 expands -ForEach and evaluates -Skip
# while discovering, before any BeforeAll has run, so these have to be settled
# out here rather than in setup.
$RepoRoot = Split-Path -Parent $PSScriptRoot

$Ps51Sources = @()
$Ps51Sources += Get-ChildItem -Path (Join-Path $RepoRoot 'scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue
$Ps51Sources += Get-ChildItem -Path (Join-Path $RepoRoot 'hooks') -Filter '*.ps1' -File -ErrorAction SilentlyContinue
$Ps51Sources += Get-Item -Path (Join-Path $RepoRoot 'install.ps1') -ErrorAction SilentlyContinue
$Ps51Sources += Get-Item -Path (Join-Path $RepoRoot 'bootstrap.ps1') -ErrorAction SilentlyContinue

$Ps51Cases = @($Ps51Sources | ForEach-Object {
        @{
            Name = [System.IO.Path]::GetFileName($_.FullName)
            Path = $_.FullName
        }
    })

# The module targets pwsh 7 (PowerShellVersion 7.0 in the manifest), so 7-only
# syntax is allowed there. It still has to parse, because a syntax error in one
# dot-sourced file takes the whole module - and every command - with it.
$ModuleSources = @(Get-ChildItem -Path (Join-Path $RepoRoot 'module') -Include '*.ps1', '*.psm1' -File -Recurse -ErrorAction SilentlyContinue)
$ModuleCases = @($ModuleSources | ForEach-Object {
        @{
            Name = $_.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
            Path = $_.FullName
        }
    })

# Windows PowerShell is not present on a Linux runner, and this suite has to be
# green there. Resolved at discovery so -Skip can use it.
$WindowsPowerShell = $null
if ($IsWindows) {
    $WindowsPowerShell = (Get-Command 'powershell.exe' -ErrorAction SilentlyContinue).Source
}
$NoWindowsPowerShell = [string]::IsNullOrEmpty($WindowsPowerShell)

# The bridge from discovery to run. Pester keeps the two in separate scopes, so
# a plain $RepoRoot read inside an It is $null - which showed up here as
# "Cannot bind argument to parameter 'Path' because it is null" rather than as
# anything resembling a scope problem. A hashtable handed to -ForEach on the
# Describe injects its keys as run-time variables, so the lists are built once
# and both passes see the same ones.
$Shared = @{
    RepoRoot    = $RepoRoot
    Ps51Cases   = $Ps51Cases
    ModuleCases = $ModuleCases
}

BeforeAll {
    function Get-ZtParseError {
        <#
            Parse a file and hand back the errors. Wraps the [ref] dance so the
            tests read as assertions rather than as interop.
        #>
        param([Parameter(Mandatory = $true)][string]$Path)

        $errors = $null
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        return @($errors)
    }

    function Get-ZtPs7OnlyNode {
        <#
            Every AST node that Windows PowerShell 5.1 has no grammar for.

              ternary        $a ? $b : $c        TernaryExpressionAst
              && and ||      a && b              PipelineChainAst - NOT a binary
                                                 expression, which is the trap:
                                                 looking for BinaryExpressionAst
                                                 alone silently misses both.
              ??             $a ?? $b            BinaryExpressionAst, QuestionQuestion
              ??=            $a ??= $b           AssignmentStatementAst, QuestionQuestionEquals
              ?. and ?[      ${a}?.b             Member/IndexExpressionAst.NullConditional

            Nothing here matches a comment or a string: the parser has already
            turned those into comment tokens and string literals by the time
            FindAll walks the tree, which is the entire reason this is not a
            regex.
        #>
        param([Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast)

        return @($Ast.FindAll({
                    param($node)
                    if ($node -is [System.Management.Automation.Language.TernaryExpressionAst]) { return $true }
                    if ($node -is [System.Management.Automation.Language.PipelineChainAst]) { return $true }
                    if ($node -is [System.Management.Automation.Language.BinaryExpressionAst]) {
                        return ($node.Operator -eq [System.Management.Automation.Language.TokenKind]::QuestionQuestion)
                    }
                    if ($node -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                        return ($node.Operator -eq [System.Management.Automation.Language.TokenKind]::QuestionQuestionEquals)
                    }
                    if ($node -is [System.Management.Automation.Language.MemberExpressionAst] -or
                        $node -is [System.Management.Automation.Language.IndexExpressionAst]) {
                        return [bool]$node.NullConditional
                    }
                    return $false
                }, $true))
    }

    function Get-ZtPs7OnlyInFile {
        param([Parameter(Mandatory = $true)][string]$Path)

        $errors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if (-not $ast) { return @() }
        return (Get-ZtPs7OnlyNode -Ast $ast)
    }

    function Get-ZtPs7OnlyInText {
        param([Parameter(Mandatory = $true)][string]$Text)

        $errors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
        return (Get-ZtPs7OnlyNode -Ast $ast)
    }

    function Format-ZtNode {
        # Failure messages have to name the line, or you get "expected 0, was 1"
        # and a file of two thousand lines to search.
        param($Nodes)

        # $null piped into ForEach-Object runs the body ONCE with $_ = $null, so
        # the happy path - no findings - was the one that threw "you cannot call
        # a method on a null-valued expression", from inside the -Because that
        # was only ever meant to explain a failure. Bail out before the pipe.
        $items = @($Nodes | Where-Object { $null -ne $_ })
        if ($items.Count -eq 0) { return '(none)' }

        return (($items | ForEach-Object {
                    'line {0}: {1} -> {2}' -f $_.Extent.StartLineNumber, $_.GetType().Name, $_.Extent.Text
                }) -join '; ')
    }
}

Describe 'The Windows PowerShell 5.1 parse contract' -ForEach $Shared {

    Context 'The set of files under the contract' {

        It 'is not empty, and holds the two files whose version gate depends on it' {
            # A glob that quietly matches nothing would make every test below
            # pass without reading a byte, which is the worst outcome available.
            $names = @($Ps51Cases | ForEach-Object { $_.Name })
            $names | Should -Contain 'install.ps1'
            $names | Should -Contain 'bootstrap.ps1'
            $names | Should -Contain 'claude-zj-hook.ps1'
            $names.Count | Should -BeGreaterOrEqual 6
        }

        It 'covers every .ps1 in scripts\ and hooks\, so a new one cannot slip in unguarded' {
            $expected = @()
            $expected += Get-ChildItem -Path (Join-Path $RepoRoot 'scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue
            $expected += Get-ChildItem -Path (Join-Path $RepoRoot 'hooks') -Filter '*.ps1' -File -ErrorAction SilentlyContinue
            $covered = @($Ps51Cases | ForEach-Object { $_.Path })
            foreach ($file in $expected) {
                $covered | Should -Contain $file.FullName
            }
        }
    }

    Context 'Parses at all' {

        It '<Name> parses with no errors' -ForEach $Ps51Cases {
            $errors = Get-ZtParseError -Path $Path
            $detail = ($errors | ForEach-Object { 'line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Message }) -join '; '
            $errors.Count | Should -Be 0 -Because "$Name must parse; $detail"
        }
    }

    Context 'Uses no PowerShell 7-only syntax' {

        It '<Name> has no ternary, ??, ??=, &&, ||, ?. or ?[' -ForEach $Ps51Cases {
            $nodes = @(Get-ZtPs7OnlyInFile -Path $Path)
            $nodes.Count | Should -Be 0 -Because "$Name is invoked by, or version-gates for, Windows PowerShell 5.1: $(Format-ZtNode $nodes)"
        }

        It 'still needs to be an AST test, because the guarded files discuss these operators in prose' {
            # If this ever goes red the prose has been reworded, and the
            # justification at the top of this file needs rewriting with it.
            # It is here so the reasoning cannot rot silently.
            $mentioning = @($Ps51Cases | Where-Object {
                    (Get-Content -LiteralPath $_.Path -Raw) -match '\?\?|&&|\|\|'
                })
            $mentioning.Count | Should -BeGreaterThan 0 -Because 'a text search for these operators matches documentation that avoids them'
        }
    }
}

Describe 'The 7-only detector itself' {

    # Without these, a detector that returned nothing at all would sail through
    # every test above and report a clean repo forever.

    Context 'Fires on real 7-only syntax' {

        It 'catches <Label>' -ForEach @(
            @{ Label = 'a ternary'; Code = '$x = $true ? 1 : 2' }
            @{ Label = 'the null coalescing operator'; Code = '$x = $null ?? 5' }
            @{ Label = 'null coalescing assignment'; Code = '$x = $null; $x ??= 5' }
            @{ Label = 'the && pipeline chain'; Code = 'Get-Date && Get-Date' }
            @{ Label = 'the || pipeline chain'; Code = 'Get-Date || Get-Date' }
            @{ Label = 'null conditional member access'; Code = '${x}?.Length' }
            @{ Label = 'null conditional indexing'; Code = '${x}?[0]' }
        ) {
            (Get-ZtPs7OnlyInText -Text $Code).Count | Should -BeGreaterThan 0
        }
    }

    Context 'Does not fire on documentation' {

        It 'ignores the operators when they appear in a comment' {
            $code = "# Compatible with Windows PowerShell 5.1 - no ternary, no ??, no && / ||.`r`n`$x = 5"
            (Get-ZtPs7OnlyInText -Text $code).Count | Should -Be 0
        }

        It 'ignores the operators when they appear in a string' {
            $code = "`$msg = 'use ?? or && here and 5.1 will not parse it'"
            (Get-ZtPs7OnlyInText -Text $code).Count | Should -Be 0
        }

        It 'ignores a variable whose name merely ends in a question mark' {
            # $x?.Length is NOT null-conditional access: ? is legal in a variable
            # name, so this is $x? followed by .Length and 5.1 parses it fine.
            # Only the ${x}?.Length form is the 7-only operator.
            (Get-ZtPs7OnlyInText -Text '$x?.Length').Count | Should -Be 0
        }
    }

    Context 'Rests on properties that actually exist' {

        It 'finds NullConditional on <Type>' -ForEach @(
            @{ Type = 'MemberExpressionAst' }
            @{ Type = 'IndexExpressionAst' }
        ) {
            # PowerShell returns $null for a property that is not there rather
            # than throwing, so a renamed or absent property would turn the
            # ?. check into a silent no-op instead of a failure.
            $astType = [type]"System.Management.Automation.Language.$Type"
            $astType.GetProperty('NullConditional') | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'A real Windows PowerShell 5.1' -Skip:$NoWindowsPowerShell -ForEach $Shared {

    # The parser above is the 7 parser and will forgive 7 syntax. When a genuine
    # 5.1 is on the machine there is no need to reason about grammars at all -
    # ask it. Skipped where powershell.exe does not exist, so the suite stays
    # green on a Linux runner.

    BeforeAll {
        $script:Wps = (Get-Command 'powershell.exe' -ErrorAction SilentlyContinue).Source

        # Handed a directory rather than a file list: quoting an array of paths
        # across a process boundary is one more thing to get wrong, and 5.1 can
        # glob perfectly well on its own.
        $script:ProbePath = Join-Path $TestDrive 'parse-under-51.ps1'
        Set-Content -LiteralPath $script:ProbePath -Encoding UTF8 -Value @'
param([string]$Root)
$files = @()
$files += Get-ChildItem -Path (Join-Path $Root 'scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue
$files += Get-ChildItem -Path (Join-Path $Root 'hooks') -Filter '*.ps1' -File -ErrorAction SilentlyContinue
$files += Get-Item -Path (Join-Path $Root 'install.ps1') -ErrorAction SilentlyContinue
$files += Get-Item -Path (Join-Path $Root 'bootstrap.ps1') -ErrorAction SilentlyContinue
"COUNT=$($files.Count)"
foreach ($f in $files) {
    $errors = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) {
        "FAIL=$($f.Name) line $($e.Extent.StartLineNumber): $($e.Message)"
    }
}
'@
    }

    It 'is really Windows PowerShell 5' {
        $reported = & $script:Wps -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.Major'
        [int]$reported | Should -Be 5
    }

    It 'parses every guarded file without error' {
        $output = @(& $script:Wps -NoProfile -NonInteractive -File $script:ProbePath -Root $RepoRoot)
        $count = @($output | Where-Object { $_ -like 'COUNT=*' })
        $count.Count | Should -Be 1 -Because 'the probe must have run and reported'
        [int]($count[0] -replace 'COUNT=', '') | Should -Be $Ps51Cases.Count -Because '5.1 must have found the same files this suite guards'

        $failures = @($output | Where-Object { $_ -like 'FAIL=*' })
        $failures.Count | Should -Be 0 -Because ($failures -join '; ')
    }

    It 'rejects a file using ??, which is what makes the test above mean something' {
        # A 5.1 that parsed everything would give a green suite for the wrong
        # reason. Prove it still says no to the syntax we are keeping out.
        $bad = Join-Path $TestDrive 'coalescing.ps1'
        Set-Content -LiteralPath $bad -Encoding UTF8 -Value '$x = $null ?? 5'
        $command = '$e = $null; $t = $null; [void][System.Management.Automation.Language.Parser]::ParseFile(' +
        "'$bad'" + ', [ref]$t, [ref]$e); $e.Count'
        $errorCount = & $script:Wps -NoProfile -NonInteractive -Command $command
        [int]$errorCount | Should -BeGreaterThan 0
    }
}

Describe 'The module source' -ForEach $Shared {

    Context 'The set of module files' {

        It 'is not empty and includes the root .psm1' {
            $names = @($ModuleCases | ForEach-Object { [System.IO.Path]::GetFileName($_.Path) })
            $names | Should -Contain 'ZellijTerminal.psm1'
            $names | Should -Contain 'Core.ps1'
            $names.Count | Should -BeGreaterOrEqual 5
        }
    }

    Context 'Parses' {

        It '<Name> parses with no errors' -ForEach $ModuleCases {
            # No 7-only check here: the manifest declares PowerShellVersion 7.0
            # and CompatiblePSEditions Core, so ?? and && are fair game in the
            # module. Only the scripts the 5.1 hook runs are constrained.
            $errors = Get-ZtParseError -Path $Path
            $detail = ($errors | ForEach-Object { 'line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Message }) -join '; '
            $errors.Count | Should -Be 0 -Because "a parse error here takes the whole module down; $detail"
        }
    }
}
