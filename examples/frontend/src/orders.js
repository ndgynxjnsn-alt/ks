import { faro, LogLevel } from './faro.js';

// Requests slower than this are reported as WARN log (in addition to the trace, which has every duration):
// a log line is easy to search, count and alert on in Loki, and it carries the trace id and the order id.
const SLOW_MS = 1000;

// The business id: created here, at the very start, so the browser's own telemetry already carries it.
// crypto.randomUUID needs a secure context (https or localhost); the fallback covers plain http.
function newOrderId() {
  return crypto.randomUUID?.() ?? `${Date.now().toString(16)}-${Math.random().toString(16).slice(2, 14)}`;
}

/**
 * Places an order. Follow it by its id:
 *   Tempo:  { span.order.id = "<id>" }          (browser span "place order" and every backend server span)
 *   Loki:   {service_name=~".+"} | order_id="<id>"   (backends, PostgreSQL slow query log)
 *           {service_name="shop-frontend"} |= "<id>"      (this frontend)
 */
export async function placeOrder(itemId) {
  const orderId = newOrderId();
  const otel = faro.api.getOTEL();
  const tracer = otel.trace.getTracer('shop-frontend');

  return tracer.startActiveSpan('place order', { attributes: { 'order.id': orderId, 'item.id': itemId } },
    async (span) => {
      faro.api.pushEvent('order_submitted', { order_id: orderId, item_id: String(itemId) });
      const started = performance.now();
      try {
        const response = await fetch('/api/orders', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-Order-Id': orderId,               // read by the backends (examples/backend OrderId.java)
            baggage: `order.id=${orderId}`,      // the same as W3C baggage, for any OTel-instrumented service
          },
          body: JSON.stringify({ itemId }),
        });
        const ms = Math.round(performance.now() - started);
        span.setAttribute('http.response.status_code', response.status);
        if (ms > SLOW_MS) {
          faro.api.pushLog([`slow request: POST /api/orders took ${ms} ms`], {
            level: LogLevel.WARN,
            context: { order_id: orderId, item_id: String(itemId), duration_ms: String(ms) },
            spanContext: span.spanContext(),
          });
        }
        if (!response.ok) {
          throw new Error(`order ${orderId} failed: HTTP ${response.status}`);
        }
        return { ...(await response.json()), ms };
      } catch (error) {
        faro.api.pushError(error, { context: { order_id: orderId } });
        span.recordException(error);
        span.setStatus({ code: otel.trace.SpanStatusCode?.ERROR ?? 2 });
        throw error;
      } finally {
        span.end();
      }
    });
}
