/**
 * TradingView → Tradovate Integration
 *
 * Primește alerte webhook de la TradingView și plasează ordine pe Tradovate.
 * Flow:
 *   1. TradingView trimite un POST webhook cu payload JSON
 *   2. Server-ul autentifică request-ul (secret token)
 *   3. Se autentifică la API-ul Tradovate (OAuth2)
 *   4. Se plasează ordinul pe Tradovate
 */

'use strict';

const http = require('http');
const https = require('https');
const crypto = require('crypto');

// ─── Configurare (suprascrisă de env vars) ────────────────────────────────────
const CONFIG = {
  // Server local
  PORT: process.env.PORT || 3000,

  // Secret partajat cu TradingView (setați în alerta TradingView ca parametru "secret")
  WEBHOOK_SECRET: process.env.WEBHOOK_SECRET || 'schimba_asta_cu_un_secret_sigur',

  // Credențiale Tradovate
  TRADOVATE_USERNAME: process.env.TRADOVATE_USERNAME || '',
  TRADOVATE_PASSWORD: process.env.TRADOVATE_PASSWORD || '',
  TRADOVATE_APP_ID: process.env.TRADOVATE_APP_ID || '',
  TRADOVATE_APP_VERSION: process.env.TRADOVATE_APP_VERSION || '1.0',
  TRADOVATE_CID: process.env.TRADOVATE_CID || '',   // Device CID
  TRADOVATE_SEC: process.env.TRADOVATE_SEC || '',   // Device Secret

  // Endpoint Tradovate: 'demo' sau 'live'
  TRADOVATE_ENV: process.env.TRADOVATE_ENV || 'demo',
};

const TRADOVATE_HOSTS = {
  demo: 'demo.tradovateapi.com',
  live: 'live.tradovateapi.com',
};

// ─── Stare autentificare ──────────────────────────────────────────────────────
let authToken = null;
let tokenExpiry = 0;

// ─── Utilitar: request HTTPS ──────────────────────────────────────────────────
function httpsRequest(options, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(data) });
        } catch {
          resolve({ status: res.statusCode, body: data });
        }
      });
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

// ─── Autentificare Tradovate ──────────────────────────────────────────────────
async function authenticate() {
  if (authToken && Date.now() < tokenExpiry) return authToken;

  console.log('[auth] Autentificare la Tradovate...');

  const host = TRADOVATE_HOSTS[CONFIG.TRADOVATE_ENV];
  const payload = {
    name: CONFIG.TRADOVATE_USERNAME,
    password: CONFIG.TRADOVATE_PASSWORD,
    appId: CONFIG.TRADOVATE_APP_ID,
    appVersion: CONFIG.TRADOVATE_APP_VERSION,
    cid: CONFIG.TRADOVATE_CID,
    sec: CONFIG.TRADOVATE_SEC,
  };

  const bodyStr = JSON.stringify(payload);
  const result = await httpsRequest({
    hostname: host,
    path: '/v1/auth/accesstokenrequest',
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(bodyStr),
    },
  }, payload);

  if (result.status !== 200 || !result.body.accessToken) {
    throw new Error(`Autentificare eșuată: ${JSON.stringify(result.body)}`);
  }

  authToken = result.body.accessToken;
  // Token-ul Tradovate expiră în ~24h; reîmprospătăm cu 5 min înainte
  const expiresIn = result.body.expirationTime
    ? new Date(result.body.expirationTime).getTime() - Date.now() - 5 * 60 * 1000
    : 23 * 60 * 60 * 1000;
  tokenExpiry = Date.now() + expiresIn;

  console.log('[auth] Autentificare reușită.');
  return authToken;
}

// ─── Căutare contract Tradovate ───────────────────────────────────────────────
async function findContract(symbol) {
  const token = await authenticate();
  const host = TRADOVATE_HOSTS[CONFIG.TRADOVATE_ENV];

  const result = await httpsRequest({
    hostname: host,
    path: `/v1/contract/find?name=${encodeURIComponent(symbol)}`,
    method: 'GET',
    headers: { Authorization: `Bearer ${token}` },
  });

  if (result.status !== 200) {
    throw new Error(`Contract negăsit pentru ${symbol}: ${JSON.stringify(result.body)}`);
  }
  return result.body; // { id, name, ... }
}

// ─── Plasare ordin Tradovate ──────────────────────────────────────────────────
/**
 * @param {object} params
 * @param {string} params.symbol    - ex: "ESM4", "NQM4"
 * @param {'Buy'|'Sell'} params.action
 * @param {number} params.qty       - număr contracte
 * @param {'Market'|'Limit'|'Stop'} params.orderType
 * @param {number} [params.price]   - obligatoriu pentru Limit
 * @param {number} [params.stopPrice] - obligatoriu pentru Stop
 * @param {number} [params.accountId]
 */
