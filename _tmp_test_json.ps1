$ErrorActionPreference = "Stop"

function ConvertFrom-ModelJson {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        throw "empty"
    }

    $text = $Content.Trim()

    if ($text.StartsWith('```')) {
        $text = [regex]::Replace($text, '^```[a-zA-Z]*\s*', '')
        $text = [regex]::Replace($text, '\s*```$', '')
        $text = $text.Trim()
    }

    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) {
        $text = $text.Substring($start, $end - $start + 1)
    }

    return $text | ConvertFrom-Json
}

$fence = [char]96 + [char]96 + [char]96

# 1. plain json
$a = ConvertFrom-ModelJson '{"title":"x","segments":[]}'
Write-Host ("plain title=" + $a.title)

# 2. fenced json
$fenced = $fence + "json`n" + '{"title":"y","segments":[]}' + "`n" + $fence
$b = ConvertFrom-ModelJson $fenced
Write-Host ("fenced title=" + $b.title)

# 3. json with surrounding prose
$prose = "result:`n" + '{"title":"z","segments":[]}' + "`ndone."
$c = ConvertFrom-ModelJson $prose
Write-Host ("prose title=" + $c.title)

Write-Host "ALL_OK"
