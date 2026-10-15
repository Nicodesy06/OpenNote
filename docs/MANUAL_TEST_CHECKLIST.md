# Checklist di prova su iPad fisico

Da eseguire con build **Release**, batteria non in carica (per le prove energetiche), dopo aver configurato le chiavi API. Per ogni voce annota data, modello di iPad, versione di iPadOS ed esito.

## Registrazione e scrittura

- [ ] **Schermo bloccato ≥ 60 min:** avvia la registrazione, blocca l'iPad per almeno un'ora, sblocca. Atteso: banner REC attivo, durata ≈ tempo reale, audio udibile per tutto l'intervallo, nessun buco ai cambi di segmento (ascolta i minuti 3:00, 6:00, 9:00…).
- [ ] **Scrittura durante la registrazione:** registra dal quaderno, scrivi su 3 pagine cambiando pagina più volte. Atteso: scrittura fluida, banner presente nell'editor. Nel dettaglio della registrazione i segnalibri «Aperta pagina N» e «Scrittura a pagina N» portano ai tempi corretti.
- [ ] **Passaggio tra app:** durante la registrazione apri Safari e un'altra app per 5 minuti. Atteso: la registrazione prosegue.
- [ ] **Lezione lunga (≥ 2 h 30):** atteso: unico file `audio.m4a` dopo lo Stop, durata corretta, nessun errore di spazio.
- [ ] **Interruzione di sistema:** ricevi una chiamata FaceTime o telefonica (o attiva Siri) durante la registrazione. Atteso: pausa con motivo, ripresa automatica a fine chiamata (se l'opzione è attiva), notifica se l'app è in background, nessuna perdita prima della chiamata.
- [ ] **Microfono esterno:** collega e scollega un microfono USB-C durante la registrazione. Atteso: la registrazione continua in un nuovo segmento con il nuovo ingresso.
- [ ] **Profili:** registrazione di prova di 10 s con ciascun profilo, a 2 m e a 10 m da una sorgente vocale. Annota il livello in dBFS e l'avviso di segnale basso o distorto.
- [ ] **Chiusura forzata:** durante una registrazione di 10 minuti chiudi l'app dal selettore. Riaprila. Atteso: registrazione «Recuperata» con l'audio fino all'ultimo segmento chiuso (si perde al massimo 3 minuti con le impostazioni predefinite) e i segnalibri.
- [ ] **Memoria quasi piena:** riempi lo spazio fino a circa 300 MB liberi. Atteso: avvio rifiutato sotto 200 MB, con messaggio. Durante una registrazione, sotto 50 MB stop protetto con l'audio salvato.

## Quaderni

- [ ] Crea un quaderno, scrivi su 30 pagine, chiudi l'app (anche forzatamente dopo qualche secondo), riaprila. Atteso: tutti i tratti presenti.
- [ ] Quaderno con oltre 150 pagine: apertura e cambio pagina fluidi, memoria stabile in Instruments (Allocations).
- [ ] Palm rejection: appoggia il palmo mentre scrivi con Pencil (opzione «dito» disattivata).
- [ ] Zoom 50–400%: righe nitide, inchiostro nitido, testo e immagini nitidi a fine zoom.
- [ ] Testo digitato e immagini: inserimento, spostamento, ridimensionamento, eliminazione; persistenza dopo il riavvio.
- [ ] Export PDF di un quaderno con modelli diversi.
- [ ] Modalità scura: la carta resta bianca e i colori dell'inchiostro restano quelli scelti.
- [ ] Split View e Slide Over con un'altra app; rotazione portrait e landscape.

## Importazione e riproduzione

- [ ] Importa un audio di **2 ore** da File/iCloud Drive (M4A, MP3, WAV) e un MP4 video. Atteso: nessun picco di memoria (Allocations), durata corretta.
- [ ] «Apri con» da Memo Vocali o File verso Quaderno AI: assegnazione alla materia.
- [ ] Riproduzione: barra, ±15 s, velocità 0,75–2×, controlli nella schermata di blocco.

## Trascrizione e sbobinatura

- [ ] Lezione reale di 90 minuti: «Trascrivi e crea sbobinatura» con OpenAI + Claude. Atteso: stima dei costi, consenso richiesto, avanzamento per parti e per sezioni, documento completo.
- [ ] **Rete assente:** modalità aereo all'avvio del lavoro → stato «In attesa della connessione»; disattiva la modalità aereo → il lavoro riparte da solo.
- [ ] **Rete persa a metà:** disattiva il Wi-Fi durante la trascrizione → nuovo tentativo automatico, nessuna parte ritrasmessa se già completata (controlla la diagnostica o i log del provider).
- [ ] **Riavvio durante un lavoro cloud:** chiudi forzatamente l'app a metà sbobinatura, riapri → il lavoro riprende dalla sezione successiva all'ultima completata.
- [ ] **Schermo bloccato durante l'elaborazione:** blocca l'iPad per 20 minuti durante la trascrizione → alla riapertura il lavoro è avanzato (upload in background) o riprende senza ripetere le parti già inviate.
- [ ] Chiave non valida → errore chiaro, nessun tentativo ripetuto. Credito esaurito → errore chiaro.
- [ ] Editor: modifica di un paragrafo, grassetto e corsivo, elenco, immagine, cerca e sostituisci; rigenera un'altra sezione e verifica che la modifica resti; ripristina una versione.
- [ ] Confronto: tocca un riferimento ▸ nella sbobinatura → l'audio salta al punto, la trascrizione evidenzia i segmenti.
- [ ] Export PDF e DOCX; apri il DOCX in Word o Pages.
- [ ] Trascrizione sul dispositivo (iPadOS 26 e iPadOS 17/18): esito e tempi; annota il consumo di batteria.
- [ ] Modelli di trascrizione: scarica Parakeet Ultra (avanzamento, «Preparazione…», annullamento e ripresa), poi in modalità aereo trascrivi una lezione di 60 minuti; ripeti con Whisper Large v3 Turbo e Canary 1B v2. Annota tempo totale, batteria consumata, temperatura e qualità (`tools/quality_eval`).
- [ ] Modelli: elimina un modello e verifica che lo spazio torni libero; verifica che i modelli non adatti all'iPad risultino disattivati con il motivo.
- [ ] Modelli: avvia una trascrizione locale e blocca lo schermo; verifica che alla riapertura riprenda dall'ultima parte completata.

## Energia (Instruments → Energy Log)

- [ ] 30 min di registrazione a schermo bloccato: impatto energetico medio ______.
- [ ] 30 min di registrazione con scrittura attiva: impatto ______, CPU media ______.
- [ ] Confronto con Memo Vocali nello stesso scenario: differenza ______.
