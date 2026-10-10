"""Failure alerts: silent without a webhook, one Slack POST with one, never raises."""
import json
import urllib.error

import meridian_alerts
from meridian_alerts import send_alert, slack_text

PAYLOAD = {
    "event": "meridian_task_failed",
    "dag_id": "meridian_microbatch_ingest",
    "task_id": "pipeline_health_gate",
    "run_id": "scheduled__2026-10-06T10:05:00+00:00",
    "try_number": 3,
    "log_url": "http://localhost:8080/log",
    "exception": "pipeline lag 22 min > 15 min",
}


class FakeResponse:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_no_webhook_means_log_only(monkeypatch):
    monkeypatch.delenv(meridian_alerts.WEBHOOK_ENV, raising=False)
    calls = []
    assert send_alert(PAYLOAD, opener=lambda *a, **k: calls.append(a)) is False
    assert calls == []


def test_webhook_gets_one_json_post(monkeypatch):
    monkeypatch.setenv(meridian_alerts.WEBHOOK_ENV, "https://hooks.example.test/T000/B000/x")
    sent = []

    def opener(request, timeout):
        sent.append((request, timeout))
        return FakeResponse()

    assert send_alert(PAYLOAD, opener=opener) is True
    request, timeout = sent[0]
    assert len(sent) == 1 and timeout == 5
    assert request.get_method() == "POST"
    assert request.full_url == "https://hooks.example.test/T000/B000/x"
    assert "pipeline_health_gate" in json.loads(request.data)["text"]


def test_slack_outage_never_raises():
    def opener(request, timeout):
        raise urllib.error.URLError("connection refused")

    assert send_alert(PAYLOAD, webhook_url="https://hooks.example.test/x", opener=opener) is False


def test_long_exception_is_trimmed():
    text = slack_text({**PAYLOAD, "exception": "x" * 5000})
    assert text.count("x") == 500
