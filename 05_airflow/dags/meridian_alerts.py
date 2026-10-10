"""
Failure alerts for the Meridian pipelines.

Standard library only, so it is unit tested without Airflow installed. Every alert goes to
the task log as one JSON line; when MERIDIAN_SLACK_WEBHOOK_URL holds a Slack incoming-webhook
URL it is also posted to that channel. An empty variable means log only.
"""
from __future__ import annotations

import json
import logging
import os
import urllib.request

WEBHOOK_ENV = "MERIDIAN_SLACK_WEBHOOK_URL"

log = logging.getLogger("meridian.alert")


def slack_text(payload: dict) -> str:
    error = str(payload.get("exception") or "no exception text")[:500]
    return (
        f":red_circle: *{payload.get('dag_id')} / {payload.get('task_id')}* failed "
        f"(try {payload.get('try_number')})\n"
        f"run `{payload.get('run_id')}`\n"
        f"```{error}```\n"
        f"<{payload.get('log_url')}|Open the task log>"
    )


def send_alert(payload: dict, webhook_url: str | None = None, opener=urllib.request.urlopen) -> bool:
    """Log the alert, then post it to Slack if a webhook is configured. Returns True when Slack accepted it."""
    log.error("%s", json.dumps(payload, default=str))
    url = os.getenv(WEBHOOK_ENV, "") if webhook_url is None else webhook_url
    if not url:
        return False
    request = urllib.request.Request(
        url,
        data=json.dumps({"text": slack_text(payload)}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with opener(request, timeout=5) as response:
            return 200 <= response.status < 300
    except Exception:  # an alert must never fail or hang the task it reports on
        log.exception("Slack alert could not be delivered")
        return False
