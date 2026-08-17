# Guards the anonymisation and the unresolved-placeholder class of bug.
#
# The release audit found seven live instances between them: personal
# identifiers left in prose, an unstamped '<you>', and references pointing at
# documents that were renamed or never written. None of these break a build or
# throw at runtime - they only surface once the repo is public and a stranger
# clicks the link, which is far too late to find out.
#
# Everything here is a fact about tracked file CONTENT, so it behaves the same
# on every machine: no Zellij, no session, no PowerToys, no .NET SDK. The only
# external dependency is git, and the suite skips rather than fails when the
# tests are run from something that is not a checkout (an extracted zip, a
# vendored copy inside another repo).
#
# Files are enumerated with 'git ls-files' on purpose. Walking the filesystem
# instead picks up scratch files, half-written notes and other agents'
# work-in-progress, which fails the build for things that were never going to
# be published.
#
# WHERE THIS RUNS, AND WHAT IT THEREFORE SCANS
#   In a clone of the public repository - which is where it matters, and where
#   it is run by somebody deciding whether to trust this - every tracked file is
#   a published file, so 'git ls-files' is exactly the right set.
#
#   In the private repository this is generated from, it is not: that tree also
#   holds files that are deliberately never published, and which name a person
#   and a machine on purpose because that is what they are for. Scanning them
#   would make this suite permanently red there, and a suite that is normally
#   red is a suite nobody reads - which is the same false-signal failure this
#   file exists to prevent, arriving from the other direction.
#
#   So when tools/publish.manifest is present, that allow-list is the scan set:
#   the question being asked is "is everything that will be published clean",
#   and the manifest is the definition of what will be published. The manifest
#   does not exist in a published clone, so there the fallback is what runs.

BeforeDiscovery {
    # -Skip is evaluated during discovery, so the git check has to happen here
    # as well as in BeforeAll. Keep it cheap and side-effect free.
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:HasGit = $false
    if (Get-Command git -ErrorAction SilentlyContinue) {
        & git -C $script:RepoRoot rev-parse --is-inside-work-tree *> $null
        $script:HasGit = ($LASTEXITCODE -eq 0)
    }
}

