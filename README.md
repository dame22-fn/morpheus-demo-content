# morpheus-demo-content

Automation for the **Parts Tracker** two-tier demo app in HPE Morpheus Enterprise
(DameNet lab). Morpheus pulls these scripts through a Git integration and runs
them as Shell Script tasks during provisioning.

| File | Tier | What it does |
| --- | --- | --- |
| `scripts/mysql-install.sh` | Database | Installs MySQL 8, listens on the network, creates a `dbadmin` login for the server VLAN |
| `scripts/web-install.sh` | Web | Installs Apache + PHP, creates the `parts` database, app login and sample rows on the DB tier, deploys `index.php` and `health.php` |

## What Morpheus must provide

| Kind | Name | Used by | Notes |
| --- | --- | --- | --- |
| Cypher | `secret/demo/db_admin` | both | 8+ characters, letters, digits, `.` `_` `-` only |
| Cypher | `secret/demo/app_db` | web | same rules |
| Environment variable | `PARTS_DB_IP` | web | Set **Environment Prefix = `PARTS_DB`** on the *Parts DB* instance type; Morpheus then exports `PARTS_DB_IP` to the other tiers of the blueprint |

The password rules keep the values safe to drop into shell and SQL without escaping.

## Morpheus objects

| Object | Name | Contents |
| --- | --- | --- |
| Task | `Parts - MySQL install` | Shell Script, repo file `scripts/mysql-install.sh`, target Resource, sudo |
| Task | `Parts - Web install` | Shell Script, repo file `scripts/web-install.sh`, target Resource, sudo |
| Workflow (provisioning) | `Parts DB` | `Linux - Set Timezone CST`, then `Parts - MySQL install` (Provision phase) |
| Workflow (provisioning) | `Parts Web` | `Linux - Set Timezone CST`, then `Parts - Web install` (Provision phase) |
| Instance type | `Parts DB` | Environment Prefix `PARTS_DB`; HVM + VMware layouts reusing the DameNet Ubuntu node types, workflow `Parts DB` |
| Instance type | `Parts Web` | Environment Prefix `PARTS_WEB`; HVM + VMware layouts reusing the DameNet Ubuntu node types, workflow `Parts Web` |
| App blueprint | `Parts Tracker` | Database tier = Parts DB (boot order 0), App tier = Parts Web (boot order 1); Dev and Prod configurations |

## After it deploys

* App: `http://<web VM IP>/`
* Health check for Morpheus monitoring: `http://<web VM IP>/health.php` returns `OK` (HTTP 200), or HTTP 503 if the database is unreachable
* MySQL check: host = DB VM IP, port 3306, database `parts`, user `parts_app`, query `select count(*) as count from parts`

## Requirements

* Ubuntu 24.04 VMs on VLAN 20 (`172.30.20.0/24`) with internet access for `apt`
* Both scripts can be re-run safely

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `PARTS_DB_IP is empty` | Deployed outside the blueprint, or the Parts DB instance type has no `PARTS_DB` environment prefix |
| `could not log in to MySQL ... as dbadmin` | DB tier failed or isn't finished; check its task output. The web VM must be on 172.30.20.0/24 |
| `cypher ... was not filled in` | Create the cypher under Tools > Cypher with exactly that key |
| `apt-get` hangs or fails | The VM can't reach the internet (router return route / NAT for VLAN 20) |

All names are fictional demo data.
