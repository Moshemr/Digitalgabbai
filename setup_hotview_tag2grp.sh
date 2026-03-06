#!/usr/bin/env bash
# =============================================================================
# setup_hotview_tag2grp.sh  v1.0 | 2026-03-06 | HOT Telecommunications
# OSS & DBA Engineering
#
# PURPOSE:
#   Single-shot bootstrap script for the hotview_tag2grp system.
#   Run once on target RHEL 9 server as root to deploy the full system.
#   After running this script, the system is ready for a first dry-run.
#
# WHAT THIS SCRIPT DOES:
#   1. Creates /data/hotview_tag2grp/ directory tree with correct permissions
#   2. Writes hotview_tag2grp_rules.json (all business logic)
#   3. Writes hotview_tag2grp_token.conf stub (credentials — you must fill in)
#   4. Writes /etc/logrotate.d/hotview_tag2grp
#   5. Writes hotview_tag2grp_hostgroup_sync.py (main Python automation)
#   6. Sets all file permissions and ownership
#   7. Prints a structured deployment summary
#
# USAGE:
#   chmod +x setup_hotview_tag2grp.sh
#   sudo bash setup_hotview_tag2grp.sh
#
# REQUIRES: root, python3 (3.9+), bash 4+, RHEL 9
# =============================================================================

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
SCRIPT_VERSION="1.0"
SCRIPT_DATE="2026-03-06"
BASE="/data/hotview_tag2grp"
LOGROTATE_CONF="/etc/logrotate.d/hotview_tag2grp"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fatal()   { echo -e "${RED}[FATAL]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}── $* ──${RESET}"; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
cat << 'BANNER'
 ┌─────────────────────────────────────────────────────────────┐
 │  hotview_tag2grp — Bootstrap Deployment Script              │
 │  HOT Telecommunications · OSS & DBA Engineering             │
 │  v1.0 | 2026-03-06                                          │
 └─────────────────────────────────────────────────────────────┘
BANNER
echo -e "${RESET}"

# ── Root check ────────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    fatal "This script must be run as root (use: sudo bash $0)"
fi

# ── Python check ─────────────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    fatal "python3 not found. Install python3 >= 3.9 before proceeding."
fi
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
info "Detected python3 version: ${PY_VER}"

# =============================================================================
# PHASE 1 — Directory Tree
# =============================================================================
section "Phase 1: Creating directory tree"

mkdir -p "${BASE}/bin"
mkdir -p "${BASE}/config"
mkdir -p "${BASE}/log"
mkdir -p "${BASE}/run"
mkdir -p "${BASE}/tmp"

chmod 750 "${BASE}"
chmod 750 "${BASE}/bin"
chmod 700 "${BASE}/config"   # restricted: token file lives here
chmod 750 "${BASE}/log"
chmod 750 "${BASE}/run"
chmod 750 "${BASE}/tmp"
chown -R root:root "${BASE}"

info "Created ${BASE}/{bin,config,log,run,tmp}"

# =============================================================================
# PHASE 2 — Configuration: hotview_tag2grp_rules.json
# =============================================================================
section "Phase 2: Writing hotview_tag2grp_rules.json"

cat > "${BASE}/config/hotview_tag2grp_rules.json" << 'JSONEOF'
{
  "version": "1.0",
  "description": "hotview_tag2grp rule configuration — HOT Telecommunications",
  "zabbix": {
    "api_url": "http://zabbix.hot.net/zabbix/api_jsonrpc.php",
    "token_env_var": "HOTVIEW_TAG2GRP_TOKEN",
    "token_file": "/data/hotview_tag2grp/config/hotview_tag2grp_token.conf"
  },
  "scope": {
    "source_groups": [
      "HOT-Network-Routers",
      "HOT-Network-Switches"
    ]
  },
  "naming": {
    "managed_prefix": "AUTO_HV_",
    "aggregation_prefix": "AGG_AUTO_HV_",
    "tag_name": "LinkGroup",
    "required_tag_prefix": "HV_"
  },
  "rules": [
    {
      "name": "cmts",
      "match_type": "regex",
      "patterns": ["^CMTS.*", "^CMTSD.*"],
      "target_value": "CMTS",
      "enabled": true
    },
    {
      "name": "bng",
      "match_type": "exact",
      "patterns": ["BNG"],
      "target_value": "BNG",
      "enabled": true
    },
    {
      "name": "metro",
      "match_type": "exact",
      "patterns": ["METRO"],
      "target_value": "METRO",
      "enabled": true
    },
    {
      "name": "ring",
      "match_type": "exact",
      "patterns": ["RING"],
      "target_value": "RING",
      "enabled": true
    }
  ],
  "exclusions": {
    "exact": ["TEST", "LAB", "DEMO"],
    "regex": ["^DEV.*", "^STAGING.*"]
  },
  "rollback": {
    "enabled": false,
    "target_groups": [],
    "delete_empty_group": false
  },
  "state": {
    "grace_period_runs": 3,
    "state_file": "/data/hotview_tag2grp/run/hotview_tag2grp_state.json"
  },
  "aggregation": {
    "enabled": true,
    "host_name_format": "AGG_AUTO_HV_{value}",
    "template_name": "Template HV Tag2Grp Aggregate",
    "target_group_macro": "{$TARGET_GROUP}",
    "target_linkgroup_macro": "{$TARGET_LINKGROUP}",
    "empty_group_action": "UNLINK_TEMPLATE",
    "delete_empty_aggregation_host_after_days": 30
  },
  "behavior": {
    "dry_run": true,
    "sync_remove": true,
    "max_host_updates": 5000,
    "max_remove_updates": 500,
    "no_tag_threshold_percent": 10,
    "request_timeout_sec": 20,
    "sleep_between_calls_sec": 0.1
  }
}
JSONEOF

chmod 640 "${BASE}/config/hotview_tag2grp_rules.json"
chown root:root "${BASE}/config/hotview_tag2grp_rules.json"
info "Written: ${BASE}/config/hotview_tag2grp_rules.json"

# =============================================================================
# PHASE 3 — Credentials Stub: hotview_tag2grp_token.conf
# =============================================================================
section "Phase 3: Writing token file stub"

cat > "${BASE}/config/hotview_tag2grp_token.conf" << 'TOKENEOF'
# hotview_tag2grp — Zabbix API Token File
# ─────────────────────────────────────────────────────────────────────────────
# INSTRUCTIONS:
#   Replace the placeholder below with your actual Zabbix API token.
#   - No spaces, no quotes, no trailing newline required.
#   - This file must remain owned by root with mode 0600.
#   - Alternatively, set the environment variable HOTVIEW_TAG2GRP_TOKEN
#     in the cron job or systemd unit (preferred for secrets management).
#
# SECURITY:
#   Owner : root:root
#   Mode  : 0600  (enforced by setup script — do NOT chmod 644)
#
# ─────────────────────────────────────────────────────────────────────────────
REPLACE_WITH_ACTUAL_ZABBIX_API_TOKEN
TOKENEOF

chmod 0600 "${BASE}/config/hotview_tag2grp_token.conf"
chown root:root "${BASE}/config/hotview_tag2grp_token.conf"
info "Written: ${BASE}/config/hotview_tag2grp_token.conf  [mode 0600 — STUB, fill in token]"

# =============================================================================
# PHASE 4 — Logrotate Configuration
# =============================================================================
section "Phase 4: Writing logrotate config"

cat > "${LOGROTATE_CONF}" << 'LOGEOF'
# /etc/logrotate.d/hotview_tag2grp
# hotview_tag2grp — Zabbix tag-to-group sync system
# HOT Telecommunications · OSS & DBA Engineering

/data/hotview_tag2grp/log/hotview_tag2grp_sync.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        true
    endscript
}

