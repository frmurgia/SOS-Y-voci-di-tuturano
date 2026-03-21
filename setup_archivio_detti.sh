#!/bin/bash
# ══════════════════════════════════════════════════════
#  ARCHIVIO DETTI — Setup completo
#  Raspberry Pi 5 + WM8960 Audio HAT
#  Uso: bash setup_archivio_detti.sh
# ══════════════════════════════════════════════════════

set -e
INSTALL_DIR="$HOME/archivio_detti"
VENV="$INSTALL_DIR/venv"
SERVICE="archivio_detti"

echo "══════════════════════════════════════════════════════"
echo "  ARCHIVIO DETTI — Installazione"
echo "══════════════════════════════════════════════════════"
echo ""

# ── 1. Dipendenze di sistema ──────────────────────────
echo "[1/8] Dipendenze di sistema..."
sudo apt update -q
sudo apt install -y \
    python3-venv python3-pip \
    ffmpeg alsa-utils \
    swig liblgpio-dev \
    python3-lgpio python3-gpiozero \
    rpi-connect-lite \
    git curl

# ── 2. Driver WM8960 ──────────────────────────────────
echo "[2/8] Driver WM8960..."
if ! aplay -l 2>/dev/null | grep -q "wm8960"; then
    if [ ! -d "$HOME/WM8960-Audio-HAT" ]; then
        git clone https://github.com/waveshare/WM8960-Audio-HAT "$HOME/WM8960-Audio-HAT"
    fi
    cd "$HOME/WM8960-Audio-HAT"
    sudo ./install.sh
    echo ""
    echo "⚠  Driver WM8960 installato."
    echo "   Riavvia il Pi e riesegui questo script:"
    echo "   sudo reboot"
    echo ""
    exit 0
else
    echo "  ✓ WM8960 già attivo"
fi
cd "$HOME"

# ── 3. Struttura cartelle ─────────────────────────────
echo "[3/8] Cartelle..."
mkdir -p "$INSTALL_DIR/archive"
mkdir -p "$INSTALL_DIR/models"

# ── 4. Virtualenv ─────────────────────────────────────
echo "[4/8] Virtualenv..."
python3 -m venv --system-site-packages "$VENV"
source "$VENV/bin/activate"
pip install -q --upgrade pip
pip install -q \
    python-telegram-bot \
    numpy soundfile librosa scipy \
    lgpio gpiozero

# ── 5. Token Telegram ─────────────────────────────────
echo "[5/8] Token Telegram..."
TOKEN_FILE="$INSTALL_DIR/token.txt"
if [ ! -f "$TOKEN_FILE" ]; then
    echo -n "  Inserisci il token del bot Telegram: "
    read TOKEN
    echo "$TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "  ✓ Token salvato"
else
    echo "  ✓ Token già presente"
fi

# ── 6. Volume ALSA ────────────────────────────────────
echo "[6/8] Volume ALSA..."
CARD=$(aplay -l | grep wm8960 | grep -o 'card [0-9]' | grep -o '[0-9]' | head -1)
if [ -n "$CARD" ]; then
    amixer -c "$CARD" set 'Speaker' 127 on 2>/dev/null || true
    amixer -c "$CARD" set 'Left Output Mixer PCM Playback Switch' on 2>/dev/null || true
    amixer -c "$CARD" set 'Right Output Mixer PCM Playback Switch' on 2>/dev/null || true
    sudo alsactl store
    echo "  ✓ Volume salvato (card $CARD)"
else
    echo "  ⚠ WM8960 non trovato — salta volume"
    CARD=0
fi

# ── 7. Script principale ──────────────────────────────
echo "[7/8] Script principale..."
cat > "$INSTALL_DIR/archivio_detti.py" << 'PYEOF'
#!/usr/bin/env python3
"""
archivio_detti.py
Archivio sonoro di detti — Raspberry Pi 5 + WM8960

Flusso:
  1. Bot Telegram riceve vocali → li salva in archive/
  2. PIR (GPIO 16) rileva presenza → riproduce un detto casuale
  3. Cooldown 5s dalla fine della riproduzione
  4. Pulizia automatica disco oltre 90%
"""

import os, time, random, logging, threading, subprocess, shutil, json
from pathlib import Path
from datetime import datetime
from gpiozero import MotionSensor
from telegram import Update
from telegram.ext import (
    ApplicationBuilder, MessageHandler, CommandHandler,
    filters, ContextTypes
)

# ── Configurazione ────────────────────────────────────
PIR_PIN     = 16
ALSA_OUT    = "hw:CARD=wm8960soundcard,DEV=0"
ARCHIVE_DIR = os.path.join(os.path.dirname(__file__), "archive")
COOLDOWN    = 5
BOT_TOKEN   = open(os.path.join(os.path.dirname(__file__), "token.txt")).read().strip()
FFMPEG_AF   = "loudnorm=I=-16:TP=-1.5:LRA=11,volume=10dB"
DISK_LIMIT  = 90        # % oltre cui pulire
MAX_DURATION = 15       # secondi — prima da cancellare
META_FILE   = os.path.join(ARCHIVE_DIR, "meta.json")

