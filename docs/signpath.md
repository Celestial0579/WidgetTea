# Signatur über die SignPath Foundation: Vorbereitung

Stand: 12.11.2026. Das Setup von WidgetTea ist nicht signiert (Entscheidung zu Issue 9). Diese Seite hält fest, was
ein Antrag bei der SignPath Foundation verlangt, wo WidgetTea bei jeder Bedingung steht, was am Release-Bau zu ändern
wäre, und sie enthält die Antworten für das Antragsformular. Gestellt ist der Antrag nicht.

Quellen, gelesen am 12.11.2026: [signpath.org](https://signpath.org/), die [Bedingungen](https://signpath.org/terms),
das [Antragsformular](https://signpath.org/apply) und die
[Anleitung für GitHub Actions](https://docs.signpath.io/trusted-build-systems/github).

## Was die SignPath Foundation bietet

Freie Software bekommt die Signatur kostenlos. Das Zertifikat lautet auf die SignPath Foundation: Sie erscheint in
Windows als Herausgeber und bürgt dafür, dass die Datei aus dem öffentlichen Repository gebaut wurde. Der Schlüssel
liegt bei SignPath.io. Signiert wird aus einem Lauf von GitHub Actions heraus, und jede Veröffentlichung gibt ein
Mitglied des Projekts von Hand frei. Über die Annahme entscheidet die Foundation allein.

## Die Bedingungen und der Stand von WidgetTea

| Bedingung | Stand |
|---|---|
| Lizenz, die die OSI anerkennt, ohne Doppel-Lizenzierung | erfüllt: MIT |
| Keine proprietären Bestandteile | erfüllt; die .NET-Laufzeit wird nicht mitgeliefert |
| Aktiv gepflegt | erfüllt |
| Schon veröffentlicht, in der Form, die signiert werden soll | erfüllt: Setup 1.0.0 |
| Was das Programm tut, steht auf der Download-Seite | erfüllt: README und Releases |
| Das Projekt ist verbreitet oder genießt Vertrauen (Pflichtfeld „Reputation“) | **schwach**, siehe unten |
| Alle Beteiligten nutzen Zwei-Faktor-Anmeldung, bei GitHub und bei SignPath | vom Maintainer einzurichten und zu bestätigen |
| Rollen sind benannt: Authors, Reviewers, Approvers | ein Maintainer hat alle drei |
| „Code signing policy“ auf Startseite und Download-Seite, mit vorgeschriebener Nennung | Text liegt unten bereit; gehört erst nach einer Zusage ins README |
| Programme, die Daten an andere Systeme senden, beschreiben das in einer Datenschutzerklärung, zeigen sie bei der Installation und lassen es abschalten | **offen**, siehe unten |
| Änderungen am System nur mit Hinweis; es gibt eine Deinstallation | erfüllt: Autostart ist abwählbar, die Deinstallation entfernt nur Eigenes |
| Produktname und Produktversion stehen in jeder signierten Datei, in einem Bau überall gleich | **anzugleichen**: Die EXE trägt `1.1.0+<Commit>`, das Setup `1.1.0` |
| Der Bau ist vollständig automatisiert, auf Runnern von GitHub; die Build-Skripte gehören zum geprüften Quelltext | **zu ändern**: Releases baut heute `build\release.ps1` auf einem eigenen Rechner |
| Signiert wird nur Eigenes; jede Veröffentlichung wird von Hand freigegeben | passt zum Ablauf unten |

**Verbreitung.** Der Antrag verlangt Belege, dass das Projekt verbreitet ist oder Vertrauen genießt: Berichte,
Download-Zahlen, GitHub-Statistik, Diskussionen. WidgetTea gibt es seit dem 24.10.2026; am 12.11.2026 hatte das
Repository keinen Stern, und das Setup 1.0.0 war 35-mal geladen, zum Teil von der eigenen CI. Hieran scheitert ein
Antrag heute am ehesten. Die Foundation prüft das beim Antrag und entscheidet nach eigenem Ermessen.

**Datenverkehr.** WidgetTea spricht mit zwei Systemen: mit dem Gitea, das der Nutzer einträgt, und mit GitHub, wenn es
nach Updates sucht. Die Suche nach Updates geschieht von selbst und lässt sich heute nicht abschalten; abschalten lässt
sich nur die automatische Installation. Für die Bedingungen der Foundation braucht es deshalb eine kurze
Datenschutzerklärung (Entwurf unten), ihre Anzeige im Setup und vermutlich einen Schalter für die Suche nach Updates.

## Was am Release-Bau zu ändern wäre

1. **Release in GitHub Actions.** Ein Workflow mit Handauslösung auf `main` baut Programm und Setup wie die CI und
   veröffentlicht mit dem Token des Laufs. Zugangsdaten auf einem eigenen Rechner braucht es dann nicht mehr.
2. **Zwei Signaturaufträge je Release.** Erst die Programmdateien (`WidgetTea.exe`, `WidgetTea.dll`), dann das Setup,
   das mit den signierten Dateien gebaut wird. Je Auftrag: Artefakt mit `actions/upload-artifact` hochladen, dann
   `signpath/github-action-submit-signing-request@v3` mit der Kennung des Artefakts; die signierte Datei kommt in den
   Ordner aus `output-artifact-directory` zurück. Die Prüfsumme `.sha256` entsteht erst aus dem signierten Setup.
3. **`build\release.ps1` teilen.** Heute baut es Programm und Setup in einem Zug. Zwischen beiden liegt dann das
   Signieren, also müssen sich die beiden Schritte einzeln aufrufen lassen.
4. **Deinstallationsprogramm.** `WriteUninstaller` erzeugt es bei der Installation aus dem Setup; es wäre unsigniert.
   Dafür muss es in einem Vorlauf erzeugt, signiert und als fertige Datei eingepackt werden.
5. **Versionsangaben angleichen** (siehe Tabelle).
6. **Im Projekt bei SignPath einzurichten:** das Projekt selbst, die Verbindung zu GitHub als Build-System, eine
   Signaturrichtlinie zum Testen und eine für Releases, die Beschreibung der Artefakte. Der Workflow braucht dann ein
   Secret mit dem API-Token und die Kennungen von Organisation, Projekt und Richtlinie.
7. **Später möglich:** Der Updater prüft vor dem Start des geladenen Setups, dass es von der SignPath Foundation
   signiert ist. Erst das schützt davor, dass jemand mit Zugriff auf das GitHub-Konto ein fremdes Setup unterschiebt.

## Der Antrag

Das Formular steht auf <https://signpath.org/apply> und ist englisch. Pflichtfelder tragen einen Stern.

| Feld | Eintrag |
|---|---|
| Project Name* | `WidgetTea` |
| Repository URL* | `https://github.com/Celestial0579/WidgetTea` |
| Homepage URL* | `https://github.com/Celestial0579/WidgetTea` |
| Download URL | `https://github.com/Celestial0579/WidgetTea/releases` (laut Formular muss diese Seite die Signatur durch die SignPath Foundation erwähnen; das geht erst nach einer Zusage, bis dahin leer lassen) |
| Privacy Policy URL | leer lassen, solange es keine Erklärung im README gibt; danach deren Adresse |
| Wikipedia URL | leer |
| Tagline* | `Shows your Gitea contribution heatmap as a widget on the Windows desktop.` |
| Category* | `Developer Tools` |
| Description* | siehe unten |
| Reputation* | siehe unten, mit aktuellen Zahlen |
| Maintainer Type | `Individual maintainer(s)` |
| Build System* | `GitHub Actions` |
| First Name*, Last Name*, Email* | eigene Angaben; auf sie wird das Konto bei SignPath angelegt |
| Company Name | leer |
| Primary Discovery Channel* | aus der Liste wählen |
| Please specify the exact source | freiwillig |

Dazu drei Kästchen: Zustimmung zum Verhaltenskodex der Foundation samt dem Hinweis, dass Zertifikate auf ihren Namen
lauten und widerrufen werden können (Pflicht), Zustimmung zur Speicherung der Angaben (Pflicht), weitere Post von
SignPath (freiwillig). Abgeschickt wird über ein reCAPTCHA.

**Description**

```text
WidgetTea is a small Windows desktop widget that shows the contribution heatmap of a Gitea account, the way
Gitea shows it on a profile page. It reads the heatmap from the Gitea server the user enters, keeps the last
result for offline use, and sits on the desktop behind other windows. It is written in C# (WPF), licensed under
MIT, installs per user without administrator rights and updates itself from the releases of its repository.
```

**Reputation** (ehrlich und mit den Zahlen vom Tag des Antrags)

```text
WidgetTea is a young project: the first release was published on 24 October 2026. The repository is public,
MIT-licensed and actively maintained by a single developer. Every pull request runs an automated test suite on
GitHub-hosted runners (unit tests, silent installer tests on Windows x64 and ARM64, and an end-to-end
self-update test). Release downloads so far: <Zahl eintragen>. GitHub stars: <Zahl eintragen>.
```

## Für das README, nach einer Zusage

Die Foundation verlangt einen Abschnitt mit der Überschrift „Code signing policy“ auf der Startseite und der
Download-Seite, mit dieser Nennung und den Rollen:

```markdown
## Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io/), certificate by
[SignPath Foundation](https://signpath.org/).

- Committers, reviewers and approvers: [Tim Heyne](https://github.com/Celestial0579)

### Privacy policy

WidgetTea connects to two systems. It reads your contribution heatmap from the Gitea server you enter in the
settings and sends the access token you provide to that server only. It asks GitHub whether a newer release of
WidgetTea exists and downloads it from there. It sends no other data and contains no telemetry.
```

Die Bedingungen nennen für Programme ohne jeden eigenen Datenverkehr einen festen Satz. Er passt auf WidgetTea nicht,
weil die Suche nach Updates von selbst geschieht; deshalb die eigene Beschreibung.

## Was beim Maintainer bleibt

- Zwei-Faktor-Anmeldung bei GitHub prüfen.
- Entscheiden, ob der Antrag jetzt gestellt wird oder erst, wenn das Projekt Verbreitung vorweisen kann.
- Den Antrag stellen: Die Angaben zur Person, die Zustimmungen und das reCAPTCHA gehören in seine Hand.
- Nach einer Zusage: Konto bei SignPath einrichten, Projekt und Richtlinien anlegen, API-Token als Secret hinterlegen.
  Erst dann lohnt der Umbau des Release-Baus.
