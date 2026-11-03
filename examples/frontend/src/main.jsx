import './faro.js';   // first: Faro instruments fetch, errors and the page load
import { StrictMode, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { placeOrder } from './orders.js';

const ITEMS = Array.from({ length: 12 }, (_, i) => i + 1);

function App() {
  const [orders, setOrders] = useState([]);
  const [busy, setBusy] = useState(null);

  async function order(itemId) {
    setBusy(itemId);
    try {
      const result = await placeOrder(itemId);
      setOrders((list) => [{ ...result, ok: true }, ...list].slice(0, 10));
    } catch (error) {
      setOrders((list) => [{ itemId, error: String(error), ok: false }, ...list].slice(0, 10));
    } finally {
      setBusy(null);
    }
  }

  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', maxWidth: 720, margin: '2rem auto', padding: '0 1rem' }}>
      <h1>Example shop</h1>
      <p>Order an item. About every fifth database query is slow on purpose (&gt; 1 s).</p>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.5rem' }}>
        {ITEMS.map((id) => (
          <button key={id} disabled={busy !== null} onClick={() => order(id)}>
            {busy === id ? '…' : `Item ${id}`}
          </button>
        ))}
      </div>
      <h2>Orders</h2>
      <table style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead><tr><th align="left">Order id</th><th>Item</th><th>Price</th><th>Duration</th></tr></thead>
        <tbody>
          {orders.map((o, i) => (
            <tr key={i} style={{ color: o.ok ? 'inherit' : 'crimson' }}>
              <td><code>{o.orderId ?? o.error}</code></td>
              <td align="center">{o.itemId}</td>
              <td align="center">{o.price?.gross ?? '–'}</td>
              <td align="center" style={{ fontWeight: o.ms > 1000 ? 'bold' : 'normal' }}>{o.ms ? `${o.ms} ms` : '–'}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </main>
  );
}

createRoot(document.getElementById('root')).render(<StrictMode><App /></StrictMode>);