/data/hotview_tag2grp/log/hotview_tag2grp_audit.jsonl {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
LOGEOF

chmod 644 "${LOGROTATE_CONF}"
chown root:root "${LOGROTATE_CONF}"
info "Written: ${LOGROTATE_CONF}"

# =============================================================================
# PHASE 5 — Python Main Script
# =============================================================================
section "Phase 5: Writing hotview_tag2grp_hostgroup_sync.py"

# NOTE: The heredoc delimiter 'PYEOF' is single-quoted, which means:
#   - bash does NOT interpret $, backticks, or \ sequences
#   - Python f-strings {var}, Zabbix macros {$TARGET_GROUP}, \n all pass verbatim

cat > "${BASE}/bin/hotview_tag2grp_hostgroup_sync.py" << 'PYEOF'
#!/usr/bin/env python3
# =============================================================================
# hotview_tag2grp_hostgroup_sync.py  v1.0 | 2026-03-06 | HOT Telecommunications
# OSS & DBA Engineering
#
# PURPOSE:
#   Synchronise Zabbix host group membership based on item-level tags.
#   Reads hosts from configured source groups, finds items tagged with
#   LinkGroup (values like HV_CMTS, HV_BNG), applies JSON-driven rules,
#   and syncs hosts into managed groups (AUTO_HV_CMTS, AUTO_HV_BNG, etc.).
#   Optionally creates aggregation hosts per managed group.
#
# USAGE:
#   python3 hotview_tag2grp_hostgroup_sync.py [--dry-run] [--config PATH]
#
# FIRST RUN:
#   Always run with --dry-run first. Review logs before enabling live mode.
#   Set behavior.dry_run=false in rules.json when satisfied.
#
# DEPENDENCIES:
#   Python 3.9+ stdlib only (no pip installs required)
#
# FILES:
#   Config  : /data/hotview_tag2grp/config/hotview_tag2grp_rules.json
#   Token   : /data/hotview_tag2grp/config/hotview_tag2grp_token.conf
#   Log     : /data/hotview_tag2grp/log/hotview_tag2grp_sync.log
#   Audit   : /data/hotview_tag2grp/log/hotview_tag2grp_audit.jsonl
#   State   : /data/hotview_tag2grp/run/hotview_tag2grp_state.json
#   Lock    : /data/hotview_tag2grp/run/hotview_tag2grp.lock
#   Last    : /data/hotview_tag2grp/run/hotview_tag2grp.last
# =============================================================================

from __future__ import annotations

import argparse
import fcntl
import json
import logging
import os
import re
import signal
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

# ── Version / Identity ────────────────────────────────────────────────────────

VERSION      = "1.0"
SCRIPT_NAME  = "hotview_tag2grp_hostgroup_sync"
SCRIPT_DATE  = "2026-03-06"

# Fixed paths (independent of config, so they are always reachable for logging)
BASE_DIR     = Path("/data/hotview_tag2grp")
DEFAULT_CONFIG = BASE_DIR / "config" / "hotview_tag2grp_rules.json"
LOG_FILE     = BASE_DIR / "log"   / "hotview_tag2grp_sync.log"
AUDIT_FILE   = BASE_DIR / "log"   / "hotview_tag2grp_audit.jsonl"
LOCK_FILE    = BASE_DIR / "run"   / "hotview_tag2grp.lock"
LAST_FILE    = BASE_DIR / "run"   / "hotview_tag2grp.last"

# ── StructuredLogger ──────────────────────────────────────────────────────────

class StructuredLogger:
    """
    Dual-output logger:
    - Human-readable text log  → LOG_FILE
    - Machine-readable JSONL   → AUDIT_FILE  (via .audit() method)
    """

    def __init__(self) -> None:
        self._logger: Optional[logging.Logger] = None
        self._audit_path: Optional[Path] = None

    def setup(self, log_file: Path, audit_file: Path, level: str = "INFO") -> None:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        audit_file.parent.mkdir(parents=True, exist_ok=True)

        fmt = logging.Formatter(
            fmt="%(asctime)s %(levelname)-8s %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S"
        )
        logger = logging.getLogger(SCRIPT_NAME)
        logger.setLevel(getattr(logging, level.upper(), logging.INFO))

        # File handler
        fh = logging.FileHandler(str(log_file))
        fh.setFormatter(fmt)
        logger.addHandler(fh)

        # Console handler (stderr)
        ch = logging.StreamHandler(sys.stderr)
        ch.setFormatter(fmt)
        logger.addHandler(ch)

        self._logger = logger
        self._audit_path = audit_file

    def info(self, msg: str) -> None:
        if self._logger:
            self._logger.info(msg)

    def warning(self, msg: str) -> None:
        if self._logger:
            self._logger.warning(msg)

    def error(self, msg: str) -> None:
        if self._logger:
            self._logger.error(msg)

    def debug(self, msg: str) -> None:
        if self._logger:
            self._logger.debug(msg)

    def audit(
        self,
        run_id: str,
        action: str,
        host: str,
        group: str,
        reason: str,
        dry_run: bool,
        **extra: Any,
    ) -> None:
        """Append one JSON record to the audit JSONL file."""
        if not self._audit_path:
            return
        record = {
            "run_id":    run_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "action":    action,
            "host":      host,
            "group":     group,
            "reason":    reason,
            "dry_run":   dry_run,
        }
        record.update(extra)
        with open(self._audit_path, "a") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")


# ── ConfigLoader ──────────────────────────────────────────────────────────────

class ConfigLoader:
    """Load and validate the rules JSON configuration."""

    _REQUIRED_TOP = {
        "zabbix", "scope", "naming", "rules",
        "exclusions", "rollback", "state", "aggregation", "behavior",
    }
    _REQUIRED_ZABBIX   = {"api_url", "token_env_var", "token_file"}
    _REQUIRED_NAMING   = {"managed_prefix", "aggregation_prefix", "tag_name", "required_tag_prefix"}
    _REQUIRED_BEHAVIOR = {"dry_run", "sync_remove", "max_host_updates",
                          "max_remove_updates", "no_tag_threshold_percent",
                          "request_timeout_sec", "sleep_between_calls_sec"}

    def load(self, path: Path) -> dict:
        try:
            with open(path) as fh:
                return json.load(fh)
        except FileNotFoundError:
            sys.exit(f"[FATAL] Config file not found: {path}")
        except json.JSONDecodeError as exc:
            sys.exit(f"[FATAL] Config file is not valid JSON: {exc}")

    def validate(self, cfg: dict) -> None:
        self._check_keys(cfg, self._REQUIRED_TOP, "top-level")
        self._check_keys(cfg["zabbix"],   self._REQUIRED_ZABBIX,   "zabbix")
        self._check_keys(cfg["naming"],   self._REQUIRED_NAMING,   "naming")
        self._check_keys(cfg["behavior"], self._REQUIRED_BEHAVIOR, "behavior")

        if not cfg["naming"]["managed_prefix"]:
            sys.exit("[FATAL] naming.managed_prefix cannot be empty")
        if not isinstance(cfg["rules"], list) or len(cfg["rules"]) == 0:
            sys.exit("[FATAL] rules must be a non-empty list")
        if not isinstance(cfg["scope"].get("source_groups"), list) or \
                len(cfg["scope"]["source_groups"]) == 0:
            sys.exit("[FATAL] scope.source_groups must be a non-empty list")
        if cfg["behavior"]["max_host_updates"] <= 0:
            sys.exit("[FATAL] behavior.max_host_updates must be > 0")
        if cfg["behavior"]["max_remove_updates"] <= 0:
            sys.exit("[FATAL] behavior.max_remove_updates must be > 0")

    @staticmethod
    def _check_keys(obj: dict, required: set, section: str) -> None:
        missing = required - obj.keys()
        if missing:
            sys.exit(f"[FATAL] Missing required config keys in '{section}': {sorted(missing)}")


# ── TokenProvider ─────────────────────────────────────────────────────────────

class TokenProvider:
    """
    Resolve the Zabbix API token.
    Priority: environment variable → token_file.
    The token is NEVER hardcoded and NEVER passed as a CLI argument.
    """

    def get_token(self, cfg: dict) -> str:
        env_var = cfg["zabbix"]["token_env_var"]
        token = os.environ.get(env_var, "").strip()
        if token:
            return token

        token_file = Path(cfg["zabbix"]["token_file"])
        try:
            token = token_file.read_text().strip()
        except FileNotFoundError:
            sys.exit(
                f"[FATAL] Token not found. Set env var {env_var} or "
                f"write token to {token_file}"
            )
        except PermissionError:
            sys.exit(
                f"[FATAL] Cannot read {token_file}. "
                "Ensure script runs as root and file mode is 0600."
            )

        # Reject stub placeholder
        if not token or token.startswith("REPLACE_WITH_"):
            sys.exit(
                f"[FATAL] Token file {token_file} still contains placeholder. "
                "Replace with actual Zabbix API token."
            )

        return token


# ── LockManager ───────────────────────────────────────────────────────────────

class LockManager:
    """
    Process-level lock using fcntl.flock.
    Prevents concurrent runs of this script.
    Designed as a context manager.
    """

    def __init__(self, lock_path: Path) -> None:
        self.lock_path = lock_path
        self._fd: Any = None
        self.acquired = False

    def __enter__(self) -> "LockManager":
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self._fd = open(self.lock_path, "w")
            fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self._fd.write(str(os.getpid()))
            self._fd.flush()
            self.acquired = True
        except OSError:
            if self._fd:
                self._fd.close()
                self._fd = None
            self.acquired = False
        return self

    def __exit__(self, *args: Any) -> None:
        if self._fd:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_UN)
            except OSError:
                pass
            self._fd.close()
            try:
                self.lock_path.unlink(missing_ok=True)
            except OSError:
                pass


