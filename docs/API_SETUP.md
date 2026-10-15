# Configurazione dei servizi AI

## Modalità supportate

| Modalità | Come funziona | Quando usarla |
|---|---|---|
| **Personale (Bring Your Own Key)** | Inserisci le tue chiavi API nell'app; le richieste partono dall'iPad verso OpenAI/Anthropic. | Uso personale, nessun server da gestire. |
| **Backend gestito** | L'app invia l'audio al tuo backend (`Backend/`), che conserva le chiavi e completa il lavoro anche ad app chiusa. | Lezioni lunghe con elaborazione garantita; base per una versione commerciale. |
| **Sul dispositivo** | Trascrizione con Apple Speech, nessun invio dell'audio. La rielaborazione richiede comunque un provider cloud. | Privacy massima per la trascrizione. |

## Perché non c'è un «Accedi con ChatGPT / Claude»

OpenAI e Anthropic non offrono (a ottobre 2026) un login OAuth che permetta a un'app di terze parti di usare le API con l'abbonamento consumer dell'utente (ChatGPT Plus/Pro, Claude Pro/Max). Gli abbonamenti consumer **non includono** l'uso delle API, che si paga a consumo su un account separato. L'app quindi:

- non simula login, non usa cookie o sessioni web, non riusa token di altri prodotti;
- usa chiavi API inserite dall'utente e salvate solo nel **Portachiavi** di iPadOS (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`);
- per un prodotto commerciale prevede il backend gestito, con autenticazione propria e chiavi solo lato server.

## Chiave OpenAI (trascrizione e, facoltativamente, rielaborazione)

1. Crea un account API su <https://platform.openai.com>, aggiungi un metodo di pagamento o del credito.
2. Crea una chiave (API keys → Create new secret key). Per sicurezza, limitala a un progetto dedicato.
3. Nell'app: Impostazioni → Chiavi API → OpenAI → incolla → **Salva**. Il test di connessione elenca i modelli disponibili sul tuo account.

Modelli di trascrizione (documentazione OpenAI «File transcription», ottobre 2026):

| Modello | Uso nell'app | Note |
|---|---|---|
| `gpt-transcribe` (predefinito) | Glossario come `keywords[]`, lingue come `languages[]`, contesto in `prompt` | Solo testo: i tempi per frase sono interpolati dall'app. Prezzo indicativo 0,0045 $/min |
| `gpt-4o-transcribe-diarize` | `response_format=diarized_json`, `chunking_strategy=auto` | Interlocutori e tempi per segmento; niente prompt. Le etichette degli interlocutori non sono coerenti fra chunk diversi |
| `whisper-1` | `verbose_json` con `timestamp_granularities[]=segment` | Tempi precisi, accuratezza minore |
| `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` | Modelli precedenti | |

Limite di 25 MB per file: l'app divide automaticamente le registrazioni lunghe.

> **Da verificare con una chiave reale:** la codifica multipart dei campi array `keywords[]` e `languages[]` di `gpt-transcribe`. La documentazione li mostra solo tramite SDK (`extra_body`). Se l'API li rifiutasse, basta modificare `OpenAITranscriptionProvider.makeForm` in `Packages/QuadernoCore`.

Per la **rielaborazione** con OpenAI si usa la Responses API (`POST /v1/responses`, `store: false`). Il modello va scelto dall'elenco del tuo account: l'app suggerisce la famiglia più recente ma non imposta un nome fisso.

## Chiave Anthropic (rielaborazione, consigliata)

1. Crea un account su <https://console.anthropic.com>, aggiungi credito.
2. Crea una chiave (Settings → API Keys).
3. Nell'app: Impostazioni → Chiavi API → Anthropic → **Salva**.

Impostazioni predefinite (Messages API):

- modello `claude-opus-5-5` (selezionabile; prezzo indicativo 4 $ / 20 $ per milione di token in/out);
- ragionamento adattivo (predefinito sul modello), accuratezza della scrittura `high`, scaletta e verifica `medium`;
- scrittura in **streaming** (evita timeout su sezioni lunghe);
- output strutturato JSON (`output_config.format`) per scaletta e verifica;
- **fallback lato server** (`fallbacks: "default"`, beta `server-side-fallback-2026-07-01`): se i filtri di sicurezza rifiutano per errore un contenuto didattico (lezioni di biologia, chimica, sicurezza informatica), la richiesta viene ripetuta su un modello alternativo. Si disattiva nelle Impostazioni.

## Combinazioni

Trascrizione e rielaborazione sono indipendenti. La combinazione consigliata è **OpenAI `gpt-transcribe` + Anthropic `claude-opus-5-5`**.

## Costi

Prima di ogni lavoro l'app mostra una stima: minuti di audio per il listino della trascrizione, più i token stimati di scaletta, scrittura, verifica e correzioni. Ordine di grandezza per una lezione di 90 minuti in modalità integrale con verifica, da confermare sul listino corrente:

- trascrizione `gpt-transcribe`: circa 0,40 $;
- rielaborazione `claude-opus-5-5`: circa 1–2 $ (≈ 140k token in ingresso e 40k in uscita; la verifica pesa per il 50–80%);
- disattivando il controllo con l'AI si risparmia, ma resta solo il controllo locale.

## Consenso e privacy

- Nessun dato parte senza consenso esplicito, chiesto per ogni lavoro, con l'indicazione di cosa viene inviato e a chi.
- L'audio va solo al servizio di trascrizione, il testo solo a quello di rielaborazione.
- Le richieste OpenAI usano `store: false`. La conservazione presso i provider segue le loro condizioni per le API: verificale, soprattutto se nelle lezioni compaiono voci di altre persone.

## Backend gestito

Vedi [`../Backend/README.md`](../Backend/README.md). Nell'app: Impostazioni → Trascrizione → Servizio: *Backend Quaderno AI* → indirizzo e token.
