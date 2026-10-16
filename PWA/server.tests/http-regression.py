"""Run against a local unconfigured Development server, not a production deployment."""
import json
import sys
import urllib.error
import urllib.request

base = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:5081"
origin = "http://127.0.0.1:5173"
checks = 0


def request(path, expected, data=None, headers=None):
    global checks
    extra = {"Content-Type": "application/json", **(headers or {})}
    raw = data.encode() if isinstance(data, str) else json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(base + path, raw, extra)
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        payload = response.read().decode()
        assert response.status == expected, (path, response.status, payload)
        assert response.headers.get("X-Content-Type-Options") == "nosniff"
        if path.startswith("/api"):
            assert response.headers.get("Cache-Control") == "no-store"
            assert "frame-ancestors 'none'" in response.headers["Content-Security-Policy"]
        checks += 1
        return json.loads(payload) if payload else {}


assert request("/health", 200)["status"] == "ok"
assert request("/api/auth/session", 200) == {"configured": False, "user": None}
request("/api/sync", 401)
request("/api/sync", 403, {"operations": []})
request("/api/sync", 403, {"operations": []}, {"Origin": "https://evil.invalid"})
request("/api/sync", 403, {"operations": []}, {"Origin": origin, "Sec-Fetch-Site": "cross-site"})
request("/api/sync", 401, {"operations": []}, {"Origin": origin})
request("/api/sync", 400, '{broken', {"Origin": origin})
request("/api/sync", 400, {"operations": [{"operationId": "wrong"}]}, {"Origin": origin})
request("/api/auth/request-code", 503, {"email": "a@example.test"}, {"Origin": origin})
request("/api/schedule/refresh", 400, {"groupId": "https://evil.invalid", "from": "2026-10-01", "to": "2026-10-02", "durationMinutes": 90}, {"Origin": origin})
request("/api/jobs/run", 401, {})
request("/api/does-not-exist", 404)
print(f"PASS: {checks} HTTP checks (CSRF/origin, no-store, validation, unavailable Auth, private jobs).")