async function placeOrder(params) {
  const token = await authenticate();
  const host = TRADOVATE_HOSTS[CONFIG.TRADOVATE_ENV];

  const contract = await findContract(params.symbol);

  const orderPayload = {
    accountId: params.accountId || parseInt(CONFIG.TRADOVATE_ACCOUNT_ID || '0'),
    contractId: contract.id,
    action: params.action,   // 'Buy' | 'Sell'
    orderQty: params.qty,
    orderType: params.orderType || 'Market',
    ...(params.price && { price: params.price }),
    ...(params.stopPrice && { stopPrice: params.stopPrice }),
  };

  console.log(`[order] Plasare ordin:`, orderPayload);

  const result = await httpsRequest({
    hostname: host,
    path: '/v1/order/placeorder',
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
  }, orderPayload);

  if (result.status !== 200) {
    throw new Error(`Eroare plasare ordin: ${JSON.stringify(result.body)}`);
  }

  console.log(`[order] Ordin plasat cu succes:`, result.body);
  return result.body;
}

// ─── Parsare payload TradingView ──────────────────────────────────────────────
/**
 * Format așteptat din TradingView (mesaj alert JSON):
 * {
 *   "secret": "...",          // obligatoriu - trebuie să coincidă cu WEBHOOK_SECRET
 *   "symbol": "ESM4",        // simbolul contractului
 *   "action": "buy",         // "buy" sau "sell"
 *   "qty": 1,                // număr contracte (opțional, implicit 1)
 *   "orderType": "market",   // "market", "limit", "stop" (opțional)
 *   "price": 5000.25,        // pentru ordine limit (opțional)
 *   "stopPrice": 4990.00,    // pentru ordine stop (opțional)
 *   "accountId": 123456      // ID cont Tradovate (opțional)
 * }
 */
function parseTradingViewPayload(body) {
  const action = (body.action || '').toLowerCase();
  if (!['buy', 'sell'].includes(action)) {
    throw new Error(`Acțiune invalidă: "${body.action}". Folosiți "buy" sau "sell".`);
  }
  if (!body.symbol) {
    throw new Error('Câmpul "symbol" este obligatoriu.');
  }

  return {
    symbol: body.symbol.toUpperCase(),
    action: action === 'buy' ? 'Buy' : 'Sell',
    qty: Math.max(1, parseInt(body.qty || 1)),
    orderType: (['market', 'limit', 'stop'].includes((body.orderType || '').toLowerCase()))
      ? body.orderType.charAt(0).toUpperCase() + body.orderType.slice(1).toLowerCase()
      : 'Market',
    price: body.price ? parseFloat(body.price) : undefined,
    stopPrice: body.stopPrice ? parseFloat(body.stopPrice) : undefined,
    accountId: body.accountId ? parseInt(body.accountId) : undefined,
  };
}

// ─── HTTP Server ──────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  // Health check
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', env: CONFIG.TRADOVATE_ENV }));
    return;
  }

  // Webhook endpoint
  if (req.method === 'POST' && req.url === '/webhook') {
    let rawBody = '';
    req.on('data', (chunk) => { rawBody += chunk; });
    req.on('end', async () => {
      try {
        // Parsare JSON
        let body;
        try {
          body = JSON.parse(rawBody);
        } catch {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'JSON invalid' }));
          return;
        }

        // Verificare secret
        const providedSecret = body.secret || req.headers['x-webhook-secret'];
        if (!providedSecret || !crypto.timingSafeEqual(
          Buffer.from(providedSecret),
          Buffer.from(CONFIG.WEBHOOK_SECRET)
        )) {
          console.warn('[webhook] Secret invalid!');
          res.writeHead(401, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Unauthorized' }));
          return;
        }

        // Parsare și plasare ordin
        const orderParams = parseTradingViewPayload(body);
        console.log(`[webhook] Semnal primit: ${orderParams.action} ${orderParams.qty}x ${orderParams.symbol}`);

        const result = await placeOrder(orderParams);

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: true, order: result }));
      } catch (err) {
        console.error('[webhook] Eroare:', err.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: err.message }));
      }
    });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(CONFIG.PORT, () => {
  console.log(`
╔══════════════════════════════════════════════════════╗
║     TradingView → Tradovate Integration Server       ║
╚══════════════════════════════════════════════════════╝
  Port:     ${CONFIG.PORT}
  Mediu:    ${CONFIG.TRADOVATE_ENV.toUpperCase()}
  Webhook:  POST http://localhost:${CONFIG.PORT}/webhook
  Health:   GET  http://localhost:${CONFIG.PORT}/health
`);
});

module.exports = { placeOrder, authenticate }; // pentru teste
