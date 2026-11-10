#!/bin/bash
# =============================================================================
# Parts Tracker demo - WEB tier
#
# 1. Installs Apache + PHP.
# 2. Connects to the database tier as dbadmin and creates the app's own
#    database, login and sample data (so the DB tier stays generic).
# 3. Deploys the Parts Tracker page (index.php) and a health check (health.php)
#    for Morpheus monitoring.
#
# Morpheus task:   Shell Script, source = this repo, execute target = Resource
# Morpheus inputs: evar    PARTS_DB_IP  (exported by the "Parts DB" instance
#                                        type: set its Environment Prefix to PARTS_DB)
#                  cypher  secret/demo/db_admin
#                  cypher  secret/demo/app_db
# Blueprint:       the Database tier must boot first (boot order 0, this tier 1)
# Runs on:         Ubuntu 24.04 (DameNet Ubuntu images)
# =============================================================================
set -euo pipefail

# --- Filled in by Morpheus at run time ---------------------------------------
DB_HOST="<%=evars.PARTS_DB_IP%>"
DB_ADMIN_PW="<%=cypher.read('secret/demo/db_admin')%>"
APP_DB_PW="<%=cypher.read('secret/demo/app_db')%>"
INSTANCE_NAME="<%=instance.name%>"

# --- Settings ----------------------------------------------------------------
APP_DB="parts"
APP_USER="parts_app"
WEB_ROOT="/var/www/html"
WAIT_FOR_DB_SECONDS=600

log() { echo "[parts-web] $*"; }
fail() { echo "[parts-web] ERROR: $*" >&2; exit 1; }

# --- Checks ------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || fail "must run as root (Morpheus runs resource tasks with sudo)"
echo "$DB_HOST" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || fail "PARTS_DB_IP is empty or not an IP. Deploy from the Parts Tracker blueprint, and set the Parts DB instance type's Environment Prefix to PARTS_DB"
# An unfilled or missing cypher fails this format check too.
for pw in "$DB_ADMIN_PW" "$APP_DB_PW"; do
  echo "$pw" | grep -Eq '^[A-Za-z0-9._-]{8,}$' \
    || fail "cypher secret/demo/db_admin or secret/demo/app_db is missing or not 8+ characters of letters, digits, . _ or -"
done
echo "$INSTANCE_NAME" | grep -Eq '^[A-Za-z0-9._-]+$' || INSTANCE_NAME="$(hostname)"

# --- Install -----------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
log "Installing Apache, PHP and the MySQL client"
apt-get update -y -q
apt-get install -y -q apache2 php libapache2-mod-php php-mysql mysql-client-core-8.0 || \
  apt-get install -y -q apache2 php libapache2-mod-php php-mysql default-mysql-client
systemctl enable apache2

# --- Wait for the database tier ----------------------------------------------
log "Waiting for MySQL on $DB_HOST (up to $WAIT_FOR_DB_SECONDS s)"
export MYSQL_PWD="$DB_ADMIN_PW"
waited=0
until mysql -h "$DB_HOST" -u dbadmin -e 'SELECT 1' >/dev/null 2>&1; do
  [ "$waited" -ge "$WAIT_FOR_DB_SECONDS" ] && fail "could not log in to MySQL on $DB_HOST as dbadmin"
  sleep 10; waited=$((waited + 10))
done

