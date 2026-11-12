<#
.SYNOPSIS
  Prüfungen, die build\release.ps1 vor dem Veröffentlichen ausführt.

.DESCRIPTION
  Sie stehen in einer eigenen Datei, damit sie sich prüfen lassen, ohne zu bauen und ohne zu veröffentlichen
  (tests\release\Test-ReleaseChecks.ps1). release.ps1 bindet die Datei per Punkt-Aufruf ein.
#>

function Assert-HeadIsRemoteBranch {
    <#
    .SYNOPSIS
      Bricht ab, wenn der ausgecheckte Commit nicht der ist, auf dem der Zweig auf der Gegenstelle gerade steht.

    .DESCRIPTION
      Gefragt wird die Gegenstelle selbst (git ls-remote) und nicht der lokale Merker origin/main, denn der ist
      nur so aktuell wie der letzte Abruf. Abgelehnt werden damit drei Lagen:
        - ein anderer Zweig oder ein älterer Commit ist ausgecheckt,
        - der Zweig ist ausgecheckt, aber nicht aktualisiert,
        - es gibt eigene Commits, die noch nicht auf der Gegenstelle liegen.
      Antwortet die Gegenstelle nicht, wird ebenfalls abgebrochen.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Remote = 'origin',
        [string]$Branch = 'main'
    )

    $head = git -C $Root rev-parse --verify HEAD
    if ($LASTEXITCODE -or -not $head) { throw "Der ausgecheckte Commit in $Root lässt sich nicht bestimmen." }

    $answer = @(git -C $Root ls-remote $Remote "refs/heads/$Branch")
    if ($LASTEXITCODE) {
        throw "Der Stand von $Remote/$Branch lässt sich nicht abfragen. Ohne ihn wird nichts veröffentlicht."
    }
    if ($answer.Count -eq 0 -or -not $answer[0]) { throw "Auf $Remote gibt es keinen Zweig $Branch." }
    $remoteHead = ($answer[0] -split '\s+')[0]

    if ($head -ne $remoteHead) {
        $name = git -C $Root rev-parse --abbrev-ref HEAD
        $where = if ($name -and $name -ne 'HEAD') { "Zweig $name" } else { 'kein Zweig' }
        $text = 'Veröffentlicht wird nur der aktuelle Stand von {0}/{1}. Ausgecheckt ist {2} ({3}), {0}/{1} steht bei {4}. ' +
                "Erst 'git switch {1}' und 'git pull' ausführen; eigene Commits müssen vorher auf {0}/{1} liegen."
        throw ($text -f $Remote, $Branch, $head.Substring(0, 7), $where, $remoteHead.Substring(0, 7))
    }
}
