#!/usr/bin/env bash
#
# harden-coolify-server.sh
# ------------------------------------------------------------------------------
# One-Shot Server-Hardening für einen frischen Hetzner-Server (Ubuntu/Debian),
# der anschließend Coolify hosten soll.
#
# Inspiriert vom hermes-agent-oneshot-installer, aber mit den Coolify-typischen
# Fallstricken berücksichtigt:
#   - Coolify verbindet sich per SSH zu SICH SELBST (localhost / Docker-Bridge)
#     als root mit Key. Darum: PermitRootLogin prohibit-password (NICHT "no")
#     und SSH bleibt intern auf Port 22 erreichbar.
#   - Externer SSH läuft auf einem custom Port; Port 22 ist von außen dicht,
#     intern (Docker-Subnetz/loopback) aber offen -> Coolify-Selbstverwaltung
#     funktioniert weiter.
#   - Docker umgeht UFW. UFW schützt nur den Host. Für veröffentlichte
#     Container-Ports IMMER zusätzlich die Hetzner Cloud Firewall nutzen.
#
# Einmalig als root auf dem frischen Server ausführen:
#   bash harden-coolify-server.sh
#
# ------------------------------------------------------------------------------
set -euo pipefail

# ─── Farben & Logging ─────────────────────────────────────────────────────────
readonly C_RESET='\033[0m'
readonly C_INFO='\033[0;32m'   # grün
readonly C_WARN='\033[0;33m'   # gelb
readonly C_ERR='\033[0;31m'    # rot
readonly C_STEP='\033[1;36m'   # cyan, fett

log()  { echo -e "${C_INFO}[INFO]${C_RESET} $*"; }
warn() { echo -e "${C_WARN}[WARN]${C_RESET} $*"; }
err()  { echo -e "${C_ERR}[FEHLER]${C_RESET} $*" >&2; }
step() { echo -e "\n${C_STEP}━━━ $* ━━━${C_RESET}"; }
die()  { err "$*"; exit 1; }

# Bei Abbruch klare Meldung
trap 'err "Script wurde bei Zeile $LINENO abgebrochen. Es wurde NICHT alles ausgeführt."' ERR

# ─── Vorbedingungen ───────────────────────────────────────────────────────────
[[ ${EUID} -eq 0 ]] || die "Bitte als root ausführen (z.B. via 'sudo bash $0' oder direkt als root)."

if [[ ! -f /etc/os-release ]]; then
  die "/etc/os-release fehlt — wird dieses OS nicht unterstützt?"
fi
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) log "Erkanntes OS: ${PRETTY_NAME:-$ID}" ;;
  *) warn "Nicht getestetes OS: ${PRETTY_NAME:-$ID}. Script ist für Ubuntu/Debian gebaut." ;;
esac

command -v apt-get >/dev/null 2>&1 || die "apt-get nicht gefunden — Script setzt Debian/Ubuntu voraus."

echo -e "${C_STEP}"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║   Coolify Server-Hardening  ·  Hetzner / Ubuntu / Debian      ║
║   Hardening + Firewall + fail2ban + (optional) Coolify        ║
╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${C_RESET}"

# ─── Interaktive Konfiguration ────────────────────────────────────────────────
step "Konfiguration"

