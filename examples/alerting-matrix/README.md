# Example: Grafana alerts into a Matrix room

**Untested sketch. Nothing here is deployed.** Adapt it to your homeserver, room and rules.

Grafana has no Matrix contact point. Its *webhook* contact point can't call the Matrix API directly either:
sending a message needs `PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}` with a new
`txnId` per message, and Grafana's webhook URL is fixed. A small bridge does the translation:

```
Grafana alert rule -> contact point "matrix" (webhook) -> matrix-alertmanager-receiver -> Matrix homeserver -> room
```

[metio/matrix-alertmanager-receiver](https://github.com/metio/matrix-alertmanager-receiver) accepts
Alertmanager webhooks. Grafana's webhook payload extends the Alertmanager format, so the receiver can read it.
It posts one message per alert group (firing/resolved, templated) as a bot user.

| File | What |
|---|---|
| `receiver.yaml` | Kubernetes manifests for the receiver (config in a Secret, because it holds the bot's access token) |
| `grafana-alerting.yaml` | Grafana provisioning format: contact point, notification policy, one example rule |

## Steps

1. On the homeserver, create a bot user (e.g. `@grafana-alerts:matrix.company.org`), invite it to the room,
   accept the invite as the bot, and get an access token for it (log in with the bot, or use the admin API).
2. Put the homeserver URL, bot id, token and room id into `receiver.yaml` and apply it to namespace `lgtm`.
3. Create the contact point, policy and rule in the Grafana org that should alert (e.g. *platform*):
   **Alerting → Import** with `grafana-alerting.yaml`, or `POST /api/v1/provisioning/...`.
   Alert rules are kept in Grafana's database, not in Git: Git Sync only syncs dashboards and folders.
   The PostgreSQL backups cover them.
4. Test: **Alerting → Contact points → matrix → Test**.

Alternatives: [grafana-matrix-forwarder](https://github.com/hectorjsmith/grafana-matrix-forwarder) is a bridge
built for Grafana's payload. [matrix-hookshot](https://github.com/matrix-org/matrix-hookshot) generic webhooks
work if the homeserver already runs hookshot.
