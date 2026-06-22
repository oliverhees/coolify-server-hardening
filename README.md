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

## Nutzung — One-Liner

Frischer Hetzner-Server, eingeloggt **als root**. Script laden und ausführen:

```bash
curl -fsSL https://raw.githubusercontent.com/oliverhees/coolify-server-hardening/main/scripts/harden-coolify-server.sh -o harden.sh && bash harden.sh
```

> **Warum nicht `curl … | bash`?** Das Script ist interaktiv (fragt Username,
> Port, Key ab). Bei `curl | bash` wäre stdin die Pipe statt dein Terminal —
> die Abfragen würden übersprungen. Darum erst laden, dann ausführen.
> Alternativ (nur bash, nicht sh): `bash <(curl -fsSL …/harden-coolify-server.sh)`

Das Script fragt interaktiv ab:
- Username + Passwort des neuen sudo-Users
- Externer SSH-Port (Standard 2222)
- Hostname (optional)
- SSH-Public-Key (oder vorhandene root-Keys übernehmen)
- Ob Coolify direkt installiert werden soll

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

1. **SSH testen** (aktuelle Sitzung offen lassen!):
   ```bash
   ssh -p <PORT> <user>@<server-ip>
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
