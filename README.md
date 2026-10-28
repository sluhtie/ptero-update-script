# ptero-upgrade

Upgrade a native **Pterodactyl Panel 1.x** installation to **Pterodactyl 2.0** with one script.
It follows the official guide [Upgrading From 1.x](https://docs.pterodactyl.io/v2/upgrading/upgrading-from-v1)
step by step and adds pre-flight checks, automatic backups, safety prompts and a one-command rollback.

**[Deutsch](#deutsch)** · **[English](#english)**

> [!WARNING]
> Pterodactyl 2.0 is an **open beta**. The official guide asks you to try the upgrade on a copy of your
> panel first ([Testing the Upgrade](https://docs.pterodactyl.io/v2/upgrading/testing-the-upgrade)).
> This is a community script, not an official Pterodactyl tool. Use it at your own risk.

---

## Deutsch

### Was das Script macht

1. **Prüft vorher alles**, ohne etwas zu ändern: root, Betriebssystem, Panel-Version (mind. 1.12.0),
   PHP-Version (8.3/8.4) und Extensions (u. a. `intl`), Composer 2, Datenbankzugang und -version, offene 1.x-Migrationen,
   Webserver (NGINX, Apache, Caddy), Queue-Worker (`pteroq`), freier Speicherplatz und welches 2.0-Release es gibt.
2. **Installiert fehlende Abhängigkeiten** auf Nachfrage: PHP 8.3/8.4 nach der offiziellen
   [PHP-Upgrade-Anleitung](https://docs.pterodactyl.io/v2/guides/configuration/php-upgrade) und fehlende Extensions.
3. **Lädt 2.0 in ein neues Verzeichnis** (`/var/www/pterodactyl-2.0`) und installiert die Composer-Abhängigkeiten,
   *während das alte Panel noch läuft*. Schlägt das fehl, bleibt 1.x unverändert.
4. **Wartungsmodus an**, Queue-Worker stoppen.
5. **Backup** nach `/root/ptero-upgrade-<datum>/`: Datenbank-Dump, `.env` (mit deinem `APP_KEY`),
   komplettes Panel-Verzeichnis als `.tar.gz` und deine Webserver-Konfiguration.
6. **Datenbank migrieren**. Schlägt die Migration fehl, bietet das Script an, die Datenbank sofort
   aus dem Backup wiederherzustellen und 1.x wieder online zu bringen.
7. **Verzeichnisse tauschen**: 1.x wird zu `/var/www/pterodactyl-1.x`, 2.0 wird zu `/var/www/pterodactyl`.
8. **Webserver anpassen**: fügt den neuen `/assets/`-Block in NGINX bzw. Apache ein
   (mit Konfig-Test und automatischem Zurücksetzen bei Fehlern). Bei Caddy wird dir der Block angezeigt.
9. Caches leeren, PHP-FPM und Queue-Worker neu starten, **Wartungsmodus aus**, kurzer HTTP-Check.

Gameserver und Wings laufen die ganze Zeit weiter, nur das Panel ist kurz offline.

### Voraussetzungen

- Native Installation nach der offiziellen 1.x-Anleitung (kein Docker)
- Ubuntu 22.04 / 24.04 / 26.04 oder Debian 12 / 13 (andere Systeme: nur Warnung, Pakete musst du selbst installieren)
- Panel **1.12.0 oder neuer** (am besten vorher auf die neueste 1.x aktualisieren)
- MySQL/MariaDB (getestet von Pterodactyl: MariaDB 10.11/11, MySQL 8/9)
- root-Rechte

### Vor dem Upgrade beachten

- **Billing-Modul (z. B. WHMCS) zuerst aktualisieren.** 2.0 entfernt die Nest-Endpunkte der Application API
  (`/api/application/nests/...`).
- **Themes, Addons und eigene Code-Änderungen werden nicht übernommen.** Nur die `.env` wird kopiert.
  (Blueprint wird erkannt und es gibt eine Warnung.)
- Nests werden in 2.0 durch **Tags** ersetzt. Prüfe nach dem Upgrade unter *Admin → Eggs* die Tags.

### Benutzung

```bash
# Script herunterladen
curl -fsSLo ptero-upgrade.sh https://raw.githubusercontent.com/sluhtie/ptero-update-script/main/ptero-upgrade.sh
chmod +x ptero-upgrade.sh

# 1. Nur prüfen, ändert nichts
sudo ./ptero-upgrade.sh --check

# 2. Upgrade starten
sudo ./ptero-upgrade.sh
```

Das Script zeigt dir vor dem Start einen Plan mit allen Warnungen und fragt dann nach einer Bestätigung
(du musst `UPGRADE` eintippen). Die komplette Ausgabe wird nach `/var/log/ptero-upgrade-<datum>.log` geschrieben.

### Zurück zu 1.x (Rollback)

Am Ende zeigt das Script den passenden Befehl an, z. B.:

```bash
sudo ./ptero-upgrade.sh --rollback /root/ptero-upgrade-20261028-120000
```

Das tauscht die Verzeichnisse zurück, stellt die Datenbank und die Webserver-Konfiguration aus dem Backup wieder her
und startet 1.x. **Achtung:** Alles, was im Panel nach dem Upgrade geändert wurde, geht verloren. Auf 2.0 erstellte
Server bleiben auf den Wings-Nodes liegen, auf 2.0 geänderte Datenbank-Passwörter musst du neu setzen.
Nutze **nie** `php artisan migrate:rollback`.

Behalte `/var/www/pterodactyl-1.x` und den Backup-Ordner, bis du sicher bist, dass alles läuft.
**Sichere die `.env` zusätzlich an einem anderen Ort**: ohne den `APP_KEY` sind Node-Tokens,
2FA-Secrets und API-Keys nicht mehr lesbar.

---

## English

### What it does

1. **Pre-flight checks** that change nothing: root, OS, panel version (1.12.0+), PHP version (8.3/8.4) and
   extensions (including `intl`), Composer 2, database access and version, pending 1.x migrations, web server (NGINX, Apache, Caddy),
   queue worker (`pteroq`), free disk space, and the newest 2.0 release.
2. **Installs missing dependencies** when you agree: PHP 8.3/8.4 following the official
   [PHP upgrade guide](https://docs.pterodactyl.io/v2/guides/configuration/php-upgrade), and missing extensions.
3. **Downloads 2.0 into a new directory** (`/var/www/pterodactyl-2.0`) and runs `composer install`
   *while 1.x is still online*. If this fails, 1.x is untouched.
4. **Maintenance mode on**, queue worker stopped.
5. **Backup** to `/root/ptero-upgrade-<date>/`: database dump, `.env` (holds your `APP_KEY`), the whole panel
   directory as `.tar.gz`, and your web server config.
6. **Database migration.** If it fails, the script offers to restore the database from the backup right away
   and brings 1.x back online.
7. **Directory swap**: 1.x becomes `/var/www/pterodactyl-1.x`, 2.0 becomes `/var/www/pterodactyl`.
8. **Web server update**: adds the new `/assets/` block for NGINX or Apache (config test, automatic revert on
   failure). For Caddy the snippet is printed for you to add.
9. Clears caches, restarts PHP-FPM and the queue worker, **maintenance mode off**, quick HTTP check.

Game servers and Wings keep running; only the panel is briefly offline.

### Requirements

- Native install following the official 1.x guide (not Docker)
- Ubuntu 22.04 / 24.04 / 26.04 or Debian 12 / 13 (other systems get a warning; install packages yourself)
- Panel **1.12.0 or newer** (ideally update to the latest 1.x first)
- MySQL/MariaDB (tested by Pterodactyl: MariaDB 10.11/11, MySQL 8/9)
- root

### Before you upgrade

- **Update your billing module (e.g. WHMCS) first.** 2.0 removes the Application API nest endpoints
  (`/api/application/nests/...`).
- **Themes, addons and code changes are not carried over.** Only `.env` is copied. (Blueprint is detected and warned about.)
- Nests are replaced by **tags** in 2.0. Review your eggs under *Admin → Eggs* afterwards.

### Usage

```bash
curl -fsSLo ptero-upgrade.sh https://raw.githubusercontent.com/sluhtie/ptero-update-script/main/ptero-upgrade.sh
chmod +x ptero-upgrade.sh

sudo ./ptero-upgrade.sh --check   # dry run, changes nothing
sudo ./ptero-upgrade.sh           # upgrade
```

You get a plan with all warnings first and have to type `UPGRADE` to start.
Everything is logged to `/var/log/ptero-upgrade-<date>.log`.

### Rollback

```bash
sudo ./ptero-upgrade.sh --rollback /root/ptero-upgrade-<date>
```

Swaps the directories back, restores the database and web server config from the backup and starts 1.x.
Anything changed in the panel after the upgrade is lost; servers created on 2.0 stay on your Wings nodes and
database passwords changed on 2.0 must be rotated again. Never use `php artisan migrate:rollback`.

---

## Options

| Option | Description |
|---|---|
| `-d, --dir <path>` | Panel directory (default `/var/www/pterodactyl`) |
| `-r, --release <tag>` | 2.x release to install, e.g. `v2.0.0-beta.2` (default: newest 2.x on GitHub) |
| `-b, --backup-dir <path>` | Where backups are created (default `/root`) |
| `-w, --webserver <name>` | `nginx`, `apache`, `caddy` or `none` (default: auto-detect) |
| `-u, --web-user <user>` | Web server user (default: owner of the panel directory, else `www-data`) |
| `-q, --queue-service <name>` | Queue worker systemd unit (default `pteroq`) |
| `-p, --php <version>` | PHP version to install if PHP is older than 8.3 (`8.3` or `8.4`, default `8.3`) |
| `--seed-eggs` / `--no-seed-eggs` | Update the default eggs after migrating (`db:seed`), asked by default |
| `-c, --check` | Only run the checks |
| `-y, --yes` | Non-interactive, answer every prompt with yes |
| `--rollback <dir>` | Roll back to 1.x using a backup made by this script |

## What it does not do

- Upgrade Wings. Wings 1.13.2+ works with the 2.0 panel; upgrade it later.
- Migrate to the Docker image.
- Carry over themes, Blueprint extensions or source code changes.

## Disclaimer

Not affiliated with or endorsed by the Pterodactyl project. Provided as is, without warranty.
Always keep your own backups.

## License

[MIT](LICENSE)