# Username
while true; do
  read -rp "Name des neuen sudo-Users (z.B. oliver): " NEW_USER
  if [[ "${NEW_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    break
  fi
  warn "Ungültiger Username. Erlaubt: kleinbuchstaben, ziffern, _ und - (Start mit Buchstabe/_)."
done

# Passwort (für sudo; SSH-Login bleibt key-only)
while true; do
  read -rsp "Passwort für ${NEW_USER} (wird für sudo gebraucht): " NEW_PASS; echo
  read -rsp "Passwort wiederholen: " NEW_PASS2; echo
  if [[ -z "${NEW_PASS}" ]]; then
    warn "Passwort darf nicht leer sein."
  elif [[ "${NEW_PASS}" != "${NEW_PASS2}" ]]; then
    warn "Passwörter stimmen nicht überein."
  else
    break
  fi
done

# SSH-Port (extern)
while true; do
  read -rp "Externer SSH-Port [Standard: 2222]: " SSH_PORT
  SSH_PORT="${SSH_PORT:-2222}"
  if [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )) && (( SSH_PORT != 22 )); then
    break
  fi
  warn "Bitte Port zwischen 1024 und 65535 wählen (nicht 22 — 22 bleibt intern für Coolify reserviert)."
done

# Hostname (optional)
read -rp "Hostname setzen? (leer lassen = unverändert): " NEW_HOSTNAME

# SSH-Key des neuen Users
echo
log "Der neue User braucht einen SSH-Public-Key für den passwortlosen Login."
EXISTING_ROOT_KEYS=""
if [[ -f /root/.ssh/authorized_keys ]] && [[ -s /root/.ssh/authorized_keys ]]; then
  EXISTING_ROOT_KEYS="$(grep -c . /root/.ssh/authorized_keys || true)"
fi

PUBKEY=""
if [[ -n "${EXISTING_ROOT_KEYS}" ]] && (( EXISTING_ROOT_KEYS > 0 )); then
  log "In /root/.ssh/authorized_keys liegen bereits ${EXISTING_ROOT_KEYS} Key(s)."
  read -rp "Diese Keys auf '${NEW_USER}' übernehmen? [J/n]: " COPY_ROOT_KEYS
  COPY_ROOT_KEYS="${COPY_ROOT_KEYS:-J}"
else
  COPY_ROOT_KEYS="n"
  warn "Keine Keys in /root/.ssh/authorized_keys gefunden."
fi

if [[ ! "${COPY_ROOT_KEYS}" =~ ^[JjYy]$ ]]; then
  echo "Bitte deinen kompletten SSH-Public-Key einfügen (eine Zeile, z.B. 'ssh-ed25519 AAAA... kommentar'):"
  read -rp "> " PUBKEY
  if [[ ! "${PUBKEY}" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-) ]]; then
    die "Das sieht nicht nach einem gültigen SSH-Public-Key aus. Abbruch (kein Aussperr-Risiko eingegangen)."
  fi
fi

# Coolify installieren?
echo
read -rp "Coolify am Ende automatisch installieren? [J/n]: " INSTALL_COOLIFY
INSTALL_COOLIFY="${INSTALL_COOLIFY:-J}"

# ─── Zusammenfassung & Bestätigung ────────────────────────────────────────────
step "Zusammenfassung"
cat <<EOF
  Neuer sudo-User .......... ${NEW_USER}
  Externer SSH-Port ........ ${SSH_PORT}   (Port 22 bleibt nur intern für Coolify)
  Hostname ................. ${NEW_HOSTNAME:-(unverändert)}
  SSH-Keys ................. $([[ "${COPY_ROOT_KEYS}" =~ ^[JjYy]$ ]] && echo "von root übernommen" || echo "neu eingegeben")
  Root-Login (extern) ...... deaktiviert für Passwort, Key-only intern (Coolify)
  Passwort-Login (SSH) ..... deaktiviert
  fail2ban / UFW / Updates . werden eingerichtet
  Coolify installieren ..... $([[ "${INSTALL_COOLIFY}" =~ ^[JjYy]$ ]] && echo "ja" || echo "nein")
EOF
echo
read -rp "Alles korrekt? Dann mit 'JA' bestätigen: " CONFIRM
[[ "${CONFIRM}" == "JA" ]] || die "Abgebrochen — nichts wurde verändert."

export DEBIAN_FRONTEND=noninteractive

# ─── 1. System aktualisieren ──────────────────────────────────────────────────
step "1/9 · System aktualisieren"
apt-get update -y
apt-get upgrade -y
apt-get install -y --no-install-recommends \
  ufw fail2ban unattended-upgrades curl ca-certificates gnupg \
  software-properties-common chrony
log "Basis-Pakete installiert."

# ─── 2. Hostname & Zeitzone ───────────────────────────────────────────────────
step "2/9 · Hostname & Zeit"
if [[ -n "${NEW_HOSTNAME}" ]]; then
  hostnamectl set-hostname "${NEW_HOSTNAME}"
  if ! grep -q "${NEW_HOSTNAME}" /etc/hosts; then
    echo "127.0.1.1   ${NEW_HOSTNAME}" >> /etc/hosts
  fi
  log "Hostname gesetzt: ${NEW_HOSTNAME}"
fi
timedatectl set-timezone Europe/Berlin || warn "Zeitzone konnte nicht gesetzt werden."
systemctl enable --now chrony >/dev/null 2>&1 || true
log "Zeitzone Europe/Berlin, Zeitsync via chrony aktiv."

# ─── 3. Sudo-User anlegen ─────────────────────────────────────────────────────
step "3/9 · Sudo-User '${NEW_USER}' anlegen"
if id "${NEW_USER}" >/dev/null 2>&1; then
  warn "User '${NEW_USER}' existiert bereits — überspringe Anlegen, setze nur Gruppen/Keys."
else
  adduser --disabled-password --gecos "" "${NEW_USER}"
  log "User '${NEW_USER}' angelegt."
