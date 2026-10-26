# Verse localization glossary (en, it, tr)

Fixed terms for the interface catalog (`app/Sources/VerseUI/Resources/Localizable.xcstrings`). New strings use these words, so a
term reads the same everywhere. Italian uses "tu" and Apple's macOS Italian terms. Turkish uses macOS-style imperatives
("Kaydet", "Sil"), avoids direct address where the sentence allows it, and uses "sen" only when it cannot be avoided.
Shortcuts (⌥⌘V, ⌥Space, ⌘↩), file names, `VERSE_BRAIN_DIR`, and product names (Verse, Claude, Anthropic, Sonnet, ElevenLabs, OpenAI,
Apple, Finder) are never translated. Plurals use catalog plural variants (`one` / `other`); Turkish keeps the noun singular.

## Pages and objects

| en | it | tr | note |
|---|---|---|---|
| Prepare | Prepara | Hazırla | one key serves the page title and the buttons; see "Deviations" |
| Me | Profilo | Profil | |
| Sessions | Sessioni | Oturumlar | |
| Practice / Practise | Esercitazione / Esercitati | Pratik / Pratik yap | noun / verb |
| Practice interview | Colloquio di prova | Deneme mülakatı | |
| Scripts | Copioni | Metinler | |
| Settings | Impostazioni | Ayarlar | System Settings: Impostazioni di Sistema / Sistem Ayarları |
| Meeting | Riunione | Toplantı | |
| Call | Chiamata | Görüşme | |
| Transcript | Trascrizione | Transkript | |
| Summary | Riepilogo | Özet | |
| Follow up | Da fare | Yapılacaklar | summary heading "Actions" |
| Still open | Ancora aperti | Açık kalanlar | summary heading "Open questions" |
| Folder | Cartella | Klasör | |
| Card | Scheda | Kart | |
| Ask this meeting | Chiedi a questa riunione | Bu toplantıya sor | |
| Unprepared | Non preparata | Hazırlıksız | |
| Other (speaker) | Altro | Karşı taraf | |
| Room | Stanza | Oda | the room route / room mode |
| Route (where Verse listens) | Sorgente audio | Ses kaynağı | |
| Source (of a profile or posting) | Fonte | Kaynak | |
| Posting (job) | Annuncio | İlan | |
| Profile | Profilo | Profil | |
| Vault | Vault | Kasa | the Obsidian vault |
| Keychain | Portachiavi | Anahtar zinciri | |
| Brain (the Python process) | Cervello | Beyin | |
| Pack (meeting pack) | Pacchetto | Paket | |
| Fact sheet | Scheda informativa | Bilgi föyü | |
| Interviewer | Intervistatore | Mülakatçı | |
| Interview | Colloquio | Mülakat | |
| Teleprompter | Teleprompter | Teleprompter | |
| Island (the notch UI) | island | island | kept as a loan word |
| People (the page) | Persone | Kişiler | memory spec 5.7 |
| Person / Company | Persona / Azienda | Kişi / Şirket | |
| Brief (noun) / Make brief | Briefing / Prepara briefing | Brifing / Brifing hazırla | the pre-meeting summary |
| Ask all meetings | Chiedi a tutte le riunioni | Tüm toplantılara sor | |
| Ask about %@ | Chiedi su %@ | %@ hakkında sor | |
| Memory (Verse's index) | Memoria | Hafıza | |
| Merge / Merge Into… | Unisci / Unisci a… | Birleştir / Şununla Birleştir… | |
| Rename… | Rinomina… | Yeniden Adlandır… | |
| Hide from People | Nascondi da Persone | Kişiler’den Gizle | |
| You promised / They promised | Hai promesso / Hanno promesso | Söz verdiklerin / Söz verdikleri | brief section titles; "You" is the owner |
| Tone and preferences | Tono e preferenze | Üslup ve tercihler | brief section title |

## Verbs and labels

| en | it | tr |
|---|---|---|
| Cancel | Annulla | İptal |
| Save | Salva | Kaydet |
| Delete / Remove | Elimina / Rimuovi | Sil / Kaldır |
| Clear | Cancella | Temizle |
| Add | Aggiungi | Ekle |
| Replace | Sostituisci | Değiştir |
| Open | Apri | Aç |
| Close | Chiudi | Kapat |
| Copy / Paste | Copia / Incolla | Kopyala / Yapıştır |
| Retry | Riprova | Tekrar Dene |
| Start / Stop | Avvia / Interrompi | Başlat / Durdur |
| Refresh | Aggiorna | Yenile |
| Show in Finder | Mostra nel Finder | Finder’da Göster |
| Move to Trash | Sposta nel Cestino | Çöp Sepeti’ne Taşı |
| Trash (the swipe action, the Finder Trash) | Cestino | Çöp Sepeti |
| Undo | Annulla | Geri Al |
| Build (a profile, an interview) | Crea | Oluştur |
| Today / Yesterday / Tomorrow | Oggi / Ieri / Domani | Bugün / Dün / Yarın |
| Rate limited | Limite raggiunto | Hız sınırı aşıldı |
| (optional) | (facoltativo) | (isteğe bağlı) |

## Units and numbers

Italian and Turkish write decimals with a comma and group thousands with a dot ("3.500 token"). Units: wpm = parole/min,
sözcük/dk; minutes = min, dk; seconds = s, sn. Percentages follow the locale ("62%", "%62"). Currency stays USD ("$0,07").

## Deviations from the spec glossary

- **Prepare → tr "Hazırla"** (spec: "Hazırlık"). The key "Prepare" is both the page title and the label of the Prepare buttons (Up next,
  the form's primary button, Practice). A catalog key has one translation, and "Hazırlık" on a button reads wrong. If the owner prefers
  the noun for the sidebar, give the page its own key in code.
- **Today / Yesterday in Italian** are written "Oggi" / "Ieri" (capitalized, like every label); the spec test text says "oggi".
