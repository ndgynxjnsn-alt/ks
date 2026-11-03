# Example apps: sending telemetry to the LGTM cluster

Sample code for teams that want their services in Grafana. Nothing here is deployed with the cluster; it all
runs outside it, the way your own services would. Copy what you need.

| Directory | What it shows |
|---|---|
| `frontend/` | React app with **Grafana Faro**: browser logs, errors, Web Vitals and traces; slow requests reported |
| `backend/` | Spring Boot, five roles in one codebase, run with the **OTel Java agent** and the **Pyroscope agent + OTel extension** |
| `postgres/` | PostgreSQL with a **slow query log**, scraped by an **Alloy sidecar** (metrics + logs) |
| `docker-compose.yml` | All of the above on one Docker host, with agents |
| `swarm/` | The same apps on a 3-node **Docker Swarm** *without* agents: **Beyla** (eBPF), container logs, eBPF profiles, one Prometheus scraper |

All data goes to the cluster's single entry point, Alloy at `alloy.<domain>` (Faro: `faro.<domain>`). Every
request carries the **tenant** in the header `X-Scope-OrgID`; in the lab that's `demo`.

## Run it (one Docker host)

```bash
cd examples
docker compose up -d --build     # cluster address and tenant: .env
```

Open http://localhost:8088 and order a few items. A load generator also places an order every 4 seconds,
but its requests start at the backend, so it creates no browser telemetry.

The browser needs to resolve `faro.lgtm.company.org`: add it to the hosts file next to the other cluster
names (`192.168.56.20`), or use the lab DNS.

## The order, end to end

```
browser ──► shop ──► stock ───► catalog ──► PostgreSQL
 (Faro)       │                    ▲          (slow query log)
              ├────► pricing ──────┘
              └────► notification
```

`shop` calls `stock` and `pricing`, and both call `catalog`, so the trace has a diamond shape. One trace
covers all of it:
* The browser's fetch instrumentation sends `traceparent` with `/api/orders`. The nginx in `frontend/`
  proxies it to `shop` on the same origin, so no CORS setup is needed.
* The Java agent continues the trace through every service and the JDBC call.
* With **sqlcommenter** (`OTEL_INSTRUMENTATION_JDBC_EXPERIMENTAL_SQLCOMMENTER_ENABLED`), the agent appends
  `/*traceparent='00-<trace>-<span>-01'*/` to every SQL statement. PostgreSQL logs statements slower than 1 s
  together with that comment. The Alloy sidecar (`postgres/alloy.alloy`) turns the comment into the log's
  `trace_id` and `span_id`.

Clicking through in Grafana (org **demo**):
* Explore → Tempo → a trace → the `catalog` database span → **Logs for this span**: the logs of the whole
  trace, including PostgreSQL's slow query entry.
* Explore → Loki → `{service_name="postgresql"} |= "duration:"`: a slow query → **View trace**.
* A backend span → **Profiles for this span** (the Pyroscope OTel extension).

About one in five catalog queries is slow on purpose (`pg_sleep`, `backend/.../CatalogController.java`).

## Following a business id (`order.id`)

A trace id is technical, so support asks for the *order*. The order id is created in the browser and carried
along explicitly. This is custom code: the agents only propagate the trace.

| Where | How | Find it in Grafana |
|---|---|---|
| Browser | span `place order` with `order.id`; event `order_submitted`; header `X-Order-Id` + `baggage` (`frontend/src/orders.js`) | Tempo `{ span.order.id = "<id>" }`, Loki `{service_name="shop-frontend"} \|= "<id>"` |
| Backends | filter reads the header (or baggage) → span attribute, MDC, outgoing header (`backend/.../OrderId.java`) | Tempo as above; Loki `{service_name=~".+"} \| order_id="<id>"` |
| Logs | MDC `order.id` → log attribute (`OTEL_INSTRUMENTATION_LOGBACK_APPENDER_EXPERIMENTAL_CAPTURE_MDC_ATTRIBUTES`) | the Loki query above |
| Database | the session's `application_name` is `catalog order.id=<id>` during the query (JDBC client info, `CatalogController.java`). PostgreSQL logs it; Alloy extracts it. Also visible live in `pg_stat_activity`. | the Loki query above |

The Grafana dashboard **Order journey** (org demo) does all of these queries for one pasted order id.
The order id is validated (`[A-Za-z0-9-]`) before it goes into headers, logs and the database session.
Why not an SQL comment like the trace context? sqlcommenter leaves statements that already contain a comment
alone, so a comment of our own would suppress the `traceparent`.
Don't put personal data into baggage, SQL comments or application_name.

## Frontend: what Faro sends, and slow requests

`initializeFaro` (`frontend/src/faro.js`) with the web instrumentations and `TracingInstrumentation` sends:
* page loads, Web Vitals, console errors and exceptions;
* a span for every `fetch`.

Slow requests: the span already has the duration, so latency analysis works from traces (Traces Drilldown,
span metrics). In addition, `orders.js` writes a **WARN log** for every request over 1 s, with the order id,
the duration and the trace context. A log line is easy to search, count and alert on in Loki, and it links
back to the trace.

The Faro URL selects the tenant: `http(s)://faro.<domain>/<tenant>/collect`.

## Docker Swarm (`swarm/`)

```bash
cd examples/swarm
vagrant up                                        # swarm1 (manager), swarm2, swarm3 on the lab network
ansible-playbook -i inventory.yml swarm.yml       # Docker, Swarm, Beyla + alloy-node per node, the stack
```

The shop: http://192.168.56.31:8088. The same images run here without the Java agents. In Grafana the data
has `service.namespace`/`deployment_environment_name` = `swarm`.

| What | How | Why this way |
|---|---|---|
| RED metrics + spans | **Beyla** per node (eBPF, `BEYLA_OPEN_PORT=8080`), names services after their `OTEL_SERVICE_NAME` | no code or agent in the app |
| CPU profiles | `pyroscope.ebpf` in **alloy-node** per node | no agent in the app |
| Container logs | `loki.source.docker` in **alloy-node** per node | every container of the node |
| Prometheus | one Alloy service in the stack (`prometheus.alloy`): Swarm service discovery, scrapes services labelled `prometheus.io/scrape` (Spring Boot `/actuator/prometheus`) + PostgreSQL | one scraper for the whole Swarm |

Beyla and alloy-node are plain containers started by Ansible on each node, not global Swarm services. They
need the host PID namespace, and Swarm services can't have it
([moby#25303](https://github.com/moby/moby/issues/25303)).

Beyla follows the trace context between the services, but its spans aren't connected to the browser's
trace the way the Java agent's are. In the lab VMs some eBPF features may report errors; that's expected
on a single developer machine.