fi
echo "${NEW_USER}:${NEW_PASS}" | chpasswd
usermod -aG sudo "${NEW_USER}"
# docker-Gruppe vorsorglich anlegen (Coolify installiert Docker später)
groupadd -f docker
usermod -aG docker "${NEW_USER}"
log "User in Gruppen 'sudo' und 'docker'."

# SSH-Keys einrichten
USER_SSH_DIR="/home/${NEW_USER}/.ssh"
install -d -m 700 -o "${NEW_USER}" -g "${NEW_USER}" "${USER_SSH_DIR}"
if [[ "${COPY_ROOT_KEYS}" =~ ^[JjYy]$ ]]; then
  cp /root/.ssh/authorized_keys "${USER_SSH_DIR}/authorized_keys"
else
  echo "${PUBKEY}" > "${USER_SSH_DIR}/authorized_keys"
fi
chown "${NEW_USER}:${NEW_USER}" "${USER_SSH_DIR}/authorized_keys"
chmod 600 "${USER_SSH_DIR}/authorized_keys"
log "authorized_keys für '${NEW_USER}' eingerichtet."

# ─── 4. Swap (gut für kleine Hetzner-Instanzen, Coolify empfiehlt Swap) ───────
step "4/9 · Swap einrichten"
if swapon --show | grep -q .; then
  log "Swap ist bereits aktiv — überspringe."
else
  # Swap = RAM-Größe, gedeckelt auf 4G
  MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  SWAP_MB=$(( MEM_MB > 4096 ? 4096 : MEM_MB ))
  log "Lege ${SWAP_MB}MB Swapfile an…"
  fallocate -l "${SWAP_MB}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_MB}"
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  # Swappiness niedrig: nur unter Druck swappen
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-coolify-swap.conf
  sysctl -p /etc/sysctl.d/99-coolify-swap.conf >/dev/null
  log "Swap aktiv (${SWAP_MB}MB, swappiness=10)."
fi

# ─── 5. Automatische Sicherheitsupdates ───────────────────────────────────────
step "5/9 · Unattended Security-Updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
# Nur Security-Updates automatisch; KEIN automatischer Reboot mitten im Betrieb
sed -i 's|//\s*"\${distro_id}:\${distro_codename}-security";|        "\${distro_id}:\${distro_codename}-security";|' \
  /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
log "Automatische Security-Updates aktiv."

# ─── 6. fail2ban ──────────────────────────────────────────────────────────────
step "6/9 · fail2ban"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# 1h Ban nach 5 Fehlversuchen innerhalb von 10 Minuten
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
ignoreip = 127.0.0.1/8 ::1 172.16.0.0/12

[sshd]
enabled = true
port    = ${SSH_PORT},22
EOF
systemctl enable --now fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban
log "fail2ban aktiv (sshd jail auf Ports ${SSH_PORT} & 22)."

# ─── 7. UFW (Host-Firewall) ───────────────────────────────────────────────────
step "7/9 · UFW Firewall"
warn "WICHTIG: Docker umgeht UFW (NAT-iptables). UFW schützt hier nur den HOST."
warn "Für veröffentlichte Container-Ports MUSST du zusätzlich die Hetzner Cloud Firewall nutzen!"

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing

# Externer SSH-Port (öffentlich erreichbar)
ufw allow "${SSH_PORT}/tcp" comment 'SSH (extern)'
# Port 22 NUR aus den Docker-Subnetzen erlauben -> Coolify-Selbstverwaltung.
# Von außen bleibt 22 dicht (kein 'allow 22/tcp' für alle).
ufw allow from 172.16.0.0/12 to any port 22 proto tcp comment 'SSH intern fuer Coolify (Docker-Bridge)'
ufw allow from 10.0.0.0/8    to any port 22 proto tcp comment 'SSH intern (Docker/privat)'
# Web + Coolify-Ports
ufw allow 80/tcp   comment 'HTTP'
ufw allow 443/tcp  comment 'HTTPS'
ufw allow 8000/tcp comment 'Coolify Dashboard'
ufw allow 6001/tcp comment 'Coolify Realtime/WebSocket'
ufw allow 6002/tcp comment 'Coolify Terminal'
ufw --force enable
log "UFW aktiv. Offen extern: ${SSH_PORT}, 80, 443, 8000, 6001, 6002. Port 22 nur intern."

# ─── 8. SSH-Hardening ─────────────────────────────────────────────────────────
step "8/9 · SSH härten"

# Verifizieren, dass der neue User wirklich einen Key hat -> Aussperr-Schutz
if [[ ! -s "${USER_SSH_DIR}/authorized_keys" ]]; then
  die "ABBRUCH: '${NEW_USER}' hat keine authorized_keys. SSH wird NICHT gehärtet, damit du dich nicht aussperrst."
fi

