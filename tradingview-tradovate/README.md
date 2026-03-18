# TradingView → Tradovate Integration

Server webhook care primește alerte din **TradingView** și plasează ordine pe **Tradovate** via REST API.

## Flux de funcționare

```
TradingView Alert
      │
      │  POST /webhook  (JSON cu secret)
      ▼
┌─────────────┐    OAuth2     ┌──────────────┐
│  Webhook    │ ────────────► │  Tradovate   │
│  Server     │  placeOrder   │  REST API    │
└─────────────┘               └──────────────┘
```

## Instalare & Pornire

```bash
cd tradingview-tradovate
cp .env.example .env
# editați .env cu credențialele reale
node server.js
```

## Configurare `.env`

| Variabilă | Descriere |
|---|---|
| `PORT` | Port server local (implicit 3000) |
| `WEBHOOK_SECRET` | Secret partajat cu TradingView |
| `TRADOVATE_ENV` | `demo` sau `live` |
| `TRADOVATE_USERNAME` | Email cont Tradovate |
| `TRADOVATE_PASSWORD` | Parolă cont Tradovate |
| `TRADOVATE_APP_ID` | ID aplicație înregistrată în Tradovate |
| `TRADOVATE_CID` | Device CID (din Tradovate Developer Portal) |
| `TRADOVATE_SEC` | Device Secret |
| `TRADOVATE_ACCOUNT_ID` | ID contul de trading |

## Configurare alertă în TradingView

1. Creați o alertă pe orice indicator/strategie
2. În **"Webhook URL"** puneți: `https://server-ul-tau.com/webhook`
3. În **"Message"** puneți JSON-ul:

```json
{
  "secret": "secretul_tau_din_env",
  "symbol": "ESM4",
  "action": "buy",
  "qty": 1,
  "orderType": "market"
}
```

### Câmpuri JSON disponibile

| Câmp | Obligatoriu | Valori | Descriere |
|---|---|---|---|
| `secret` | DA | string | Trebuie să coincidă cu `WEBHOOK_SECRET` |
| `symbol` | DA | ex: `ESM4`, `NQM4` | Simbolul contractului Tradovate |
| `action` | DA | `buy` / `sell` | Direcția ordinului |
| `qty` | Nu | număr întreg | Contracte (implicit 1) |
| `orderType` | Nu | `market` / `limit` / `stop` | Tipul ordinului (implicit `market`) |
| `price` | Doar limit | număr | Prețul pentru ordin limit |
| `stopPrice` | Doar stop | număr | Prețul pentru ordin stop |
| `accountId` | Nu | număr | Suprascrie `TRADOVATE_ACCOUNT_ID` |

## Exemple TradingView (variabile dinamice)

```json
{
  "secret": "secretul_tau",
  "symbol": "{{ticker}}",
  "action": "{{strategy.order.action}}",
  "qty": {{strategy.order.contracts}},
  "orderType": "market"
}
```

## Endpoint-uri server

| Metodă | Path | Descriere |
|---|---|---|
| `POST` | `/webhook` | Primește alerte TradingView |
| `GET` | `/health` | Verificare stare server |

## Securitate

- Serverul validează `secret` din fiecare request folosind comparație time-safe (prevenire timing attacks)
- Folosiți **HTTPS** în producție (nginx reverse proxy + Let's Encrypt)
- Folosiți **`demo`** pentru testare înainte de a trece pe `live`
- Nu publicați niciodată `.env` sau credențialele

## Testare manuală

```bash
# Health check
curl http://localhost:3000/health

# Simulare webhook (înlocuiți secretul)
curl -X POST http://localhost:3000/webhook \
  -H "Content-Type: application/json" \
  -d '{
    "secret": "schimba_asta_cu_un_secret_sigur",
    "symbol": "ESM4",
    "action": "buy",
    "qty": 1,
    "orderType": "market"
  }'
```
