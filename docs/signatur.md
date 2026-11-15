# Signatur des Setups

Stand: 15.11.2026

Das Setup von WidgetTea ist vorerst nicht signiert. Windows SmartScreen warnt deshalb beim Start. Wie es trotzdem
startet und was die Prüfsumme leistet, steht im [README](../README.md).

## Geprüft wird: Microsoft Store

Geprüft wird, WidgetTea künftig auch über den Microsoft Store anzubieten. Was das für Paket, Selbst-Update und die
.NET-Laufzeit bedeutet, ist noch nicht ausgearbeitet.

## Möglich: Certum Open Source Code Signing

Ein Zertifikat von Certum (Polen) für Entwickler freier Software. Die Angaben stammen aus Certums Shop und
Support-Seiten, abgerufen am 15.11.2026:
[Produkt](https://shop.certum.eu/open-source-code-signing-on-simplysign.html),
[nötige Unterlagen](https://support.certum.eu/en/code-signing-required-documents/).

- **Kosten:** 49 € für „Open Source Code Signing in the Cloud". Eine Laufzeit nennt die Produktseite nicht.
- **Wer es bekommt:** nur natürliche Personen. Wird damit kommerziell vertriebene Software signiert, widerruft Certum
  das Zertifikat.
- **Was Certum verlangt:** eine Identitätsprüfung (automatisch, mit Fotos beider Seiten eines Ausweises, notariell oder
  an einer Registrierungsstelle), eine Versorgerrechnung auf den eigenen Namen und die Adresse eines laufenden,
  öffentlichen Projekts, an dem die Beziehung des Antragstellers zum Projekt klar erkennbar ist. Bei WidgetTea steht
  der Name des Maintainers in der Lizenz und im Programm.
- **Was das Zertifikat öffentlich zeigt:** die Angaben zur Person, mit vorangestelltem „Open Source Developer", also
  den bürgerlichen Namen des Maintainers. Jeder sieht ihn in den Eigenschaften der signierten Datei. Ob weitere
  Angaben wie der Wohnort hineinkommen, sagen Certums Seiten nicht ausdrücklich.
- **Wie signiert wird:** Der Schlüssel liegt in Certums Cloud (SimplySign). Signiert wird auf einem Windows-Rechner
  mit SimplySign Desktop und einem Code aus der Handy-App (Android oder iOS), höchstens 5.000 Signaturen im Monat.
  Das passt zum Bau mit `build/release.ps1` auf dem eigenen Rechner. In GitHub Actions ginge es nur mit Werkzeugen
  Dritter.
- **Was es bringt:** Windows nennt einen Herausgeber statt „Unbekannt". Die Warnung von SmartScreen verschwindet
  damit nicht sofort; Windows vergibt Ansehen erst nach und nach.

## Nicht weiter verfolgt: SignPath Foundation

Kostenlos für freie Software, setzt aber voraus, dass das Setup in GitHub Actions gebaut wird, und verlangt eine
nachweisbare Bekanntheit des Projekts.