# ── ZabbixAPI ─────────────────────────────────────────────────────────────────

class ZabbixAPI:
    """
    Minimal JSON-RPC 2.0 client for Zabbix API.
    Authentication via Bearer token (Zabbix 5.4+).
    Uses stdlib urllib only — no external dependencies.
    """

    def __init__(
        self,
        url: str,
        token: str,
        timeout: float = 20,
        sleep_sec: float = 0.1,
    ) -> None:
        self.url       = url
        self.token     = token
        self.timeout   = timeout
        self.sleep_sec = sleep_sec
        self._req_id   = 0

    def call(self, method: str, params: Any) -> Any:
        """Execute one Zabbix API call. Returns result or raises RuntimeError."""
        self._req_id += 1
        payload = {
            "jsonrpc": "2.0",
            "method":  method,
            "params":  params,
            "id":      self._req_id,
        }
        data = json.dumps(payload).encode("utf-8")
        req  = urllib.request.Request(
            self.url,
            data=data,
            headers={
                "Content-Type":  "application/json",
                "Authorization": f"Bearer {self.token}",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                result = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"HTTP {exc.code} from Zabbix API: {body[:512]}")
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Network error reaching Zabbix API: {exc.reason}")

        time.sleep(self.sleep_sec)

        if "error" in result:
            err = result["error"]
            raise RuntimeError(
                f"Zabbix API error [{err.get('code')}]: "
                f"{err.get('data', err.get('message', 'unknown'))}"
            )
        return result["result"]

    # ── Host / Group helpers ──────────────────────────────────────────────────

    def get_hosts_in_groups(self, group_names: list[str]) -> list[dict]:
        """Return [{hostid, host, name}] for all hosts in the named source groups."""
        groups = self.call("hostgroup.get", {
            "output": ["groupid", "name"],
            "filter": {"name": group_names},
        })
        if not groups:
            return []
        groupids = [g["groupid"] for g in groups]
        return self.call("host.get", {
            "output":   ["hostid", "host", "name"],
            "groupids": groupids,
        })

    def get_item_tags_for_hosts(self, host_ids: list[str]) -> dict[str, list[dict]]:
        """
        Return {hostid: [{tag, value}, ...]} for items on the given hosts.
        One host can have many items; we accumulate all item tags.
        """
        if not host_ids:
            return {}
        items = self.call("item.get", {
            "output":     ["hostid"],
            "hostids":    host_ids,
            "selectTags": "extend",
        })
        result: dict[str, list[dict]] = {}
        for item in items:
            hid = item["hostid"]
            result.setdefault(hid, []).extend(item.get("tags", []))
        return result

    def get_managed_groups(self, prefix: str) -> dict[str, str]:
        """Return {name: groupid} for all groups whose name starts with prefix."""
        groups = self.call("hostgroup.get", {
            "output":                  ["groupid", "name"],
            "search":                  {"name": prefix},
            "searchWildcardsEnabled":  True,
        })
        return {
            g["name"]: g["groupid"]
            for g in groups
            if g["name"].startswith(prefix)
        }

    def get_group_members(self, groupids: list[str]) -> dict[str, set[str]]:
        """Return {groupid: {hostid, ...}} for the given group IDs."""
        if not groupids:
            return {}
        hosts = self.call("host.get", {
            "output":       ["hostid"],
            "groupids":     groupids,
            "selectGroups": ["groupid"],
        })
        result: dict[str, set[str]] = {gid: set() for gid in groupids}
        for host in hosts:
            for grp in host.get("groups", []):
                gid = grp["groupid"]
                if gid in result:
                    result[gid].add(host["hostid"])
        return result

    def create_group(self, name: str) -> str:
        """Create a new host group. Returns its groupid."""
        result = self.call("hostgroup.create", {"name": name})
        return result["groupids"][0]

    def add_hosts_to_group(self, groupid: str, host_ids: list[str]) -> None:
        self.call("hostgroup.massadd", {
            "groups": [{"groupid": groupid}],
            "hosts":  [{"hostid": hid} for hid in host_ids],
        })

    def remove_hosts_from_group(self, groupid: str, host_ids: list[str]) -> None:
        self.call("hostgroup.massremove", {
            "groupids": [groupid],
            "hostids":  host_ids,
        })

    def get_template_by_name(self, name: str) -> Optional[str]:
        """Return templateid, or None if not found."""
        result = self.call("template.get", {
            "output": ["templateid"],
            "filter": {"host": [name]},
        })
        return result[0]["templateid"] if result else None

    def get_host_by_name(self, name: str) -> Optional[dict]:
        """Return full host record, or None if not found."""
        result = self.call("host.get", {
            "output":              ["hostid", "host", "name"],
            "filter":              {"host": [name]},
            "selectGroups":        ["groupid"],
            "selectMacros":        ["hostmacroid", "macro", "value"],
            "selectParentTemplates": ["templateid"],
        })
        return result[0] if result else None

    def create_aggregation_host(
        self,
        name: str,
        groupid: str,
        templateid: Optional[str],
        macros: list[dict],
    ) -> str:
        """Create an aggregation host. Returns its hostid."""
        params: dict[str, Any] = {
            "host":   name,
            "name":   name,
            "groups": [{"groupid": groupid}],
            "macros": macros,
        }
        if templateid:
            params["templates"] = [{"templateid": templateid}]
        result = self.call("host.create", params)
        return result["hostids"][0]

    def update_host_macros(self, hostid: str, macros: list[dict]) -> None:
        self.call("host.update", {"hostid": hostid, "macros": macros})

    def unlink_template_from_host(self, hostid: str, templateid: str) -> None:
        self.call("host.update", {
            "hostid":          hostid,
            "templates_clear": [{"templateid": templateid}],
        })

    def delete_host(self, hostid: str) -> None:
        self.call("host.delete", [hostid])


# ── RuleEngine ────────────────────────────────────────────────────────────────

class RuleEngine:
    """
    Resolves raw LinkGroup tag values to target_values via the configured rule set.

    Decision logic (STRICT):
    1. Tag value MUST start with required_tag_prefix (e.g. "HV_")     → reject if not
    2. Strip prefix, UPPERCASE
    3. Check exclusions (exact first, then regex)                      → skip if excluded
    4. Match against enabled rules in declaration order                → first match wins
    5. No match                                                        → NO_MATCH (log WARNING, skip)
    6. Return deduplicated list of target_values
    """

    def __init__(self, cfg: dict, log: StructuredLogger) -> None:
        naming = cfg["naming"]
        self.tag_name        = naming["tag_name"]
        self.required_prefix = naming["required_tag_prefix"]
        self.log             = log

        # Pre-compile rules and exclusions
        self._rules = [r for r in cfg["rules"] if r.get("enabled", True)]
        self._excl_exact: set[str] = set(cfg["exclusions"].get("exact", []))
        self._excl_regex: list[re.Pattern] = [
            re.compile(p) for p in cfg["exclusions"].get("regex", [])
        ]

    def resolve(self, raw_values: list[str]) -> list[str]:
        """
        Given a list of raw LinkGroup tag values (e.g. ["HV_CMTS", "HV_BNG"]),
        return a deduplicated list of target_values (e.g. ["CMTS", "BNG"]).
        """
        seen: set[str] = set()
        result: list[str] = []

        for raw in raw_values:
            if not raw.startswith(self.required_prefix):
                self.log.warning(
                    f"    Tag value '{raw}' does not start with required prefix "
                    f"'{self.required_prefix}' — REJECTED"
                )
                continue

            stripped = raw[len(self.required_prefix):].upper()

            excluded, reason = self._is_excluded(stripped)
            if excluded:
                self.log.info(f"    Tag value '{raw}' → '{stripped}' EXCLUDED: {reason}")
                continue

            target = self._match_rule(stripped)
            if target is None:
                self.log.warning(
                    f"    Tag value '{raw}' (normalized: '{stripped}') → NO_MATCH — "
                    "no group will be created"
                )
                continue

            if target not in seen:
                seen.add(target)
                result.append(target)
                self.log.debug(f"    Tag value '{raw}' → '{stripped}' → target_value='{target}'")

        return result

    def _is_excluded(self, value: str) -> tuple[bool, str]:
        if value in self._excl_exact:
            return True, f"exact exclusion: '{value}'"
        for pattern in self._excl_regex:
            if pattern.fullmatch(value):
                return True, f"regex exclusion: pattern='{pattern.pattern}'"
        return False, ""

    def _match_rule(self, value: str) -> Optional[str]:
        """Return target_value of the first matching rule, or None."""
        for rule in self._rules:
            mt = rule.get("match_type", "exact")
            for pattern in rule.get("patterns", []):
                if mt == "exact":
                    if value == pattern:
                        return rule["target_value"]
                elif mt == "regex":
                    if re.fullmatch(pattern, value):
                        return rule["target_value"]
        return None


# ── StateManager ──────────────────────────────────────────────────────────────

class StateManager:
    """
    Tracks per-host, per-group remove-candidate run counts for grace-period logic.

    A host is only removed from a managed group after it has been a removal
    candidate for `grace_period_runs` consecutive runs.

    State file schema:
    {
      "version": "1.0",
      "last_run_id": "YYYYMMDD_HHMMSS",
      "pending_removes": {
        "<hostid>": {
          "<groupid>": <consecutive_candidate_count>
        }
      }
    }
    """

    def __init__(self, state_file: Path, grace_period_runs: int) -> None:
        self.state_file       = state_file
        self.grace_period_runs = grace_period_runs

    def load(self) -> dict:
        try:
            text = self.state_file.read_text().strip()
            if text:
                return json.loads(text)
        except FileNotFoundError:
            pass
        except json.JSONDecodeError:
            pass
        return {"version": "1.0", "last_run_id": "", "pending_removes": {}}

    def save(self, state: dict) -> None:
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self.state_file.write_text(json.dumps(state, indent=2))

    def update_pending_removes(
        self,
        state: dict,
        remove_candidates: dict[str, set[str]],
    ) -> dict:
        """
        remove_candidates: {groupid: {hostid, ...}}
        Increments counters for active candidates.
        Drops entries for hosts that are no longer candidates.
        """
        # Build candidate lookup: hostid → set(groupids)
        candidate_lookup: dict[str, set[str]] = {}
        for groupid, hostids in remove_candidates.items():
            for hostid in hostids:
                candidate_lookup.setdefault(hostid, set()).add(groupid)

        old_pending = state.get("pending_removes", {})
        new_pending: dict[str, dict[str, int]] = {}

        # Carry forward + increment existing pending that are still candidates
        for hostid, grp_counts in old_pending.items():
            for groupid, count in grp_counts.items():
                if hostid in candidate_lookup and groupid in candidate_lookup[hostid]:
                    new_pending.setdefault(hostid, {})[groupid] = count + 1

        # Insert new candidates not yet in pending (start at count 1)
        for hostid, groupids in candidate_lookup.items():
            for groupid in groupids:
                if groupid not in new_pending.get(hostid, {}):
                    new_pending.setdefault(hostid, {})[groupid] = 1

        state["pending_removes"] = new_pending
        return state

    def get_confirmed_removes(self, state: dict) -> dict[str, list[str]]:
        """Return {groupid: [hostid, ...]} where count >= grace_period_runs."""
        result: dict[str, list[str]] = {}
        for hostid, grp_counts in state.get("pending_removes", {}).items():
            for groupid, count in grp_counts.items():
                if count >= self.grace_period_runs:
                    result.setdefault(groupid, []).append(hostid)
        return result


# ── SyncEngine ────────────────────────────────────────────────────────────────

class SyncEngine:
    """
    Core sync logic:
    - Build desired state (which hosts should be in which managed groups)
    - Compute delta vs. current state
    - Apply safety guards
    - Execute adds/removes (with dry-run support)
    """

    def __init__(
        self,
        zapi: ZabbixAPI,
        rule_engine: RuleEngine,
        cfg: dict,
        log: StructuredLogger,
    ) -> None:
        self.zapi        = zapi
        self.rule_engine = rule_engine
        self.cfg         = cfg
        self.behavior    = cfg["behavior"]
        self.naming      = cfg["naming"]
        self.log         = log

    def build_desired_state(
        self,
        hosts: list[dict],
        item_tags_by_hostid: dict[str, list[dict]],
    ) -> dict[str, Any]:
        """
        Returns:
          desired[hostid] = set of target_values (e.g. {"CMTS", "BNG"})
          desired["_no_tag_hosts"] = set of hostids with no valid LinkGroup tags
          desired["_host_info"]    = {hostid: hostname} for logging
        """
        desired: dict[str, Any] = {}
        no_tag_hosts: set[str]  = set()
        host_info: dict[str, str] = {}

        tag_name = self.naming["tag_name"]

        for host in hosts:
            hid   = host["hostid"]
            hname = host.get("host", hid)
            host_info[hid] = hname

            item_tags = item_tags_by_hostid.get(hid, [])

            # Collect all LinkGroup values from all items on this host
            link_group_values = [
                t["value"]
                for t in item_tags
                if t.get("tag") == tag_name
            ]

            if not link_group_values:
                no_tag_hosts.add(hid)
                desired[hid] = set()
                continue

            target_values = self.rule_engine.resolve(link_group_values)
            desired[hid] = set(target_values)

        desired["_no_tag_hosts"] = no_tag_hosts
        desired["_host_info"]    = host_info
        return desired

    def compute_delta(
        self,
        desired_state: dict[str, Any],
        current_membership: dict[str, set[str]],
        managed_groups: dict[str, str],
    ) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
        """
        Returns:
          add_ops:           {groupname: {hostid, ...}}   — hosts to add
          remove_candidates: {groupid: {hostid, ...}}     — candidate removals
        """
        prefix = self.naming["managed_prefix"]

        # All in-scope host IDs (excluding internal state keys)
        all_hostids = {
            k for k in desired_state
            if not k.startswith("_")
        }

        # Build desired: {groupname → set of hostids that should be there}
        desired_members: dict[str, set[str]] = {}
        for hostid in all_hostids:
            for tv in desired_state.get(hostid, set()):
                gname = f"{prefix}{tv}"
                desired_members.setdefault(gname, set()).add(hostid)

        name_to_gid = managed_groups
        gid_to_name = {v: k for k, v in managed_groups.items()}

        # ADD: hosts that should be in a group but are not yet
        add_ops: dict[str, set[str]] = {}
        for gname, wanted_hosts in desired_members.items():
            gid     = name_to_gid.get(gname)
            current = current_membership.get(gid, set()) if gid else set()
            missing = wanted_hosts - current
            if missing:
                add_ops[gname] = missing

        # REMOVE CANDIDATES: hosts in a managed group that are in scope
        # but should not be in that group
        remove_candidates: dict[str, set[str]] = {}
        for gname, gid in managed_groups.items():
            current   = current_membership.get(gid, set())
            should_be = desired_members.get(gname, set())
            # Only flag in-scope hosts as removal candidates
            removable = (current & all_hostids) - should_be
            if removable:
                remove_candidates[gid] = removable

        return add_ops, remove_candidates

    def apply_safety_guards(
        self,
        hosts: list[dict],
        desired_state: dict[str, Any],
        add_ops: dict[str, set[str]],
        confirmed_removes: dict[str, list[str]],
    ) -> None:
        """Abort if any safety threshold is violated."""
        total    = len(hosts)
        no_tag   = desired_state.get("_no_tag_hosts", set())
        n_no_tag = len(no_tag)

        if total > 0:
            no_tag_pct = (n_no_tag / total) * 100.0
            threshold  = self.behavior["no_tag_threshold_percent"]
            if no_tag_pct > threshold:
                self.log.error(
                    f"SAFETY ABORT: {n_no_tag}/{total} in-scope hosts "
                    f"({no_tag_pct:.1f}%) have no valid '{self.naming['tag_name']}' "
                    f"item tag. Threshold is {threshold}%. "
                    "Possible data collection failure — aborting to avoid mass removal."
                )
                sys.exit(2)

        total_adds    = sum(len(v) for v in add_ops.values())
        total_removes = sum(len(v) for v in confirmed_removes.values())

        max_removes = self.behavior["max_remove_updates"]
        if total_removes > max_removes:
            self.log.error(
                f"SAFETY ABORT: {total_removes} confirmed REMOVE operations "
                f"exceed max_remove_updates={max_removes}."
            )
            sys.exit(2)

        max_total = self.behavior["max_host_updates"]
        if total_adds + total_removes > max_total:
            self.log.error(
                f"SAFETY ABORT: {total_adds + total_removes} total operations "
                f"(adds={total_adds} + removes={total_removes}) "
                f"exceed max_host_updates={max_total}."
            )
            sys.exit(2)

        self.log.info(
            f"Safety guards passed — "
            f"ADD={total_adds}, REMOVE={total_removes} (confirmed after grace period), "
            f"no_tag={n_no_tag}/{total}"
        )

    def execute(
        self,
        add_ops: dict[str, set[str]],
        confirmed_removes: dict[str, list[str]],
        managed_groups: dict[str, str],
        dry_run: bool,
        run_id: str,
        host_info: dict[str, str],
        audit_fn,
    ) -> dict[str, str]:
        """
        Create missing groups, add hosts, remove confirmed hosts.
        Returns updated managed_groups dict (with any newly created groups).
        """
        name_to_gid = dict(managed_groups)
        prefix      = self.naming["managed_prefix"]

        # ── Create missing managed groups ─────────────────────────────────────
        for gname in add_ops:
            if gname not in name_to_gid:
                if dry_run:
                    self.log.info(f"  [DRY-RUN] Would CREATE group: {gname}")
                else:
                    try:
                        gid = self.zapi.create_group(gname)
                        name_to_gid[gname] = gid
                        self.log.info(f"  CREATED group: {gname} (groupid={gid})")
                    except RuntimeError as exc:
                        self.log.error(f"  Failed to create group '{gname}': {exc}")
                        continue
                audit_fn(run_id, "CREATE_GROUP", "", gname, "new managed group required", dry_run)

        # ── ADD hosts to groups ───────────────────────────────────────────────
        stats_added = 0
        for gname, hostids in add_ops.items():
            gid = name_to_gid.get(gname)
            if not gid and not dry_run:
                self.log.warning(f"  Cannot add to '{gname}': groupid unknown (create may have failed)")
                continue

            for hid in hostids:
                hname = host_info.get(hid, hid)
                if dry_run:
                    self.log.info(f"  [DRY-RUN] Would ADD '{hname}' → '{gname}'")
                audit_fn(run_id, "ADD_HOST", hname, gname, "tag rule match", dry_run)

            if not dry_run and gid and hostids:
                try:
                    self.zapi.add_hosts_to_group(gid, list(hostids))
                    self.log.info(f"  ADDED {len(hostids)} host(s) → '{gname}'")
                    stats_added += len(hostids)
                except RuntimeError as exc:
                    self.log.error(f"  Failed to add hosts to '{gname}': {exc}")

        # ── REMOVE confirmed hosts from groups ────────────────────────────────
        gid_to_name = {v: k for k, v in name_to_gid.items()}
        stats_removed = 0
        for gid, hostids in confirmed_removes.items():
            gname = gid_to_name.get(gid, gid)
            for hid in hostids:
                hname = host_info.get(hid, hid)
                if dry_run:
                    self.log.info(f"  [DRY-RUN] Would REMOVE '{hname}' ← '{gname}' (grace period expired)")
                audit_fn(run_id, "REMOVE_HOST", hname, gname, "grace period expired", dry_run)

            if not dry_run and hostids:
                try:
                    self.zapi.remove_hosts_from_group(gid, hostids)
                    self.log.info(f"  REMOVED {len(hostids)} host(s) ← '{gname}'")
                    stats_removed += len(hostids)
                except RuntimeError as exc:
                    self.log.error(f"  Failed to remove hosts from '{gname}': {exc}")

        if dry_run:
            self.log.info(
                f"  [DRY-RUN] Summary: would-add={sum(len(v) for v in add_ops.values())}, "
                f"would-remove={sum(len(v) for v in confirmed_removes.values())}"
            )
        else:
            self.log.info(f"  Sync complete: added={stats_added}, removed={stats_removed}")

        return name_to_gid


# ── AggregationManager ────────────────────────────────────────────────────────

class AggregationManager:
    """
    Manages AGG_AUTO_HV_{VALUE} aggregation hosts.

    For each managed group AUTO_HV_X:
    - If the group has members: ensure AGG_AUTO_HV_X exists with correct macros
    - If the group is empty:
        - UNLINK_TEMPLATE action: remove template link from agg host
        - After delete_empty_aggregation_host_after_days: delete the agg host

    Macros set on the aggregation host:
    - {$TARGET_GROUP}     = AUTO_HV_X
    - {$TARGET_LINKGROUP} = HV_X
    """

    def __init__(self, zapi: ZabbixAPI, cfg: dict, log: StructuredLogger) -> None:
        self.zapi    = zapi
        self.cfg     = cfg
        self.agg_cfg = cfg["aggregation"]
        self.naming  = cfg["naming"]
        self.log     = log

    def sync(
        self,
        managed_groups: dict[str, str],
        group_members: dict[str, set[str]],
        dry_run: bool,
        run_id: str,
        audit_fn,
        state: dict,
    ) -> None:
        if not self.agg_cfg.get("enabled", False):
            self.log.info("Aggregation is disabled — skipping.")
            return

        template_name = self.agg_cfg["template_name"]
        templateid    = self.zapi.get_template_by_name(template_name)
        if not templateid:
            self.log.warning(
                f"Aggregation template '{template_name}' not found in Zabbix. "
                "Skipping aggregation host sync."
            )
            return

        prefix     = self.naming["managed_prefix"]
        agg_prefix = self.naming["aggregation_prefix"]
        req_prefix = self.naming["required_tag_prefix"]

        for gname, gid in managed_groups.items():
            value         = gname[len(prefix):]                   # e.g. "CMTS"
            agg_name      = f"{agg_prefix}{value}"                # e.g. "AGG_AUTO_HV_CMTS"
            linkgroup_val = f"{req_prefix}{value}"                # e.g. "HV_CMTS"

            members  = set(group_members.get(gid, set()))
            existing = self.zapi.get_host_by_name(agg_name)

            # Exclude the aggregation host itself from member count
            if existing:
                members.discard(existing["hostid"])

            if not members:
                if existing:
                    self._handle_empty_group(
                        existing, templateid, gname, dry_run, run_id, audit_fn, state
                    )
                # else: empty group, no agg host → nothing to do
            else:
                if not existing:
                    self._create_agg_host(
                        agg_name, gid, gname, linkgroup_val, templateid,
                        dry_run, run_id, audit_fn
                    )
                else:
                    self._ensure_macros(existing, gname, linkgroup_val, dry_run)

    def _create_agg_host(
        self,
        name: str,
        groupid: str,
        target_group: str,
        linkgroup_val: str,
        templateid: Optional[str],
        dry_run: bool,
        run_id: str,
        audit_fn,
    ) -> None:
        macros = [
            {"macro": "{$TARGET_GROUP}",     "value": target_group},
            {"macro": "{$TARGET_LINKGROUP}", "value": linkgroup_val},
        ]
        if dry_run:
            self.log.info(f"  [DRY-RUN] Would CREATE aggregation host: {name}")
        else:
            try:
                hostid = self.zapi.create_aggregation_host(name, groupid, templateid, macros)
                self.log.info(f"  CREATED aggregation host: {name} (hostid={hostid})")
            except RuntimeError as exc:
                self.log.error(f"  Failed to create aggregation host '{name}': {exc}")
                return
        audit_fn(run_id, "CREATE_AGG_HOST", name, target_group,
                 "managed group needs aggregation host", dry_run)

    def _handle_empty_group(
        self,
        host: dict,
        templateid: str,
        gname: str,
        dry_run: bool,
        run_id: str,
        audit_fn,
        state: dict,
    ) -> None:
        action = self.agg_cfg.get("empty_group_action", "UNLINK_TEMPLATE")
        hid    = host["hostid"]
        hname  = host["host"]

        if action == "UNLINK_TEMPLATE":
            linked = [t["templateid"] for t in host.get("parentTemplates", [])]
            if templateid in linked:
                if dry_run:
                    self.log.info(f"  [DRY-RUN] Would UNLINK template from {hname} (empty group)")
                else:
                    try:
                        self.zapi.unlink_template_from_host(hid, templateid)
                        self.log.info(f"  UNLINKED template from {hname} (empty group)")
                    except RuntimeError as exc:
                        self.log.error(f"  Failed to unlink template from '{hname}': {exc}")
                        return
                audit_fn(run_id, "UNLINK_TEMPLATE", hname, gname, "group is empty", dry_run)

        # Check if agg host should be deleted (empty for N+ days)
        delete_after = self.agg_cfg.get("delete_empty_aggregation_host_after_days", 30)
        empty_since  = state.get("empty_groups", {}).get(gname)
        if empty_since:
            try:
                since_dt = datetime.fromisoformat(empty_since)
                days_empty = (datetime.now(timezone.utc) - since_dt).days
                if days_empty >= delete_after:
                    if dry_run:
                        self.log.info(
                            f"  [DRY-RUN] Would DELETE aggregation host {hname} "
                            f"(empty for {days_empty} days >= {delete_after} day threshold)"
                        )
                    else:
                        try:
                            self.zapi.delete_host(hid)
                            self.log.info(
                                f"  DELETED aggregation host {hname} "
                                f"(empty for {days_empty} days)"
                            )
                        except RuntimeError as exc:
                            self.log.error(f"  Failed to delete aggregation host '{hname}': {exc}")
                            return
                    audit_fn(run_id, "DELETE_AGG_HOST", hname, gname,
                             f"empty for {days_empty} days", dry_run)
                    state.get("empty_groups", {}).pop(gname, None)
                    return
            except (ValueError, TypeError):
                pass
        else:
            # Record when the group became empty
            state.setdefault("empty_groups", {})[gname] = \
                datetime.now(timezone.utc).isoformat()

    def _ensure_macros(
        self,
        host: dict,
        target_group: str,
        linkgroup_val: str,
        dry_run: bool,
    ) -> None:
        """Update macros on the agg host if they differ from desired values."""
        desired = {
            "{$TARGET_GROUP}":     target_group,
            "{$TARGET_LINKGROUP}": linkgroup_val,
        }
        current = {m["macro"]: m["value"] for m in host.get("macros", [])}
        needs_update = any(current.get(k) != v for k, v in desired.items())

        if not needs_update:
            return

        # Build new macro list: update desired keys, keep others
        new_macros = [{"macro": k, "value": v} for k, v in desired.items()]
        for m in host.get("macros", []):
            if m["macro"] not in desired:
                new_macros.append(m)

        if dry_run:
            self.log.info(f"  [DRY-RUN] Would UPDATE macros on {host['host']}")
        else:
            try:
                self.zapi.update_host_macros(host["hostid"], new_macros)
                self.log.info(f"  UPDATED macros on {host['host']}")
            except RuntimeError as exc:
                self.log.error(f"  Failed to update macros on '{host['host']}': {exc}")


# ── Utility ───────────────────────────────────────────────────────────────────

def write_last_file(path: Path, run_id: str, stats: dict) -> None:
    """Write a JSON summary of the last run to .last file."""
    record = {
        "run_id":    run_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        **stats,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, indent=2))


