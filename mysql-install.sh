#!/bin/bash
# =============================================================================
# Parts Tracker demo - DATABASE tier
#
# Installs MySQL 8 and creates one admin login ("dbadmin") that the web tier
# uses over the network to create its own database. The database server stays
# generic: nothing here is specific to the Parts Tracker app.
#
# Morpheus task:   Shell Script, source = this repo, execute target = Resource
# Morpheus inputs: cypher  secret/demo/db_admin   (letters, digits . _ - only)
# Runs on:         Ubuntu 24.04 (DameNet Ubuntu images)
# =============================================================================
set -euo pipefail

# --- Filled in by Morpheus at run time ---------------------------------------
DB_ADMIN_PW="<%=cypher.read('secret/demo/db_admin')%>"

# --- Settings ----------------------------------------------------------------
# Hosts allowed to log in as dbadmin (MySQL wildcard). Server VLAN by default.
ADMIN_HOSTS="172.30.20.%"
ADMIN_CIDR="172.30.20.0/24"

log() { echo "[parts-db] $*"; }
fail() { echo "[parts-db] ERROR: $*" >&2; exit 1; }

# --- Checks ------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || fail "must run as root (Morpheus runs resource tasks with sudo)"
# An unfilled or missing cypher fails this format check too.
echo "$DB_ADMIN_PW" | grep -Eq '^[A-Za-z0-9._-]{8,}$' \
  || fail "cypher secret/demo/db_admin is missing or not 8+ characters of letters, digits, . _ or - (Tools > Cypher)"

# --- Install -----------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
log "Installing MySQL server"
apt-get update -y -q
apt-get install -y -q mysql-server

# Listen on all interfaces so the web tier can connect.
CNF=/etc/mysql/mysql.conf.d/mysqld.cnf
if grep -q '^bind-address' "$CNF"; then
  sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' "$CNF"
else
  printf '\n[mysqld]\nbind-address = 0.0.0.0\n' >> "$CNF"
fi
systemctl enable mysql
systemctl restart mysql

# Open the firewall only if ufw is active (it is off on stock cloud images).
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
  log "ufw active - allowing 3306 from $ADMIN_CIDR"
  ufw allow from "$ADMIN_CIDR" to any port 3306 proto tcp
fi

# --- Admin login -------------------------------------------------------------
# root keeps Ubuntu's socket login (sudo mysql), so this script can be re-run.
log "Creating dbadmin@'$ADMIN_HOSTS'"
mysql --protocol=socket -uroot <<SQL
CREATE USER IF NOT EXISTS 'dbadmin'@'$ADMIN_HOSTS' IDENTIFIED WITH mysql_native_password BY '$DB_ADMIN_PW';
ALTER USER 'dbadmin'@'$ADMIN_HOSTS' IDENTIFIED WITH mysql_native_password BY '$DB_ADMIN_PW';
GRANT ALL PRIVILEGES ON *.* TO 'dbadmin'@'$ADMIN_HOSTS' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

log "MySQL $(mysql --version | awk '{print $3}') is running and accepting connections from $ADMIN_CIDR"
