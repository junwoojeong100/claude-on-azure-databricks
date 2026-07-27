#!/usr/bin/env bash

set -euo pipefail

PROFILE="${DATABRICKS_CONFIG_PROFILE:-claude-code}"

command -v databricks >/dev/null ||
  { echo "Databricks CLI not found." >&2; exit 1; }
command -v python3 >/dev/null ||
  { echo "Python 3 is required to parse the OAuth token response." >&2; exit 1; }

databricks auth token --profile "$PROFILE" --output json |
  python3 -c '
import json
import sys

access_token = json.load(sys.stdin).get("access_token")
if not access_token:
    raise SystemExit("Databricks CLI did not return access_token.")
print(access_token)
'