# --- App database, login and sample data -------------------------------------
log "Creating database '$APP_DB' and login '$APP_USER' on $DB_HOST"
mysql -h "$DB_HOST" -u dbadmin <<SQL
CREATE DATABASE IF NOT EXISTS $APP_DB;
CREATE USER IF NOT EXISTS '$APP_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$APP_DB_PW';
ALTER USER '$APP_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$APP_DB_PW';
GRANT SELECT, INSERT, UPDATE, DELETE ON $APP_DB.* TO '$APP_USER'@'%';
FLUSH PRIVILEGES;
CREATE TABLE IF NOT EXISTS $APP_DB.parts (
  id        INT AUTO_INCREMENT PRIMARY KEY,
  part_no   VARCHAR(32)  NOT NULL,
  name      VARCHAR(128) NOT NULL,
  category  VARCHAR(64)  NOT NULL,
  qty       INT          NOT NULL DEFAULT 0,
  added_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO $APP_DB.parts (part_no, name, category, qty)
SELECT * FROM (
  SELECT 'SRV-1001' AS p, 'ProLiant DL380 Gen11 chassis' AS n, 'Servers'    AS c, 4  AS q UNION ALL
  SELECT 'SRV-1002',      '32 GB DDR5 RDIMM',                  'Memory',          48      UNION ALL
  SELECT 'STO-2001',      '1.92 TB NVMe SSD',                  'Storage',         24      UNION ALL
  SELECT 'NET-3001',      '25 GbE dual-port adapter',          'Networking',      12      UNION ALL
  SELECT 'NET-3002',      'Aruba 2930M 24-port switch',        'Networking',      2       UNION ALL
  SELECT 'PWR-4001',      '1600 W power supply',               'Power',           8
) AS seed
WHERE NOT EXISTS (SELECT 1 FROM $APP_DB.parts);
SQL
unset MYSQL_PWD

# --- App config (kept outside the web root) ----------------------------------
mkdir -p /etc/parts-tracker
cat > /etc/parts-tracker/config.php <<CONF
<?php
return [
  'db_host'  => '$DB_HOST',
  'db_name'  => '$APP_DB',
  'db_user'  => '$APP_USER',
  'db_pass'  => '$APP_DB_PW',
  'instance' => '$INSTANCE_NAME',
];
CONF
chown root:www-data /etc/parts-tracker/config.php
chmod 640 /etc/parts-tracker/config.php

# --- App pages ---------------------------------------------------------------
log "Deploying Parts Tracker to $WEB_ROOT"
rm -f "$WEB_ROOT/index.html"

cat > "$WEB_ROOT/index.php" <<'PHP'
<?php
$cfg = require '/etc/parts-tracker/config.php';
mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
$error = null; $parts = []; $notice = null;
try {
    $db = new mysqli($cfg['db_host'], $cfg['db_user'], $cfg['db_pass'], $cfg['db_name']);
    $db->set_charset('utf8mb4');
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $partNo = trim($_POST['part_no'] ?? '');
        $name   = trim($_POST['name'] ?? '');
        $cat    = trim($_POST['category'] ?? '');
        $qty    = (int)($_POST['qty'] ?? 0);
        if ($partNo !== '' && $name !== '' && $cat !== '') {
            $st = $db->prepare('INSERT INTO parts (part_no, name, category, qty) VALUES (?, ?, ?, ?)');
            $st->bind_param('sssi', $partNo, $name, $cat, $qty);
            $st->execute();
            header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?') . '?added=1');
            exit;
        }
        $notice = 'Part number, name and category are required.';
    }
    if (isset($_GET['added'])) { $notice = 'Part added.'; }
    $parts = $db->query('SELECT part_no, name, category, qty, added_at FROM parts ORDER BY category, part_no')->fetch_all(MYSQLI_ASSOC);
} catch (Throwable $e) {
    $error = $e->getMessage();
}
$h = fn($s) => htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8');
$total = array_sum(array_column($parts, 'qty'));
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Parts Tracker</title>
<style>
  :root { --ink:#1f2933; --muted:#616e7c; --line:#d9e2ec; --accent:#01a982; --bg:#f5f7fa; --card:#fff; --bad:#c62828; }
  * { box-sizing:border-box; }
  body { margin:0; font:15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; color:var(--ink); background:var(--bg); }
  header { background:var(--ink); color:#fff; padding:18px 24px; display:flex; flex-wrap:wrap; gap:8px 24px; align-items:baseline; }
  header h1 { margin:0; font-size:20px; }
  header span { color:#cbd2d9; font-size:13px; }
  main { max-width:960px; margin:24px auto; padding:0 16px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:16px; margin-bottom:16px; }
  .stats { display:flex; gap:32px; flex-wrap:wrap; }
  .stat b { display:block; font-size:24px; }
  .stat span { color:var(--muted); font-size:13px; }
  table { width:100%; border-collapse:collapse; }
  th, td { text-align:left; padding:8px; border-bottom:1px solid var(--line); }
  th { font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); }
  td.num { text-align:right; font-variant-numeric:tabular-nums; }
  form { display:grid; grid-template-columns:repeat(auto-fit, minmax(140px, 1fr)); gap:8px; }
  input, button { font:inherit; padding:8px; border:1px solid var(--line); border-radius:6px; }
  button { background:var(--accent); color:#fff; border:0; cursor:pointer; font-weight:600; }
  .notice { color:var(--accent); font-weight:600; }
  .error { color:var(--bad); font-weight:600; }
  footer { color:var(--muted); font-size:12px; text-align:center; margin:24px 0; }
</style>
</head>
<body>
<header>
  <h1>Parts Tracker</h1>
  <span>Web tier: <?= $h($cfg['instance']) ?> (<?= $h(gethostname()) ?>)</span>
  <span>Database tier: <?= $h($cfg['db_host']) ?></span>
</header>
<main>
<?php if ($error): ?>
  <div class="card error">Can't reach the database: <?= $h($error) ?></div>
<?php else: ?>
  <div class="card stats">
    <div class="stat"><b><?= count($parts) ?></b><span>part numbers</span></div>
    <div class="stat"><b><?= $total ?></b><span>units in stock</span></div>
    <div class="stat"><b><?= count(array_unique(array_column($parts, 'category'))) ?></b><span>categories</span></div>
  </div>
  <div class="card">
    <?php if ($notice): ?><p class="notice"><?= $h($notice) ?></p><?php endif; ?>
    <form method="post">
      <input name="part_no" placeholder="Part number" required maxlength="32">
      <input name="name" placeholder="Name" required maxlength="128">
      <input name="category" placeholder="Category" required maxlength="64">
      <input name="qty" type="number" min="0" value="1" aria-label="Quantity">
      <button type="submit">Add part</button>
    </form>
  </div>
  <div class="card">
    <table>
      <thead><tr><th>Part no.</th><th>Name</th><th>Category</th><th>Qty</th><th>Added</th></tr></thead>
      <tbody>
      <?php foreach ($parts as $p): ?>
        <tr><td><?= $h($p['part_no']) ?></td><td><?= $h($p['name']) ?></td><td><?= $h($p['category']) ?></td>
            <td class="num"><?= (int)$p['qty'] ?></td><td><?= $h(substr($p['added_at'], 0, 10)) ?></td></tr>
      <?php endforeach; ?>
      </tbody>
    </table>
  </div>
<?php endif; ?>
</main>
<footer>Deployed by HPE Morpheus Enterprise from the Parts Tracker blueprint</footer>
</body>
</html>
PHP

cat > "$WEB_ROOT/health.php" <<'PHP'
<?php
// Morpheus web check target: 200 + "OK" when Apache, PHP and the database all answer.
$cfg = require '/etc/parts-tracker/config.php';
mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
header('Content-Type: text/plain');
header('Cache-Control: no-store');
try {
    $db = new mysqli($cfg['db_host'], $cfg['db_user'], $cfg['db_pass'], $cfg['db_name']);
    $db->query('SELECT 1 FROM parts LIMIT 1');
    echo "OK\n";
} catch (Throwable $e) {
    http_response_code(503);
    echo "DB UNAVAILABLE\n";
}
PHP

chown www-data:www-data "$WEB_ROOT/index.php" "$WEB_ROOT/health.php"
systemctl restart apache2

# --- Smoke test --------------------------------------------------------------
if curl -fsS http://localhost/health.php | grep -q OK; then
  log "Parts Tracker is up: http://$(hostname -I | awk '{print $1}')/"
else
  fail "health check failed - see /var/log/apache2/error.log"
fi