# ── Argument Parser ───────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog=SCRIPT_NAME,
        description=(
            "hotview_tag2grp — Sync Zabbix host group membership "
            "from LinkGroup item tags."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "FIRST RUN: always use --dry-run.\n"
            "Review logs, then set behavior.dry_run=false in rules.json.\n\n"
            f"Version: {VERSION} | {SCRIPT_DATE} | HOT Telecommunications"
        ),
    )
    parser.add_argument(
        "--config",
        default=str(DEFAULT_CONFIG),
        metavar="PATH",
        help=f"Path to rules JSON config (default: {DEFAULT_CONFIG})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Force dry-run mode (no writes to Zabbix, overrides config)",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Log level (default: INFO)",
    )
    return parser.parse_args()


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    args = parse_args()

    # ── Load & validate config ────────────────────────────────────────────────
    loader = ConfigLoader()
    cfg    = loader.load(Path(args.config))
    loader.validate(cfg)

    # CLI --dry-run overrides config
    if args.dry_run:
        cfg["behavior"]["dry_run"] = True
    dry_run = cfg["behavior"]["dry_run"]

    # ── Setup logging ─────────────────────────────────────────────────────────
    log = StructuredLogger()
    log.setup(LOG_FILE, AUDIT_FILE, args.log_level)

    log.info(f"{'=' * 70}")
    log.info(f"{SCRIPT_NAME} v{VERSION} | {SCRIPT_DATE}")
    log.info(f"Config : {args.config}")
    log.info(f"Dry-run: {dry_run}")
    log.info(f"{'=' * 70}")

    # ── Resolve token ─────────────────────────────────────────────────────────
    token = TokenProvider().get_token(cfg)
    log.info("Token resolved successfully.")

    # ── Acquire lock ──────────────────────────────────────────────────────────
    with LockManager(LOCK_FILE) as lock:
        if not lock.acquired:
            log.error(
                "Another instance of this script is already running "
                f"(lock file: {LOCK_FILE}). Exiting."
            )
            return 1

        run_id = datetime.now().strftime("%Y%m%d_%H%M%S")
        log.info(f"Lock acquired. run_id={run_id}")
        log.audit(run_id, "RUN_START", "", "", f"dry_run={dry_run}", dry_run)

        # ── Instantiate components ────────────────────────────────────────────
        behavior = cfg["behavior"]
        zapi = ZabbixAPI(
            url       = cfg["zabbix"]["api_url"],
            token     = token,
            timeout   = behavior["request_timeout_sec"],
            sleep_sec = behavior["sleep_between_calls_sec"],
        )
        rule_engine  = RuleEngine(cfg, log)
        state_file   = Path(cfg["state"]["state_file"])
        grace_runs   = cfg["state"]["grace_period_runs"]
        state_mgr    = StateManager(state_file, grace_runs)
        sync_engine  = SyncEngine(zapi, rule_engine, cfg, log)
        agg_mgr      = AggregationManager(zapi, cfg, log)

        stats: dict = {
            "dry_run":        dry_run,
            "hosts_total":    0,
            "hosts_tagged":   0,
            "hosts_no_tag":   0,
            "groups_managed": 0,
            "adds":           0,
            "removes":        0,
            "exit_code":      0,
        }

        try:
            # ── Step 4: Fetch in-scope hosts ──────────────────────────────────
            source_groups = cfg["scope"]["source_groups"]
            log.info(f"[PHASE 1] Fetching hosts from source groups: {source_groups}")
            hosts = zapi.get_hosts_in_groups(source_groups)
            log.info(f"[PHASE 1] Found {len(hosts)} in-scope hosts")
            stats["hosts_total"] = len(hosts)

            if not hosts:
                log.warning("No in-scope hosts found. Nothing to do.")
                log.audit(run_id, "RUN_END", "", "", "no in-scope hosts", dry_run)
                return 0

            # ── Step 5: Fetch item tags ───────────────────────────────────────
            host_ids = [h["hostid"] for h in hosts]
            log.info(f"[PHASE 1] Fetching item tags for {len(host_ids)} hosts …")
            item_tags_by_hostid = zapi.get_item_tags_for_hosts(host_ids)
            log.info(f"[PHASE 1] Retrieved item tag data for {len(item_tags_by_hostid)} hosts")

            # ── Step 6: Build desired state ───────────────────────────────────
            log.info("[PHASE 1] Resolving LinkGroup values → applying rules & exclusions …")
            desired_state = sync_engine.build_desired_state(hosts, item_tags_by_hostid)

            no_tag_hosts = desired_state.get("_no_tag_hosts", set())
            host_info    = desired_state.get("_host_info", {})
            tagged_count = len(hosts) - len(no_tag_hosts)
            log.info(
                f"[PHASE 1] Desired state built: "
                f"{tagged_count}/{len(hosts)} hosts have valid LinkGroup tags"
            )
            stats["hosts_tagged"] = tagged_count
            stats["hosts_no_tag"] = len(no_tag_hosts)

            # ── Step 7: Read current managed group membership ─────────────────
            log.info("[PHASE 1] Reading current managed groups from Zabbix …")
            prefix        = cfg["naming"]["managed_prefix"]
            managed_groups = zapi.get_managed_groups(prefix)
            log.info(f"[PHASE 1] Found {len(managed_groups)} existing managed groups")
            stats["groups_managed"] = len(managed_groups)

            current_members: dict[str, set[str]] = {}
            if managed_groups:
                current_members = zapi.get_group_members(list(managed_groups.values()))

            # ── Step 8: Compute delta ─────────────────────────────────────────
            log.info("[PHASE 2] Computing delta (adds and remove candidates) …")
            add_ops, remove_candidates = sync_engine.compute_delta(
                desired_state, current_members, managed_groups
            )
            log.info(
                f"[PHASE 2] Delta: "
                f"adds={sum(len(v) for v in add_ops.values())}, "
                f"remove_candidates={sum(len(v) for v in remove_candidates.values())}"
            )

            # ── Step 9: State / grace period ──────────────────────────────────
            log.info(f"[PHASE 2] Loading state (grace_period_runs={grace_runs}) …")
            state = state_mgr.load()
            state["last_run_id"] = run_id
            state = state_mgr.update_pending_removes(state, remove_candidates)
            confirmed_removes = state_mgr.get_confirmed_removes(state)
            log.info(
                f"[PHASE 2] Confirmed removes (grace satisfied): "
                f"{sum(len(v) for v in confirmed_removes.values())}"
            )

            # ── Safety guards ─────────────────────────────────────────────────
            sync_engine.apply_safety_guards(
                hosts, desired_state, add_ops, confirmed_removes
            )

            # ── Steps 11-12: Execute sync ─────────────────────────────────────
            log.info(f"[PHASE 2] Executing sync (dry_run={dry_run}) …")
            updated_groups = sync_engine.execute(
                add_ops,
                confirmed_removes,
                managed_groups,
                dry_run,
                run_id,
                host_info,
                log.audit,
            )

            stats["adds"]    = sum(len(v) for v in add_ops.values())
            stats["removes"] = sum(len(v) for v in confirmed_removes.values())

            # ── Step 13: Aggregation hosts ────────────────────────────────────
            if cfg["aggregation"].get("enabled", False):
                log.info("[PHASE 2] Syncing aggregation hosts …")
                if updated_groups:
                    updated_members = zapi.get_group_members(list(updated_groups.values()))
                else:
                    updated_members = {}
                agg_mgr.sync(
                    updated_groups,
                    updated_members,
                    dry_run,
                    run_id,
                    log.audit,
                    state,
                )

            # ── Step 14: Save state ───────────────────────────────────────────
            state_mgr.save(state)
            log.info(f"State saved to {state_file}")

        except RuntimeError as exc:
            log.error(f"Zabbix API error: {exc}")
            log.audit(run_id, "RUN_FAILED", "", "", str(exc), dry_run)
            stats["exit_code"] = 1
            write_last_file(LAST_FILE, run_id, stats)
            return 1

        except KeyboardInterrupt:
            log.warning("Interrupted by user.")
            log.audit(run_id, "RUN_INTERRUPTED", "", "", "SIGINT", dry_run)
            stats["exit_code"] = 130
            write_last_file(LAST_FILE, run_id, stats)
            return 130

        # ── Step 17: Write .last file ─────────────────────────────────────────
        stats["groups_managed"] = len(updated_groups) if "updated_groups" in dir() else len(managed_groups)
        write_last_file(LAST_FILE, run_id, stats)

        log.audit(run_id, "RUN_END", "", "", f"exit_code=0", dry_run)
        log.info(
            f"{'=' * 70}\n"
            f"Run complete | run_id={run_id} | "
            f"adds={stats['adds']} | removes={stats['removes']} | "
            f"dry_run={dry_run}\n"
            f"{'=' * 70}"
        )
        return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