logging.basicConfig(
    format="[%(asctime)s] %(message)s",
    datefmt="%H:%M:%S",
    level=logging.INFO
)
log = logging.getLogger(__name__)

# ── Archivio ──────────────────────────────────────────
class Archivio:
    def __init__(self):
        os.makedirs(ARCHIVE_DIR, exist_ok=True)
        self._playlist = []
        self._played   = []
        self._lock     = threading.Lock()
        self._meta     = self._load_meta()
        self._refresh()

    def _load_meta(self):
        if os.path.exists(META_FILE):
            try:
                return json.load(open(META_FILE))
            except Exception:
                pass
        return {}

    def _save_meta(self):
        json.dump(self._meta, open(META_FILE, "w"), indent=2)

    def _get_duration(self, wav_path):
        try:
            r = subprocess.run([
                "ffprobe", "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                wav_path
            ], capture_output=True, text=True)
            return float(r.stdout.strip())
        except Exception:
            return 0.0

    def _disk_usage_pct(self):
        s = shutil.disk_usage(ARCHIVE_DIR)
        return s.used / s.total * 100

    def _cleanup_if_needed(self):
        if self._disk_usage_pct() < DISK_LIMIT:
            return
        log.info(f"Disco oltre {DISK_LIMIT}% — pulizia automatica...")
        # Prima: file più lunghi di MAX_DURATION
        for f in sorted(Path(ARCHIVE_DIR).glob("*.wav")):
            if self._get_duration(str(f)) > MAX_DURATION:
                os.remove(f)
                self._meta.pop(f.name, None)
                log.info(f"Rimosso (lungo): {f.name}")
                if self._disk_usage_pct() < DISK_LIMIT:
                    self._save_meta()
                    return
        # Poi: dal più vecchio
        for f in sorted(Path(ARCHIVE_DIR).glob("*.wav")):
            os.remove(f)
            self._meta.pop(f.name, None)
            log.info(f"Rimosso (vecchio): {f.name}")
            if self._disk_usage_pct() < DISK_LIMIT:
                break
        self._save_meta()

    def _refresh(self):
        files = sorted(Path(ARCHIVE_DIR).glob("*.wav"))
        with self._lock:
            self._playlist = [str(f) for f in files]
        log.info(f"Archivio: {len(self._playlist)} detti")

    def add(self, src_path, user_id=None, username=None):
        self._cleanup_if_needed()
        ts   = datetime.now().strftime("%Y%m%d_%H%M%S")
        dest = os.path.join(ARCHIVE_DIR, f"detto_{ts}.wav")
        subprocess.run([
            "ffmpeg", "-y", "-i", src_path,
            "-ar", "44100", "-ac", "2",
            "-af", FFMPEG_AF, dest
        ], capture_output=True)
        fname = os.path.basename(dest)
        self._meta[fname] = {"user_id": user_id, "username": username, "ts": ts}
        self._save_meta()
        self._refresh()
        log.info(f"Aggiunto: {fname}")
        return dest

    def delete_last_by_user(self, user_id):
        user_files = [
            (fname, info) for fname, info in self._meta.items()
            if info.get("user_id") == user_id
        ]
        if not user_files:
            return None
        user_files.sort(key=lambda x: x[1]["ts"], reverse=True)
        fname, _ = user_files[0]
        fpath = os.path.join(ARCHIVE_DIR, fname)
        if os.path.exists(fpath):
            os.remove(fpath)
        self._meta.pop(fname, None)
        self._save_meta()
        self._refresh()
        return fname

    def next(self):
        with self._lock:
            available = [f for f in self._playlist if f not in self._played]
            if not available:
                self._played = []
                available    = list(self._playlist)
            if not available:
                return None
            chosen = random.choice(available)
            self._played.append(chosen)
            return chosen

    def count(self):
        return len(self._playlist)

# ── Player ────────────────────────────────────────────
class Player:
    def __init__(self):
        self._proc = None
        self._lock = threading.Lock()

    def play(self, wav_path):
        with self._lock:
            self._stop()
            log.info(f"▶ {os.path.basename(wav_path)}")
            self._proc = subprocess.Popen(
                ["aplay", "-D", ALSA_OUT, wav_path],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )

    def _stop(self):
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
            self._proc.wait()
        self._proc = None

    def is_playing(self):
        return self._proc is not None and self._proc.poll() is None

# ── PIR ───────────────────────────────────────────────
class PIRController:
    def __init__(self, archivio, player):
        self.archivio      = archivio
        self.player        = player
        self._last_trigger = 0
        self._pir          = MotionSensor(PIR_PIN)
        self._pir.when_motion = self._on_motion
        log.info(f"PIR su GPIO {PIR_PIN} — in ascolto")

    def _on_motion(self):
        now = time.time()
        if now - self._last_trigger < COOLDOWN:
            return
        if self.player.is_playing():
            return
        if self.archivio.count() == 0:
            return
        wav = self.archivio.next()
        if wav:
            threading.Thread(
                target=self._play_and_cooldown, args=(wav,), daemon=True
            ).start()

    def _play_and_cooldown(self, wav):
        self._last_trigger = float('inf')
        self.player.play(wav)
        while self.player.is_playing():
            time.sleep(0.2)
        self._last_trigger = time.time()

