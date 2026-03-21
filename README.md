# Archivio Detti di Tuturano
### Installazione sonora interattiva — Casa di Quartiere, Tuturano (Puglia)

---

## Descrizione

Un archivio sonoro partecipativo di detti dialettali raccolti via Telegram e riprodotti in uno spazio fisico. I visitatori inviano un vocale al bot, che lo normalizza e lo aggiunge all'archivio. Un sensore PIR rileva la presenza e riproduce un detto casuale ogni volta che qualcuno si avvicina all'installazione.

---

## Hardware

| Componente | Modello |
|---|---|
| Microcomputer | Raspberry Pi 5 (4GB o 8GB) |
| Scheda audio | Waveshare WM8960 Audio HAT |
| Sensore presenza | PIR HC-SR501 |
| Speaker | Speaker amplificato 8Ω / 1W per canale |

### Pinout WM8960

| PIN HAT | GPIO (BCM) | Board | Funzione |
|---|---|---|---|
| SDA | GPIO 2 | 3 | I2C Data |
| SCL | GPIO 3 | 5 | I2C Clock |
| CLK | GPIO 18 | 12 | I2S Bit clock |
| LRCLK | GPIO 19 | 35 | I2S Frame clock |
| DAC | GPIO 21 | 40 | I2S Data out |
| ADC | GPIO 20 | 38 | I2S Data in |
| BUTTON | GPIO 17 | 11 | Pulsante |

### Collegamento PIR

- **VCC** → Pin 2 (5V)
- **GND** → Pin 6 (GND)
- **OUT** → GPIO 16 (Pin 36)

---

## Installazione

### Requisiti
- Raspberry Pi OS Trixie (64-bit, headless)
- Connessione internet al primo avvio
- Account Raspberry Pi (per Rpi Connect)
- Bot Telegram creato via @BotFather

### Setup automatico

```bash
scp setup_archivio_detti.sh xyz@<IP_PI>:~/
ssh xyz@<IP_PI>
bash setup_archivio_detti.sh
```

Lo script:
1. Installa il driver WM8960 (richiede riavvio alla prima esecuzione)
2. Crea il virtualenv con tutte le dipendenze
3. Chiede il token Telegram e lo salva
4. Configura il volume ALSA in modo permanente
5. Scrive `archivio_detti.py`
6. Crea e abilita il servizio systemd

> **Nota**: se lo script chiede di riavviare, esegui `sudo reboot` e poi riesegui `bash setup_archivio_detti.sh`.

---

## Struttura del progetto

```
archivio_detti/
├── archivio_detti.py     # Script principale
├── token.txt             # Token bot Telegram (non condividere)
├── archive/              # File WAV dei detti
│   ├── meta.json         # Metadati utenti e timestamp
│   ├── detto_20260227_103045.wav
│   └── ...
├── models/               # Modelli RAVE opzionali
└── venv/                 # Virtualenv Python
```

---

## Configurazione

Tutti i parametri sono in cima ad `archivio_detti.py`:

| Parametro | Default | Descrizione |
|---|---|---|
| `PIR_PIN` | 16 | GPIO del sensore PIR |
| `ALSA_OUT` | hw:CARD=wm8960soundcard,DEV=0 | Device audio ALSA |
| `COOLDOWN` | 5s | Pausa dopo fine riproduzione |
| `DISK_LIMIT` | 90% | Soglia pulizia automatica disco |
| `MAX_DURATION` | 15s | Durata max prima della pulizia |
| `FFMPEG_AF` | loudnorm + volume=10dB | Catena di elaborazione audio |

---

## Bot Telegram

### Comandi disponibili

| Comando | Funzione |
|---|---|
| `/start` | Messaggio di benvenuto e istruzioni |
| `/archivio` | Numero di detti nell'archivio |
| `/cancella` | Rimuove il proprio ultimo detto |
| `/help` | Lista comandi |

### Flusso utente

1. L'utente scrive `/start` → riceve istruzioni
2. L'utente invia un vocale → viene normalizzato, convertito in stereo WAV e aggiunto all'archivio
3. Il bot risponde con il numero progressivo e l'invito a visitare l'installazione
4. Con `/cancella` l'utente può rimuovere il proprio ultimo contributo

### Aggiungere file da Mac

```bash
scp /path/to/file.wav xyz@<IP_PI>:~/archivio_detti/archive/
```

Per rinormalizzare i file già presenti:

```bash
for f in ~/archivio_detti/archive/*.wav; do
    ffmpeg -y -i "$f" -ar 44100 -ac 2 \
        -af "loudnorm=I=-16:TP=-1.5:LRA=11,volume=10dB" \
        "/tmp/$(basename $f)" && mv "/tmp/$(basename $f)" "$f"
done
```

---

## Gestione servizio

```bash
# Stato
sudo systemctl status archivio_detti

# Log in tempo reale
sudo journalctl -u archivio_detti -f

# Riavvia
sudo systemctl restart archivio_detti

# Ferma
sudo systemctl stop archivio_detti
```

---

## Accesso remoto

Il sistema usa **Raspberry Pi Connect** per accesso remoto senza IP fisso.

### Prima configurazione

```bash
rpi-connect signin
```

Apri il link nel browser e associa il dispositivo al tuo account.

### Accesso

Vai su [connect.raspberrypi.com](https://connect.raspberrypi.com), seleziona il dispositivo "audio" e clicca **Connect**.

---

## Volume

Il volume viene salvato in modo permanente con `alsactl store`. Per modificarlo:

```bash
# Interattivo
alsamixer -c 0

# Da terminale
amixer -c 0 set 'Speaker' 127

# Salva
sudo alsactl store
```

---

## Pulizia automatica

Quando il disco supera il 90% di utilizzo, il sistema rimuove automaticamente:

1. **Prima**: i file più lunghi di 15 secondi
2. **Poi**: i file più vecchi, in ordine cronologico

La pulizia continua finché lo spazio non scende sotto la soglia.

---

## Risoluzione problemi

**Il PIR non risponde**
```bash
python3 test_pir.py   # verifica che rilevi movimento
```
Se dà `GPIO busy`, cambia pin in `archivio_detti.py` e sposta il cavo fisicamente. Pin consigliati: 16, 23, 26.

**Nessun audio**
```bash
aplay -l                                          # verifica card number
aplay -D hw:0,0 ~/archivio_detti/archive/*.wav    # test diretto
```

**Conflict bot Telegram**
```bash
# Assicurati che un solo Pi usi lo stesso token
sudo systemctl stop archivio_detti   # sull'altro Pi
```

**WM8960 non rilevato**
```bash
cd ~/WM8960-Audio-HAT && sudo ./install.sh && sudo reboot
```

---

## Dipendenze Python

```
python-telegram-bot
numpy
soundfile
librosa
scipy
lgpio
gpiozero
```

---

*Progetto sviluppato per la Casa di Quartiere di Tuturano, Puglia.*
