# Runbook: AppDown

**Alert:** `AppDown`
**Severity:** Critical
**Team:** Platform
**Last reviewed:** 2025-05

---

## What this alert means

The Prometheus target `cloud-app` is returning `up == 0`, meaning Prometheus cannot scrape the application's `/metrics` endpoint. The application is either crashed, unreachable on the network, or the container has stopped.

This directly breaches the availability SLO. Every second this alert is firing, error budget is being consumed.

---

## Immediate impact

| Area | Impact |
|---|---|
| Availability SLO | Actively breaching — 99% target |
| Error budget | Burning at maximum rate |
| Users | All requests failing |
| Downstream | Any service depending on cloud-lab API is affected |

---

## Diagnosis steps

Work through these in order. Stop when you find the cause.

### Step 1 — Confirm the alert is real

```bash
curl -v http://localhost:8080/
curl -v http://localhost:8080/metrics
```

If either responds, the app is up and Prometheus has a scrape issue, not an app issue. Go to Step 5.

If both fail, the app is genuinely down. Continue to Step 2.

---

### Step 2 — Check container state

```bash
docker ps -a --filter "name=cloud-app"
```

**Container is running** → app process crashed inside the container. Go to Step 3.

**Container is stopped/exited** → container stopped unexpectedly. Go to Step 4.

**Container not listed** → container was never started or was removed. Run `./lab up` and monitor.

---

### Step 3 — App crashed inside running container

```bash
docker logs cloud-app --tail 50
```

Look for Python tracebacks, port binding errors, or OOM messages.

```bash
docker exec cloud-app ps aux
```

If uvicorn process is missing, restart:

```bash
docker restart cloud-app
```

Monitor for 60 seconds. If it crashes again, check logs for the root cause before restarting again.

---

### Step 4 — Container stopped or exited

```bash
docker logs cloud-app --tail 50
```

Check exit code:

```bash
docker inspect cloud-app --format='{{.State.ExitCode}}'
```

| Exit code | Meaning |
|---|---|
| 0 | Clean shutdown (unexpected in lab) |
| 1 | App error / Python exception |
| 137 | OOM kill — container ran out of memory |
| 143 | SIGTERM — container was stopped externally |

Restart the container:

```bash
./lab recover
```

If exit code was 137, the container needs a memory limit increase in the `lab` script.

---

### Step 5 — Network or scrape issue

If the app responds but Prometheus shows `up == 0`:

```bash
# Check Prometheus targets page
curl http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -A5 "cloud-lab"
```

Check Docker network:

```bash
docker network inspect cloud-lab-net
```

Confirm cloud-app is attached to the network. If not:

```bash
docker network connect cloud-lab-net cloud-app
```

---

## Recovery steps

```bash
# Standard recovery
./lab recover

# If recovery fails, full restart
./lab down && ./lab up

# Confirm recovery
./lab status
```

After recovery, confirm in Prometheus that `up == 1` for the `cloud-lab` job before closing the incident.

---

## Post-incident checklist

- [ ] App is responding to requests (`curl http://localhost:8080/`)
- [ ] Prometheus shows `up == 1` for `cloud-lab` target
- [ ] Alert has resolved in Alertmanager
- [ ] Grafana availability panel is back to green
- [ ] Error budget panel shows burn rate returning to normal

---

## Escalation

This is a lab environment. In a production context, escalation would go to:

1. On-call SRE (immediate)
2. Platform team lead (if not resolved within 15 minutes)
3. Service owner (if root cause is application code)

---

## Write a postmortem if

- Outage lasted more than 5 minutes
- Root cause was not immediately obvious
- A configuration change preceded the outage

Use the postmortem template at `docs/postmortem-template.md`.