# ── Bot Telegram ──────────────────────────────────────
class TelegramBot:
    def __init__(self, archivio):
        self.archivio = archivio
        self.app      = ApplicationBuilder().token(BOT_TOKEN).build()
        self.app.add_handler(CommandHandler("start",    self._handle_start))
        self.app.add_handler(CommandHandler("cancella", self._handle_cancella))
        self.app.add_handler(CommandHandler("archivio", self._handle_archivio))
        self.app.add_handler(CommandHandler("help",     self._handle_help))
        self.app.add_handler(
            MessageHandler(filters.VOICE | filters.AUDIO, self._handle_voice)
        )
        self.app.post_init = self._set_commands

    async def _set_commands(self, app):
        await app.bot.set_my_commands([
            ("start",    "Inizia e scopri come partecipare"),
            ("archivio", "Quanti detti ci sono"),
            ("cancella", "Rimuovi il tuo ultimo detto"),
            ("help",     "Aiuto"),
        ])

    async def _handle_start(self, update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        await update.message.reply_text(
            "Aiutami a creare l'archivio dei Detti di Tuturano, "
            "mandami un breve vocale e nci pensu iu a condividerlo cu tutti! "
            "Premi il tasto microfono e registra il tuo detto tipico! 🎤"
        )

    async def _handle_voice(self, update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        msg      = update.message
        username = msg.from_user.first_name or msg.from_user.username or "Anonimo"
        file     = await (msg.voice or msg.audio).get_file()
        tmp      = f"/tmp/detto_{int(time.time())}.ogg"
        await file.download_to_drive(tmp)
        dest = self.archivio.add(tmp, user_id=msg.from_user.id, username=username)
        os.remove(tmp)
        n = self.archivio.count()
        await msg.reply_text(
            f"Vocale ricevuto {username}, grazie! 🙏\n"
            f"Il tuo contributo n° {n} si è appena unito al nostro database sonoro "
            f"in continua evoluzione.\n\n"
            f"Addoni potrai ascoltarlo insieme a tutti gli altri? "
            f"Vieni a trovarci alla Casa di Quartiere e cerca l'installazione "
            f"a forma di volatile per vivere un'esperienza immersiva di ascolto! 🐦"
        )

    async def _handle_archivio(self, update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        n = self.archivio.count()
        await update.message.reply_text(
            f"🗂 L'archivio contiene {n} dett{'o' if n==1 else 'i'}."
        )

    async def _handle_cancella(self, update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        user_id = update.message.from_user.id
        fname   = self.archivio.delete_last_by_user(user_id)
        if fname:
            await update.message.reply_text(
                f"✓ Il tuo ultimo detto è stato rimosso dall'archivio.\n"
                f"Detti rimanenti: {self.archivio.count()}"
            )
        else:
            await update.message.reply_text(
                "Non ho trovato nessun detto da cancellare per te."
            )

    async def _handle_help(self, update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        await update.message.reply_text(
            "Come partecipare:\n"
            "🎤 Inviami un vocale con un detto tipico di Tuturano\n\n"
            "Comandi:\n"
            "/start — messaggio di benvenuto\n"
            "/archivio — quanti detti sono stati raccolti\n"
            "/cancella — rimuovi il tuo ultimo detto\n"
            "/help — questo messaggio"
        )

    def run(self):
        log.info("Bot Telegram avviato")
        self.app.run_polling(stop_signals=None)

# ── Main ──────────────────────────────────────────────
if __name__ == "__main__":
    archivio = Archivio()
    player   = Player()
    pir      = PIRController(archivio, player)

    log.info(f"Detti presenti: {archivio.count()}")
    log.info("Sistema pronto. CTRL+C per uscire.\n")

    try:
        bot = TelegramBot(archivio)
        bot.run()
    except KeyboardInterrupt:
        log.info("Uscita.")
PYEOF

# ── 8. Servizio systemd ───────────────────────────────
echo "[8/8] Servizio systemd..."
sudo tee /etc/systemd/system/${SERVICE}.service > /dev/null << EOF
[Unit]
Description=Archivio Detti
After=network.target sound.target
Wants=network-online.target

[Service]
User=$USER
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV}/bin/python3 ${INSTALL_DIR}/archivio_detti.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE}
sudo systemctl start ${SERVICE}

# ── Rpi Connect ───────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Setup completato!"
echo "══════════════════════════════════════════════════════"
echo ""
echo "Stato servizio:"
sudo systemctl status ${SERVICE} --no-pager | head -5
echo ""
echo "Comandi utili:"
echo "  Log in tempo reale:  sudo journalctl -u ${SERVICE} -f"
echo "  Riavvia servizio:    sudo systemctl restart ${SERVICE}"
echo "  Ferma servizio:      sudo systemctl stop ${SERVICE}"
echo ""
echo "Rpi Connect (accesso remoto):"
echo "  rpi-connect signin"
echo "  Poi vai su: connect.raspberrypi.com"
echo ""
