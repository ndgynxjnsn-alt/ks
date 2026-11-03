// Grafana Faro: browser telemetry to the LGTM cluster.
//   logs, errors, events, Web Vitals -> Loki;  traces (page load, fetch) -> Tempo
// The URL names the tenant: faro.<domain>/<tenant>/collect (the cluster routes each tenant to its own receiver).
// The fetch instrumentation sends a W3C traceparent header with every same-origin request (/api/...), so the
// backend spans join the browser's trace: one trace from the click to the database.
import { getWebInstrumentations, initializeFaro, LogLevel } from '@grafana/faro-web-sdk';
import { TracingInstrumentation } from '@grafana/faro-web-tracing';

export const faro = initializeFaro({
  url: import.meta.env.VITE_FARO_URL ?? 'http://faro.lgtm.company.org/demo/collect',
  app: {
    name: 'shop-frontend',
    namespace: 'examples',
    version: '1.0.0',
    environment: 'lab',
  },
  instrumentations: [...getWebInstrumentations(), new TracingInstrumentation()],
});

export { LogLevel };