Describe 'Anonymisation and placeholders' -Skip:(-not $script:HasGit) {

    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot

        # This file necessarily contains the very needles it searches for. Left
        # in the scan set it reports itself, so every assertion below would fail
        # the moment the test was added.
        $script:SelfPath = 'tests/Placeholders.Tests.ps1'

        # Tracked, text-ish, and readable. Binary assets (the Command Palette
        # PNGs) are excluded by extension rather than by sniffing content -
        # Get-Content on a PNG returns mojibake that can match anything.
        $binaryExtensions = @('.png', '.jpg', '.ico', '.wasm', '.dll', '.exe', '.pdf')

        # The publish allow-list when there is one, every tracked file when
        # there is not. See the header for why the two cases differ.
        $manifest = Join-Path $script:RepoRoot 'tools/publish.manifest'
        if (Test-Path -LiteralPath $manifest) {
            $tracked = @(
                Get-Content -LiteralPath $manifest |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { $_ -and -not $_.StartsWith('#') }
            )
        } else {
            $tracked = & git -C $script:RepoRoot ls-files
        }

        $script:TrackedFiles = @(
            $tracked |
                Where-Object { $_ -and $_ -ne $script:SelfPath } |
                Where-Object { [System.IO.Path]::GetExtension($_).ToLowerInvariant() -notin $binaryExtensions }
        )

        # The published set, unfiltered - this file included, binaries included.
        # TrackedFiles answers "what do I scan"; this answers "will the reader
        # have it", which is a different question and the one a reference check
        # needs. $ScanSetIsManifest records which it is: in a published clone
        # there is no manifest, and existing on disk IS being published.
        $script:PublishedSet     = @($tracked | Where-Object { $_ })
        $script:ScanSetIsManifest = (Test-Path -LiteralPath $manifest)

        # Read every file once. The scans below all want the same text, and
        # re-reading per assertion made the suite noticeably slower than the
        # rest of the tests put together.
        $script:FileLines = @{}
        foreach ($relative in $script:TrackedFiles) {
            $full = Join-Path $script:RepoRoot $relative
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $script:FileLines[$relative] = @(Get-Content -LiteralPath $full -ErrorAction SilentlyContinue)
            }
        }

        # Reports a violation the way a person reads it: where it is, then what
        # is wrong with it. Pester prints -Because verbatim, so this ends up
        # being the whole of the failure message.
        function Format-Violation {
            param([string]$File, [int]$LineNumber, [string]$Detail)
            "  $File`:$LineNumber  $Detail"
        }
    }

    Context 'Personal identifiers' {

        It 'no tracked file contains a personal identifier' {
            # Assembled from fragments rather than written out. If the names
            # were literals here, a published repo would still answer "yes" when
            # somebody greps it for them - which is precisely the check this
            # test exists to make pass.
            $needles = @(
                ('juli' + 'an'),
                ('snow' + 'den'),
                ('snow' + 'dej')
            )
            $pattern = '(?i)(' + ($needles -join '|') + ')'

            $violations = foreach ($file in $script:TrackedFiles) {
                $lines = $script:FileLines[$file]
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match $pattern) {
                        Format-Violation -File $file -LineNumber ($i + 1) -Detail "personal identifier '$($Matches[1])'"
                    }
                }
            }
            $violations = @($violations)

            $violations.Count | Should -Be 0 -Because (
                "the repo is anonymised and no personal name may appear in it:`n" +
                ($violations -join "`n"))
        }
    }

    Context 'Unresolved placeholders' {

        # The name deliberately spells the placeholder out in words. Pester
        # treats angle brackets in a test name as -ForEach templating, so a
        # literal <you> in the title is substituted with the value of $you and
        # the test reports itself as "the literal $null" (confirmed on Pester
        # 6.1.0). The needle in the body is unaffected.
        It 'no tracked file contains the unreplaced you placeholder in angle brackets' {
            # '<you>' is what gets typed while drafting and forgotten. It reads
            # as deliberate angle-bracket syntax in a code block, so it survives
            # proofreading in a way that XXX or TODO does not.
            $violations = foreach ($file in $script:TrackedFiles) {
                $lines = $script:FileLines[$file]
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '<you>') {
                        Format-Violation -File $file -LineNumber ($i + 1) -Detail 'unreplaced placeholder <you>'
                    }
                }
            }
            $violations = @($violations)

            $violations.Count | Should -Be 0 -Because (
                "an unreplaced placeholder shipped to a user is a bug:`n" +
                ($violations -join "`n"))
        }
    }

    Context 'Repository owner' {

        BeforeAll {
            # The only three files allowed to name the GitHub owner. Each one
            # needs it for a different reason - the installer clones from it,
            # the README tells you to, and the manifest publishes it as
            # ProjectUri - and tools/Set-RepoOwner.ps1 stamps all three at once.
            # Anywhere else means a fourth place to stamp that nothing updates.
            $script:SanctionedOwnerFiles = @(
                'bootstrap.ps1',
                'README.md',
                'module/ZellijTerminal/ZellijTerminal.psd1',

                # The stamping tool itself, for the same reason this test file
                # is excluded from its own scan: it cannot do its job without
                # naming the token it substitutes. The literal is load-bearing
                # there - it is the search term and the -Revert value, not
                # documentation that could be reworded.
                #
                # Added after a clean install caught it. The tool was untracked
                # while it was being written, and this scan enumerates with
                # `git ls-files`, so it only came into scope on the first
                # commit - and then failed against a clone rather than against
                # the working tree it was written in.
                'tools/Set-RepoOwner.ps1'
            )
        }

        It 'the OWNER placeholder appears only in the sanctioned files' {
            # Case-sensitive and word-bounded on purpose: the placeholder is the
            # shouted literal. Lower-case 'owner' is an ordinary English word
            # and appears in prose that has nothing to do with this.
            $violations = foreach ($file in $script:TrackedFiles) {
                if ($file -in $script:SanctionedOwnerFiles) { continue }
                $lines = $script:FileLines[$file]
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -cmatch '\bOWNER\b') {
                        Format-Violation -File $file -LineNumber ($i + 1) -Detail 'OWNER placeholder outside the sanctioned files'
                    }
                }
            }
            $violations = @($violations)

            $violations.Count | Should -Be 0 -Because (
                "only bootstrap.ps1, README.md and the manifest may carry OWNER, because those are the three tools/Set-RepoOwner.ps1 stamps:`n" +
                ($violations -join "`n"))
        }

        It 'each sanctioned file still carries the placeholder' {
            # Keeps the allowlist above honest. A renamed or deleted file leaves
            # a dead entry behind, and a dead entry is worse than no entry: the
            # leak test goes on excusing a path that no longer exists while the
            # placeholder's new home is never checked.
            #
            # This deliberately does NOT assert that the three still CONTAIN the
            # placeholder. Set-RepoOwner.ps1 stamps a real owner into README.md
            # and the manifest, but bootstrap.ps1 keeps the literal either way
            # because its own guard matches on '/OWNER/'. Asserting presence
            # therefore fails on every correctly stamped fork.
            $dead = @($script:SanctionedOwnerFiles | Where-Object { $_ -notin $script:TrackedFiles })

            $dead.Count | Should -Be 0 -Because (
                'these paths are on the OWNER allowlist but are not tracked files, so the allowlist is stale: ' +
                ($dead -join ', '))
        }

        It 'bootstrap.ps1 refuses to clone while OWNER is unstamped' {
            # The failure this guards against is silent: git reports "repository
            # not found" for github.com/OWNER/..., which reads as the repo being
            # private or deleted rather than as bootstrap.ps1 never having been
            # finished. The throw has to happen before the clone.
            $bootstrap = $script:FileLines['bootstrap.ps1'] -join "`n"

            $bootstrap | Should -Match "\`$repoUrl -match '/OWNER/'" -Because 'the guard tests the resolved URL, not the default'
            $bootstrap | Should -Match 'has not been stamped with a repository owner' -Because 'the message has to say what is wrong'
            $bootstrap | Should -Match 'Set-RepoOwner\.ps1' -Because 'and name the tool that fixes it'

            # Ordering matters more than presence. A guard that runs after
            # 'git clone' explains a failure the user has already had.
            $guardAt = $bootstrap.IndexOf("-match '/OWNER/'")
            $cloneAt = $bootstrap.IndexOf('git clone')
            $guardAt | Should -BeGreaterThan -1
            $cloneAt | Should -BeGreaterThan -1
            $guardAt | Should -BeLessThan $cloneAt -Because 'the guard must throw before the clone is attempted'
        }
    }

    Context 'References resolve' {

        It 'every relative markdown link points at a file that exists' {
            # Markdown-link syntax is only looked for in .md files. PowerShell
            # produces the same '](' sequence whenever an index is followed by a
            # sub-expression - $Matches[1], $args[0] - and scanning scripts for
            # it reports those as links to nowhere.
            $markdown = @($script:TrackedFiles | Where-Object { $_ -like '*.md' })

            $violations = foreach ($file in $markdown) {
                $directory = Split-Path -Parent $file
                $lines = $script:FileLines[$file]
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    foreach ($m in [regex]::Matches($lines[$i], '\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')) {
                        $target = $m.Groups[1].Value

                        # External and in-page links are somebody else's problem.
                        if ($target -match '^[a-z][a-z0-9+.-]*:') { continue }
                        if ($target.StartsWith('#')) { continue }

                        # Strip the anchor: docs/05-usage.md#detach is a link to
                        # the file, and headings move around too much to check.
                        $path = ($target -split '#', 2)[0]
                        if (-not $path) { continue }

                        $resolved = if ($path.StartsWith('/')) {
                            Join-Path $script:RepoRoot $path.TrimStart('/')
                        } elseif ($directory) {
                            Join-Path (Join-Path $script:RepoRoot $directory) $path
                        } else {
                            Join-Path $script:RepoRoot $path
                        }

                        if (-not (Test-Path -LiteralPath $resolved)) {
                            Format-Violation -File $file -LineNumber ($i + 1) -Detail "link to '$target' - no such file"
                        }
                    }
                }
            }
            $violations = @($violations)

            $violations.Count | Should -Be 0 -Because (
                "a relative link that resolves to nothing is a 404 on GitHub:`n" +
                ($violations -join "`n"))
        }

        # Written -Skip, because when it was authored the repo genuinely failed
        # it: four references named three documents that were not in the
        # checkout, and spikes/ did not exist at all. All three have since been
        # written, so the skip is gone and this runs for real.
        #
        # The sequence is worth recording. A test skipped for a real defect and
        # then never un-skipped is a false green - in the summary it reads
        # exactly like a test that passed, which is the same silent-success
        # failure mode this whole project is built to refuse.
        It 'every docs/ or spikes/ reference points at a file that exists' {
            # These get written in prose and in comments, not as links, so the
            # markdown check above never sees them. They are the ones that rot:
            # a document gets renamed and the half-dozen places that mention it
            # by name carry on pointing at the old one.
            #
            # EVERY published text file is scanned, not a list of extensions.
            # The allow-list here used to be .md/.ps1/.kdl, and the two worst
            # offenders were a .ahk and a .cs - four published files cited a
            # CLAUDE.md that is never published, and two of them were invisible
            # to this check for no better reason than their suffix.
            $scanned = @($script:TrackedFiles)

            $violations = foreach ($file in $scanned) {
                $lines = $script:FileLines[$file]
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    # Drop URLs before matching. code.claude.com/docs/en/hooks
                    # contains 'docs/en/hooks', which is not a path in this repo.
                    $line = $lines[$i] -replace '[a-z][a-z0-9+.-]*://\S+', ''

                    # Two shapes. A docs/ or spikes/ path, where an extension is
                    # required - that filters out prose which merely runs the
                    # words together ("which docs/skill to ask for") and the
                    # extensionless tails of any URL that slipped past. And a
                    # SHOUTING repo-root filename, restricted to .md: with an
                    # open extension it matches IO.Path, UTF8.GetBytes and
                    # USERPROFILE.TrimEnd, which are code, not references.
                    foreach ($m in [regex]::Matches($line, '(?<![\w./\\-])(?:(?:docs|spikes)/[\w./-]+\.\w+|[A-Z][A-Z0-9_-]*\.md\b)')) {
                        $reference = $m.Value

                        # "Does it exist here" is the wrong question in the
                        # private tree, and it is the reason this check passed
                        # for as long as it did: CLAUDE.md exists, so Test-Path
                        # said yes, while no reader could ever open it. When the
                        # manifest is the scan set, ask whether the reference is
                        # PUBLISHED. In a clone there is no manifest and the two
                        # questions are the same one.
                        $resolves = if ($script:ScanSetIsManifest) {
                            $reference -in $script:PublishedSet
                        } else {
                            Test-Path -LiteralPath (Join-Path $script:RepoRoot $reference)
                        }

                        if (-not $resolves) {
                            Format-Violation -File $file -LineNumber ($i + 1) -Detail "reference to '$reference' - not published, so no reader can follow it"
                        }
                    }
                }
            }
            $violations = @($violations)

            $violations.Count | Should -Be 0 -Because (
                "each of these names a document that is not in the repo - either write it or stop pointing at it:`n" +
                ($violations -join "`n"))
        }

        It 'no published file cites a spike' {
            # The spikes are lab notes of the private side - machine paths,
            # private repository paths, and the record of what was tried before
            # the thing that worked. None of them are published and none will
            # be, so a citation to one can never be followed from here.
            #
            # This is not the same check as the one above. These were written
            # "(spike 03)" in prose, with no path and nothing link-shaped, so
            # the reference scan looking for 'spikes/something.md' walked
            # straight past twenty of them across ten published files.
            #
            # The measurement was always the useful half. "~500 ms measured"
            # says everything "~500 ms (spike 03)" said to somebody who cannot
            # open spike 03. This file is excluded from its own scan set, which
            # is the only reason the pattern can be written out here.
            #
            # EVERY text file, not a list of extensions. The check above scans
            # .md/.ps1/.kdl because a path-shaped reference only ever appears in
            # prose; this one has no such excuse, and an extension allow-list
            # here is the deny-list failure mode again - the first draft listed
            # six extensions and walked past a citation in settings.hooks.json
            # and four more in the AutoHotkey script, none of which are prose
            # files and all of which are published.
            $violations = foreach ($file in $script:TrackedFiles) {
                $lines = $script:FileLines[$file]
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '(?i)\bspikes?\s*-?\s*\d+') {
                        Format-Violation -File $file -LineNumber ($i + 1) -Detail "cites '$($Matches[0])' - the spikes are private and are never published"
                    }
                }
            }
            $violations = @($violations)

            $violations.Count | Should -Be 0 -Because (
                "keep the measurement, drop the citation - nobody reading this repo can open a spike:`n" +
                ($violations -join "`n"))
        }
    }
}