chmod 750 "${BASE}/bin/hotview_tag2grp_hostgroup_sync.py"
chown root:root "${BASE}/bin/hotview_tag2grp_hostgroup_sync.py"
info "Written: ${BASE}/bin/hotview_tag2grp_hostgroup_sync.py"

# =============================================================================
# PHASE 6 — Runtime File Stubs
# =============================================================================
section "Phase 6: Initialising runtime files"

# Log files
touch "${BASE}/log/hotview_tag2grp_sync.log"
touch "${BASE}/log/hotview_tag2grp_audit.jsonl"
chmod 640 "${BASE}/log/hotview_tag2grp_sync.log"
chmod 640 "${BASE}/log/hotview_tag2grp_audit.jsonl"
chown root:root "${BASE}/log/hotview_tag2grp_sync.log"
chown root:root "${BASE}/log/hotview_tag2grp_audit.jsonl"

# Run-state files
echo '{"version":"1.0","last_run_id":"","pending_removes":{}}' \
    > "${BASE}/run/hotview_tag2grp_state.json"
touch "${BASE}/run/hotview_tag2grp.last"
chmod 640 "${BASE}/run/hotview_tag2grp_state.json"
chmod 640 "${BASE}/run/hotview_tag2grp.last"
chown root:root "${BASE}/run/hotview_tag2grp_state.json"
chown root:root "${BASE}/run/hotview_tag2grp.last"

