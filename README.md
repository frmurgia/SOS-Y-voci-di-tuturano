# 🐦 Archivio Detti di Tuturano

> Installazione sonora interattiva — Casa di Quartiere, Tuturano (Puglia, IT)

Un archivio sonoro partecipativo di detti dialettali raccolti via Telegram e riprodotti nello spazio fisico. I visitatori inviano un vocale al bot, che lo normalizza e lo aggiunge all'archivio. Un sensore PIR rileva la presenza e riproduce un detto casuale ogni volta che qualcuno si avvicina all'installazione.

---

## Come funziona
```
Visitatore → Telegram Bot → Archivio WAV → PIR rileva presenza → Riproduzione
```

1. L'utente invia un vocale al bot Telegram
2. Il bot normalizza l'audio e lo salva nell'archivio
3. Il sensore PIR rileva un visitatore davanti all'installazione
4. Viene riprodotto un detto casuale (senza ripetizioni fino all'esaurimento del ciclo)
5. Cooldown di 5 secondi dalla fine della riproduzione

---

## Hardware

- Raspberry Pi 5
- Waveshare WM8960 Audio HAT
- Sensore PIR HC-SR501 → GPIO 16
- Speaker amplificato

---

## Installazione
```bash
bash setup_archivio_detti.sh
```

> Se richiede riavvio per il driver WM8960, esegui `sudo reboot` e riesegui lo script.

---

## Bot Telegram

| Comando | Funzione |
|---|---|
| `/start` | Benvenuto e istruzioni |
| `/archivio` | Numero di detti raccolti |
| `/cancella` | Rimuovi il tuo ultimo detto |
| `/help` | Lista comandi |

---

## Configurazione

Modifica i parametri in cima ad `archivio_detti.py`:
```python
PIR_PIN      = 16       # GPIO sensore PIR
ALSA_OUT     = "hw:CARD=wm8960soundcard,DEV=0"
COOLDOWN     = 5        # secondi dopo fine riproduzione
DISK_LIMIT   = 90       # % disco oltre cui pulire automaticamente
MAX_DURATION = 15       # secondi — file più lunghi rimossi per primi
```

---

## Struttura
```
archivio-detti/
├── archivio_detti.py        # Script principale
├── setup_archivio_detti.sh  # Setup automatico
├── README.md
└── archive/                 # Generata automaticamente
    ├── meta.json
    └── detto_*.wav
```

> `token.txt` e `archive/` sono esclusi dal repository (`.gitignore`)

---

## Accesso remoto

Il sistema usa [Raspberry Pi Connect](https://connect.raspberrypi.com) per accesso remoto senza IP fisso.
```bash
rpi-connect signin
```

---

## Licenza

MIT — Daniele Murgioni / Atlas Instruments