# Backup der originalen Config
SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "${SSHD_BACKUP}"
log "Backup der sshd_config: ${SSHD_BACKUP}"

# Eigene Hardening-Datei in conf.d (sauberer als sshd_config zu patchen)
cat > /etc/ssh/sshd_config.d/00-coolify-hardening.conf <<EOF
# Erzeugt von harden-coolify-server.sh
# Externer SSH-Port + interner Port 22 (für Coolify-Selbstverwaltung)
Port ${SSH_PORT}
Port 22

# Key-only. PermitRootLogin = prohibit-password ist PFLICHT für Coolify,
# weil Coolify sich als root per Key zu localhost/Docker-Bridge verbindet.
# (NICHT auf "no" setzen — das legt Coolifys Selbstverwaltung lahm!)
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

# Sonstige Härtung
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

# Validieren bevor Neustart
if ! sshd -t; then
  err "sshd-Konfiguration ist fehlerhaft! Stelle Backup wieder her."
  rm -f /etc/ssh/sshd_config.d/00-coolify-hardening.conf
  cp "${SSHD_BACKUP}" /etc/ssh/sshd_config
  die "SSH NICHT verändert. Bitte Config prüfen."
fi

# Ubuntu 22.10+ nutzt ssh.socket statt ssh.service -> Socket-Override für Port
if systemctl is-active ssh.socket >/dev/null 2>&1; then
  warn "ssh.socket ist aktiv — deaktiviere Socket-Aktivierung, damit Port-Direktiven greifen."
  systemctl disable --now ssh.socket >/dev/null 2>&1 || true
  systemctl enable --now ssh.service >/dev/null 2>&1 || systemctl enable --now sshd.service >/dev/null 2>&1 || true
fi

systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || die "SSH-Dienst-Neustart fehlgeschlagen."
log "SSH gehärtet & neu gestartet."

echo
warn "═══════════════════════════════════════════════════════════════"
warn " JETZT TESTEN — ÖFFNE EINE ZWEITE SSH-SITZUNG, bevor du diese hier schließt!"
warn "   ssh -p ${SSH_PORT} ${NEW_USER}@<server-ip>"
warn " Funktioniert sie NICHT, stelle wieder her mit:"
warn "   cp ${SSHD_BACKUP} /etc/ssh/sshd_config && rm /etc/ssh/sshd_config.d/00-coolify-hardening.conf && systemctl restart ssh"
warn "═══════════════════════════════════════════════════════════════"
echo

# ─── 9. Coolify (optional) ────────────────────────────────────────────────────
step "9/9 · Coolify"
if [[ "${INSTALL_COOLIFY}" =~ ^[JjYy]$ ]]; then
  read -rp "SSH-Login wurde in der zweiten Sitzung getestet und funktioniert? Coolify jetzt installieren? [j/N]: " GO
  if [[ "${GO}" =~ ^[JjYy]$ ]]; then
    log "Installiere Coolify (offizielles Script). Docker wird dabei mitinstalliert…"
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
    log "Coolify-Installation abgeschlossen."
  else
    warn "Coolify übersprungen. Später manuell: curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash"
  fi
else
  log "Coolify wird nicht automatisch installiert."
  log "Später: curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash"
fi

# ─── Abschluss ────────────────────────────────────────────────────────────────
trap - ERR
step "Fertig ✓"
cat <<EOF

  Was jetzt noch wichtig ist:

  1) SSH-Test: Lass die aktuelle Sitzung OFFEN und logge dich parallel neu ein:
       ssh -p ${SSH_PORT} ${NEW_USER}@<server-ip>

  2) Hetzner Cloud Firewall (PFLICHT, weil Docker UFW umgeht):
       Im Hetzner Cloud Panel eine Firewall anlegen und nur erlauben:
         - TCP ${SSH_PORT}  (SSH)
         - TCP 80, 443      (Web)
       Die Ports 8000 / 6001 / 6002 nur temporär öffnen, falls du Coolify
       über die IP statt über eine Domain einrichtest — danach wieder zu.

  3) Coolify-Dashboard erreichen:
       http://<server-ip>:8000   (erstes Setup, Admin-Account anlegen)
       Danach eigene Domain + HTTPS in Coolify konfigurieren und 8000/6001/6002
       sowohl in UFW als auch in der Hetzner Firewall wieder schließen.

  4) Coolify-Selbstverwaltung: Der 'localhost'-Server in Coolify nutzt intern
     Port 22 (Docker-Bridge) — bitte NICHT in den SSH-Einstellungen auf den
     externen Port umstellen, sonst bricht die Verbindung.

  Backup der alten SSH-Config: ${SSHD_BACKUP}

EOF
