"""Isolated TEST CLUSTER only, after mock-auth.sql + schema.sql. No extra Python packages."""
import json
import os
import subprocess
import time

psql = os.environ.get("PSQL", "psql")
command = [psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1"]
user = "dddddddd-dddd-dddd-dddd-dddddddddddd"


def run(sql):
    return subprocess.run(command, input=sql, text=True, check=True, capture_output=True).stdout.strip()


run(f"insert into auth.users(id,email) values('{user}','concurrency@example.test');")
identity = f"set local role authenticated; set local request.jwt.claim.sub='{user}';"
try:
    run(f"begin; {identity} select public.pwa_sync('[]'); commit;")
    operation = json.dumps([{
        "operationId": "dddddddd-dddd-dddd-dddd-dddddddddd01", "entityId": "concurrent-task",
        "kind": "task", "baseVersion": 0, "base": None,
        "data": {"title": "Committed", "date": "2026-10-13", "groupId": None, "note": "", "completed": False},
    }])
    writer = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    writer.stdin.write(f"begin; {identity} select public.pwa_sync('{operation}'); select 'writer-holds-lock'; select pg_sleep(0.6); commit;\n")
    writer.stdin.close()
    while True:
        line = writer.stdout.readline()
        if line.strip() == "writer-holds-lock":
            break
        if not line:
            raise AssertionError(writer.stderr.read())
    started = time.monotonic()
    snapshot = json.loads(run(f"begin; {identity} select public.pwa_sync('[]'); commit;"))
    elapsed = time.monotonic() - started
    writer.wait(timeout=10)
    assert writer.returncode == 0, writer.stderr.read()
    assert elapsed > 0.3, f"Snapshot did not wait for uncommitted writer: {elapsed}"
    assert snapshot["revision"] == 1 and len(snapshot["records"]) == 1 and snapshot["records"][0]["data"]["title"] == "Committed", snapshot
    print("PASS: snapshot/revision serialized until writer COMMIT; no skipped late commit.")
finally:
    run(f"delete from auth.users where id='{user}';")