info "Runtime files initialised."

# =============================================================================
# PHASE 7 — Syntax Check
# =============================================================================
section "Phase 7: Python syntax check"

if python3 -m py_compile "${BASE}/bin/hotview_tag2grp_hostgroup_sync.py"; then
    info "Python syntax check passed."
else
    fatal "Python syntax check FAILED. Review the script before proceeding."
fi

# =============================================================================
# PHASE 8 — Deployment Summary
# =============================================================================
section "Deployment Summary"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗"
echo -e "║        hotview_tag2grp — Deployment Complete                    ║"
echo -e "╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${GREEN}Files created:${RESET}"
echo "  ${BASE}/bin/hotview_tag2grp_hostgroup_sync.py  (mode 750)"
echo "  ${BASE}/config/hotview_tag2grp_rules.json      (mode 640)"
echo "  ${BASE}/config/hotview_tag2grp_token.conf      (mode 0600 — STUB)"
echo "  ${BASE}/log/hotview_tag2grp_sync.log           (mode 640)"
echo "  ${BASE}/log/hotview_tag2grp_audit.jsonl        (mode 640)"
echo "  ${BASE}/run/hotview_tag2grp_state.json         (mode 640)"
echo "  ${BASE}/run/hotview_tag2grp.last               (mode 640)"
echo "  ${LOGROTATE_CONF}"
echo ""
echo -e "${YELLOW}REQUIRED NEXT STEPS:${RESET}"
echo ""
echo "  1. Set the Zabbix API URL:"
echo "     Edit: ${BASE}/config/hotview_tag2grp_rules.json"
echo "     Set:  zabbix.api_url  →  your Zabbix server URL"
echo ""
echo "  2. Configure your API token (CHOOSE ONE):"
echo ""
echo "     Option A — Environment variable (preferred):"
echo "       export HOTVIEW_TAG2GRP_TOKEN=\"<your-zabbix-api-token>\""
echo ""
echo "     Option B — Token file:"
echo "       echo '<your-zabbix-api-token>' > ${BASE}/config/hotview_tag2grp_token.conf"
echo "       chmod 0600 ${BASE}/config/hotview_tag2grp_token.conf"
echo "       chown root:root ${BASE}/config/hotview_tag2grp_token.conf"
echo ""
echo "  3. Run the FIRST DRY-RUN (no changes written to Zabbix):"
echo "       python3 ${BASE}/bin/hotview_tag2grp_hostgroup_sync.py --dry-run"
echo ""
echo "  4. Review output:"
echo "       tail -50 ${BASE}/log/hotview_tag2grp_sync.log"
echo "       cat      ${BASE}/log/hotview_tag2grp_audit.jsonl | python3 -m json.tool"
echo ""
echo "  5. When satisfied, enable live mode:"
echo "     Edit: ${BASE}/config/hotview_tag2grp_rules.json"
echo "     Set:  behavior.dry_run  →  false"
echo ""
echo "  6. Schedule with cron (example — runs daily at 02:00):"
echo "     0 2 * * * root HOTVIEW_TAG2GRP_TOKEN=<token> \\"
echo "       python3 ${BASE}/bin/hotview_tag2grp_hostgroup_sync.py"
echo ""
echo -e "${RED}SECURITY:${RESET}"
echo "  Token file MUST remain:  owner=root:root  mode=0600"
echo "  DO NOT: chmod 644, store token in script, pass via CLI args"
echo ""
echo -e "${CYAN}Managed group name format  : AUTO_HV_{VALUE}       e.g. AUTO_HV_CMTS${RESET}"
echo -e "${CYAN}Aggregation host format    : AGG_AUTO_HV_{VALUE}   e.g. AGG_AUTO_HV_CMTS${RESET}"
echo -e "${CYAN}Tag prefix required        : HV_                   e.g. HV_CMTS${RESET}"
echo ""
echo -e "${GREEN}Deployment complete. System is ready for first dry-run.${RESET}"
echo ""
