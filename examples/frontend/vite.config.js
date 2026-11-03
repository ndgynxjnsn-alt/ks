import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// npm run dev: the API is proxied to the shop backend of examples/docker-compose.yml (port 8081 on the host)
export default defineConfig({
  plugins: [react()],
  server: { proxy: { '/api': 'http://localhost:8081' } },
});
