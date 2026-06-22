# Coolify Server-Hardening (Hetzner / Ubuntu / Debian)

One-Shot-Script, das einen frischen Hetzner-Server härtet und für **Coolify** vorbereitet — im Stil des [hermes-agent-oneshot-installer](https://github.com/oliverhees/hermes-agent-oneshot-installer), aber mit den Coolify-typischen Fallstricken berücksichtigt.

## Was das Script macht

| Schritt | Inhalt |
|--------|--------|
| 1 | System-Update + Basis-Pakete |
| 2 | Hostname + Zeitzone (`Europe/Berlin`) + Zeitsync (chrony) |
| 3 | Neuer sudo-User (in `sudo` + `docker`), SSH-Keys übertragen |
| 4 | Swap-File (RAM-Größe, max. 4 GB, `swappiness=10`) |
| 5 | Automatische Security-Updates (`unattended-upgrades`) |
| 6 | fail2ban (5 Fehlversuche / 10 Min → 1 h Ban) |
| 7 | UFW-Firewall (Host) |
| 8 | SSH-Hardening (key-only, Backup, Validierung, Aussperr-Schutz) |
| 9 | Optionale Coolify-Installation |

## Komplette Anleitung (Schritt für Schritt)

Von „frischer Hetzner-Server" bis „gehärteter Coolify-Server". Alle lokalen
Befehle laufen auf deinem Rechner, alle Server-Befehle auf dem Server.

### Schritt 1 — SSH-Key mit eigener Datei erstellen (lokal)

Pro Server einen eigenen Key (nicht den `id_ed25519`-Standardkey mitbenutzen).
`<name>` z.B. den Servernamen verwenden:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/coolify-<name> -C "coolify-<name>"
```

- Passphrase: für deinen **persönlichen Login-Key** gern eine setzen.
- Es entstehen zwei Dateien: `~/.ssh/coolify-<name>` (privat, geheim halten)
  und `~/.ssh/coolify-<name>.pub` (öffentlich, kommt auf den Server).

Public-Key anzeigen (brauchst du gleich):

```bash
cat ~/.ssh/coolify-<name>.pub
```

### Schritt 2 — Hetzner-Server mit diesem Key erstellen

Im Hetzner Cloud Panel beim Erstellen des Servers:

1. **Image:** Ubuntu 24.04
2. **SSH Keys:** „SSH key hinzufügen" → den Inhalt von `coolify-<name>.pub`
   einfügen. So ist der Server von Anfang an key-only (kein Root-Passwort,
   kein „Too many authentication failures"-Gefummel).

> Der Key landet automatisch in `/root/.ssh/authorized_keys` auf dem Server.

### Schritt 3 — Per SSH verbinden

Wichtig: **`-i` + `IdentitiesOnly=yes`**, damit nur dieser eine Key angeboten
wird. Ohne das bietet dein SSH-Agent alle Keys an, und der Server bricht nach
6 Versuchen mit `Too many authentication failures` ab.

```bash
ssh -i ~/.ssh/coolify-<name> -o IdentitiesOnly=yes root@<server-ip>
```

**Komfort-Variante** (empfohlen): einmalig in `~/.ssh/config` eintragen…

```
Host coolify-<name>
    HostName <server-ip>
    User root
    IdentityFile ~/.ssh/coolify-<name>
    IdentitiesOnly yes
```

…danach reicht `ssh coolify-<name>`.

### Schritt 4 — Hardening-Script laden und ausführen

Auf dem Server (als root):

```bash
curl -fsSL https://raw.githubusercontent.com/oliverhees/coolify-server-hardening/main/scripts/harden-coolify-server.sh -o harden.sh && bash harden.sh
```

> **Warum nicht `curl … | bash`?** Das Script ist interaktiv. Bei `curl | bash`
> wäre stdin die Pipe statt dein Terminal — die Abfragen würden übersprungen.
> Darum erst laden, dann ausführen. (Nur-bash-Alternative:
> `bash <(curl -fsSL …/harden-coolify-server.sh)`)
>
> **Nicht über die Hetzner-Web-Konsole einfügen!** Die VNC-Konsole verstümmelt
> lange Befehle mit Sonderzeichen (`://` wird zu `: //`, `&&` zu `77`). Immer
> über echtes SSH (Schritt 3) arbeiten.

Das Script fragt interaktiv ab:
- Username + Passwort des neuen sudo-Users
- Externer SSH-Port (Standard 2222)
- Hostname (optional)
- SSH-Public-Key — hier **„von root übernehmen" mit `J` bestätigen**, dann
  bekommt dein neuer sudo-User denselben `coolify-<name>`-Key
- Ob Coolify direkt installiert werden soll (falls schon installiert: `n`)

### Schritt 5 — Neuen Zugang testen (BEVOR du die alte Sitzung schließt!)

Die alte Root-Sitzung **offen lassen**. In einem **zweiten** Terminal mit dem
neuen User + neuen Port verbinden (derselbe Key wurde ja übernommen):

```bash
ssh -i ~/.ssh/coolify-<name> -o IdentitiesOnly=yes -p <PORT> <user>@<server-ip>
```

Erst wenn das klappt, ist Aussperren ausgeschlossen — dann erst die alte
Sitzung schließen. Klappt es nicht → in der noch offenen Root-Sitzung die
Wiederherstellung unten ausführen.

### Schritt 6 — Hetzner Cloud Firewall + Coolify

Weiter mit „Nach dem Script — Pflicht-Schritte" (Cloud Firewall) und ggf.
Coolify-Setup weiter unten.

## ⚠️ Die drei Coolify-Fallstricke (warum dieses Script anders ist)

1. **`PermitRootLogin` darf NICHT `no` sein.**
   Coolify verwaltet sich selbst über eine SSH-Verbindung als root zu sich
   selbst. Darum wird `prohibit-password` gesetzt (root-Login nur per Key,
   nie per Passwort). `no` würde Coolifys Selbstverwaltung lahmlegen.

2. **Port 22 bleibt intern offen.**
   Coolify verbindet sich intern über die Docker-Bridge
   (`host.docker.internal` → ~172.17.0.1) auf **Port 22**. Externer SSH läuft
   auf dem custom Port; Port 22 ist von außen via Firewall dicht, aber für die
   Docker-Subnetze (`172.16.0.0/12`, `10.0.0.0/8`) freigegeben.
   → **Den `localhost`-Server in Coolify NICHT auf den externen Port umstellen.**

3. **Docker umgeht UFW.**
   Docker schreibt eigene NAT-/iptables-Regeln, die UFW umgehen. UFW schützt
   hier **nur den Host**, nicht die von Containern veröffentlichten Ports.
   → Die **Hetzner Cloud Firewall ist Pflicht**, nicht optional.

## Nach dem Script — Pflicht-Schritte

1. **SSH testen** (aktuelle Sitzung offen lassen!) — siehe Schritt 5 oben:
   ```bash
   ssh -i ~/.ssh/coolify-<name> -o IdentitiesOnly=yes -p <PORT> <user>@<server-ip>
   ```
   Falls es nicht klappt — Wiederherstellung steht am Ende der Script-Ausgabe.

2. **Hetzner Cloud Firewall** im Hetzner-Panel anlegen, nur erlauben:
   - TCP `<SSH-PORT>`
   - TCP 80, 443
   - 8000 / 6001 / 6002 nur temporär, falls Coolify-Ersteinrichtung über die IP

3. **Coolify-Dashboard**: `http://<server-ip>:8000`, Admin anlegen,
   eigene Domain + HTTPS einrichten, danach 8000/6001/6002 wieder schließen
   (in UFW **und** Hetzner Firewall).

## Offene Ports nach dem Hardening

| Port | extern | Zweck |
|------|:------:|-------|
| `<custom>` | ✅ | SSH (extern) |
| 22 | ❌ (nur intern) | Coolify-Selbstverwaltung |
| 80 / 443 | ✅ | Web / TLS |
| 8000 / 6001 / 6002 | ✅* | Coolify-Setup — nach Domain-Setup schließen |

\* In UFW offen; via Hetzner Cloud Firewall steuern und nach Setup schließen.

## Wiederherstellung (falls ausgesperrt)

Das Script legt vor jeder SSH-Änderung ein Backup an
(`/etc/ssh/sshd_config.bak.<timestamp>`) und validiert die neue Config mit
`sshd -t`, bevor SSH neu startet. Über die Hetzner-Konsole (VNC im Panel):

```bash
cp /etc/ssh/sshd_config.bak.<timestamp> /etc/ssh/sshd_config
rm /etc/ssh/sshd_config.d/00-coolify-hardening.conf
systemctl restart ssh
```

## Quellen

- [Coolify Docs — OpenSSH](https://coolify.io/docs/knowledge-base/server/openssh)
- [Coolify Docs — Firewall](https://coolify.io/docs/knowledge-base/server/firewall)
- [Coolify Docs — Installation](https://coolify.io/docs/installation)
- [Security Hardening Your Coolify Server (MassiveGRID)](https://massivegrid.com/blog/coolify-security-hardening/)
- [hermes-agent-oneshot-installer](https://github.com/oliverhees/hermes-agent-oneshot-installer)
