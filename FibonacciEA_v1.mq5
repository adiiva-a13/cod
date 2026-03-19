//+------------------------------------------------------------------+
//|  FibonacciEA_v1.mq5                                              |
//|  Strategie Fibonacci Retracement                                  |
//|  Directie: 4H EMA | Confirmare: 1H EMA | Entry: M1 swing 1-3%   |
//|  Entry 1: zona 0.750-0.786, SL la 0.886                         |
//|  Entry 2: nivel 0.886, SL la 1.0                                 |
//|  Sesiune: 15:00-19:00 | Max 2 tranzactii/zi                      |
//+------------------------------------------------------------------+
#property strict
#property description "Fibonacci Retracement EA v1"

// ─────────────────────────────────────────────
// 1. PARAMETRI
// ─────────────────────────────────────────────
input group "=== RISK MANAGEMENT ==="
input double RiskMoney       = 100.0;   // Risc per tranzactie ($)
input double RRRatio         = 2.0;     // Raport Risc/Recompensa
input double MaxLotLimit     = 10.0;    // Lot maxim
input double BE_Activation   = 1.0;     // Activare Break-Even (x risc, 0=dezactivat)

input group "=== FIBONACCI NIVELE ==="
input double Fib_Entry1_Low  = 0.750;   // Zona entry 1 – capatul SUPERIOR ca procent
input double Fib_Entry1_High = 0.786;   // Zona entry 1 – capatul INFERIOR ca procent
input double Fib_Entry2      = 0.886;   // Nivel entry 2
input double SL_Buffer_Pts   = 15.0;    // Buffer SL dincolo de nivelul de referinta (puncte)

input group "=== SWING DETECTIE M1 ==="
input int    Pivot_Bars      = 5;        // Bare de confirmare pivot (fiecare parte)
input int    Swing_Lookback  = 300;      // Bare M1 lookback pentru swing
input double Min_Swing_Pct   = 1.0;     // Range minim swing (%)
input double Max_Swing_Pct   = 3.0;     // Range maxim swing (%)

input group "=== TREND FILTER ==="
input int    EMA_4H_Period   = 200;      // Period EMA pe 4H (directie principala)
input int    EMA_1H_Period   = 50;       // Period EMA pe 1H (confirmare)

input group "=== SESIUNE ==="
input int    SessionStartHour = 15;      // Ora start sesiune (ora server MT5)
input int    SessionEndHour   = 19;      // Ora sfarsit sesiune (ora server MT5)
input int    MaxDailyTrades   = 2;       // Tranzactii maxime per zi

input group "=== SETARI AVANSATE ==="
input int    MagicNumber     = 12345;    // Magic number unic
input int    Slippage        = 10;       // Slippage maxim (puncte)

// ─────────────────────────────────────────────
// 2. VARIABILE GLOBALE
// ─────────────────────────────────────────────
int      g_daily_trades  = 0;
datetime g_last_day      = 0;
double   g_fib_high      = 0;
double   g_fib_low       = 0;
int      g_fib_dir       = 0;       // 1=BUY setup, -1=SELL setup
bool     g_fib_valid     = false;
bool     g_entry1_taken  = false;
bool     g_entry2_taken  = false;
int      h_ema_4h        = INVALID_HANDLE;
int      h_ema_1h        = INVALID_HANDLE;

// ─────────────────────────────────────────────
// 3. OnInit / OnDeinit
// ─────────────────────────────────────────────
int OnInit()
{
   h_ema_4h = iMA(_Symbol, PERIOD_H4, EMA_4H_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_ema_1h = iMA(_Symbol, PERIOD_H1, EMA_1H_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(h_ema_4h == INVALID_HANDLE || h_ema_1h == INVALID_HANDLE)
   {
      Print("❌ Eroare creare handle EMA.");
      return INIT_FAILED;
   }
   PrintFormat("✅ FibonacciEA v1 initializat pe %s | Magic: %d | Sesiune: %02d:00-%02d:00 | EMA 4H(%d) / 1H(%d)",
               _Symbol, MagicNumber, SessionStartHour, SessionEndHour,
               EMA_4H_Period, EMA_1H_Period);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(h_ema_4h != INVALID_HANDLE) IndicatorRelease(h_ema_4h);
   if(h_ema_1h != INVALID_HANDLE) IndicatorRelease(h_ema_1h);
   Print("EA oprit. Motiv: ", reason);
}

// ─────────────────────────────────────────────
// 4. DIRECTIA TRENDULUI
//    Compara pretul de inchidere al barei precedente cu EMA
//    pe ambele timeframe-uri. Ambele trebuie sa confirme.
//    Returneaza: 1=uptrend, -1=downtrend, 0=conflict (nu tranzactionam)
// ─────────────────────────────────────────────
int GetTrendDirection()
{
   double ema4h[1], ema1h[1], c4h[1], c1h[1];
   ArraySetAsSeries(ema4h, true);
   ArraySetAsSeries(ema1h, true);
   ArraySetAsSeries(c4h,   true);
   ArraySetAsSeries(c1h,   true);

   if(CopyBuffer(h_ema_4h, 0, 1, 1, ema4h) < 1) return 0;
   if(CopyBuffer(h_ema_1h, 0, 1, 1, ema1h) < 1) return 0;
   if(CopyClose(_Symbol, PERIOD_H4, 1, 1, c4h)  < 1) return 0;
   if(CopyClose(_Symbol, PERIOD_H1, 1, 1, c1h)  < 1) return 0;

   bool up_4h = (c4h[0] > ema4h[0]);
   bool up_1h = (c1h[0] > ema1h[0]);

   if( up_4h &&  up_1h) return  1;
   if(!up_4h && !up_1h) return -1;
   return 0;
}

// ─────────────────────────────────────────────
// 5. PRET LA NIVEL FIBONACCI
//
//  dir = 1  (BUY, uptrend):
//    Masurat de la HIGH catre LOW (retracement)
//    level 0.0 = HIGH, level 1.0 = LOW
//    fib_price = high - level * (high - low)
//
//  dir = -1 (SELL, downtrend):
//    Masurat de la LOW catre HIGH (bounce)
//    level 0.0 = LOW, level 1.0 = HIGH
//    fib_price = low + level * (high - low)
// ─────────────────────────────────────────────
double FibPrice(int dir, double hi, double lo, double level)
{
   if(dir == 1)
      return NormalizeDouble(hi - level * (hi - lo), _Digits);
   else
      return NormalizeDouble(lo + level * (hi - lo), _Digits);
}

// ─────────────────────────────────────────────
// 6. DETECTIE SWING FIBONACCI PE M1
//
//  BUY (dir=1):
//    Cauta cel mai recent pivot HIGH pe M1, urmat de un pivot LOW mai vechi.
//    Pret curent trebuie sa fie sub swing high (in retracement).
//
//  SELL (dir=-1):
//    Cauta cel mai recent pivot LOW pe M1, precedat de un pivot HIGH mai vechi.
//    Pret curent trebuie sa fie peste swing low (in bounce).
//
//  Range filter: (high - low) / low intre Min_Swing_Pct si Max_Swing_Pct.
// ─────────────────────────────────────────────
bool FindFibSwing(int trend_dir, double &out_hi, double &out_lo)
{
   int bars   = Swing_Lookback + Pivot_Bars * 2 + 2;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   // Pornim de la bara 1 (ultima bara inchisa), nu de la bara 0 (in formare)
   int copied = CopyRates(_Symbol, PERIOD_M1, 1, bars, r);
   if(copied < Pivot_Bars * 2 + 4) return false;

   int    usable  = copied - Pivot_Bars - 1;
   double min_rng = Min_Swing_Pct / 100.0;
   double max_rng = Max_Swing_Pct / 100.0;

   if(trend_dir == 1) // BUY: pivot HIGH recent + pivot LOW precedent
   {
      for(int i = Pivot_Bars; i < usable; i++)
      {
         // Test pivot HIGH la bara i
         bool is_ph = true;
         for(int k = 1; k <= Pivot_Bars && is_ph; k++)
            if(r[i].high <= r[i-k].high || r[i].high <= r[i+k].high) is_ph = false;
         if(!is_ph) continue;

         double sh = r[i].high;

         // Cauta pivot LOW precedent (bara mai veche = indice mai mare in seria desc)
         for(int j = i + Pivot_Bars; j < usable; j++)
         {
            bool is_pl = true;
            for(int k = 1; k <= Pivot_Bars && is_pl; k++)
               if(r[j].low >= r[j-k].low || r[j].low >= r[j+k].low) is_pl = false;
            if(!is_pl) continue;

            double sl  = r[j].low;
            if(sh <= sl) break; // high trebuie sa fie mai mare decat low

            double rng = (sh - sl) / sl;
            if(rng > max_rng) break;  // swing prea mare, nu cautam mai departe
            if(rng < min_rng) continue; // swing prea mic, continuam cu un low mai vechi

            // Pret curent sub swing high (in retracement)
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            if(bid >= sh) break; // pretul nu a coborat inca sub high → nu e retracement

            out_hi = sh;
            out_lo = sl;
            return true;
         }
      }
   }
   else if(trend_dir == -1) // SELL: pivot LOW recent + pivot HIGH precedent
   {
      for(int i = Pivot_Bars; i < usable; i++)
      {
         // Test pivot LOW la bara i
         bool is_pl = true;
         for(int k = 1; k <= Pivot_Bars && is_pl; k++)
            if(r[i].low >= r[i-k].low || r[i].low >= r[i+k].low) is_pl = false;
         if(!is_pl) continue;

         double sl = r[i].low;

         // Cauta pivot HIGH precedent
         for(int j = i + Pivot_Bars; j < usable; j++)
         {
            bool is_ph = true;
            for(int k = 1; k <= Pivot_Bars && is_ph; k++)
               if(r[j].high <= r[j-k].high || r[j].high <= r[j+k].high) is_ph = false;
            if(!is_ph) continue;

            double sh  = r[j].high;
            if(sh <= sl) break;

            double rng = (sh - sl) / sl;
            if(rng > max_rng) break;
            if(rng < min_rng) continue;

            // Pret curent peste swing low (in bounce)
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            if(ask <= sl) break; // pretul nu a urcat inca peste low

            out_hi = sh;
            out_lo = sl;
            return true;
         }
      }
   }

   return false;
}

// ─────────────────────────────────────────────
// 7. TRIMITERE ORDIN cu calcul lot
// ─────────────────────────────────────────────
bool SendOrder(ENUM_ORDER_TYPE type, double entry, double sl, double tp)
{
   double real_risk = MathAbs(entry - sl);
   if(real_risk <= 0)
   { Print("❌ Risc = 0, ordin anulat."); return false; }

   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0 || tick_value <= 0)
   { Print("❌ Date simbol invalide (tick_size/tick_value)."); return false; }

   double point_value = tick_value / tick_size;
   double lot_raw     = RiskMoney / (real_risk * point_value);
   double vol_min     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vol_max     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vol_step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lot         = MathFloor(lot_raw / vol_step) * vol_step;
   lot = MathMax(lot, vol_min);
   lot = MathMin(lot, MathMin(MaxLotLimit, vol_max));

   ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode != SYMBOL_TRADE_MODE_FULL)
   { PrintFormat("❌ Market inchis (mode=%d) - ordin anulat.", (int)mode); return false; }

   double margin = 0;
   if(OrderCalcMargin(type, _Symbol, lot, entry, margin))
   {
      double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin > free * 0.95)
      { PrintFormat("❌ Margin insuficient (necesar=%.2f, disponibil=%.2f).", margin, free); return false; }
   }

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.volume    = lot;
   req.type      = type;
   req.price     = entry;
   req.sl        = NormalizeDouble(sl, _Digits);
   req.tp        = NormalizeDouble(tp, _Digits);
   req.magic     = MagicNumber;
   req.deviation = Slippage;
   req.comment   = "FibEA v1";

   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if     ((filling & SYMBOL_FILLING_FOK) != 0) req.type_filling = ORDER_FILLING_FOK;
   else if((filling & SYMBOL_FILLING_IOC) != 0) req.type_filling = ORDER_FILLING_IOC;
   else                                          req.type_filling = ORDER_FILLING_RETURN;

   bool ok = OrderSend(req, res);
   if(ok)
      PrintFormat("✅ %s | Lot:%.2f | Entry:%.5f | SL:%.5f | TP:%.5f | Risc real:$%.2f",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  lot, entry, sl, tp, real_risk * point_value * lot);
   else
      PrintFormat("❌ Eroare ordin: %d - %s", res.retcode, res.comment);

   return ok;
}

// ─────────────────────────────────────────────
// 8. BREAK-EVEN MANAGEMENT
// ─────────────────────────────────────────────
void ManageBreakEven()
{
   if(BE_Activation <= 0) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      double tp  = PositionGetDouble(POSITION_TP);
      double rsk = MathAbs(op - sl);
      if(rsk <= 0) continue;

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double ts  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double new_sl = 0;
      bool   need   = false;

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         if(bid >= op + rsk * BE_Activation && sl < op)
         { new_sl = NormalizeDouble(op + ts * 2, _Digits); need = true; }
      }
      else
      {
         if(ask <= op - rsk * BE_Activation && (sl > op || sl == 0))
         { new_sl = NormalizeDouble(op - ts * 2, _Digits); need = true; }
      }
      if(!need) continue;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action   = TRADE_ACTION_SLTP;
      req.position = ticket;
      req.symbol   = _Symbol;
      req.sl       = new_sl;
      req.tp       = NormalizeDouble(tp, _Digits);
      if(OrderSend(req, res))
         PrintFormat("🔒 BE activat #%d la %.5f", ticket, new_sl);
      else
         Print("⚠️ Eroare BE: ", res.retcode);
   }
}

// ─────────────────────────────────────────────
// 9. NUMAR POZITII DESCHISE (filtrat dupa magic)
// ─────────────────────────────────────────────
int CountMyPositions()
{
   int cnt = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         cnt++;
   }
   return cnt;
}

// ─────────────────────────────────────────────
// 10. OnTick PRINCIPAL
// ─────────────────────────────────────────────
void OnTick()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));

   // ── Reset zilnic ───────────────────────────────────────────────
   if(today != g_last_day)
   {
      g_daily_trades = 0;
      g_fib_valid    = false;
      g_entry1_taken = false;
      g_entry2_taken = false;
      g_fib_high     = 0;
      g_fib_low      = 0;
      g_fib_dir      = 0;
      g_last_day     = today;
      Print("🔄 Zi noua: ", TimeToString(today, TIME_DATE), " | Reset tranzactii & fib setup.");
   }

   // ── Verifica sesiunea activa ───────────────────────────────────
   int curTime  = dt.hour * 100 + dt.min;
   int sesStart = SessionStartHour * 100;
   int sesEnd   = SessionEndHour   * 100;
   if(curTime < sesStart || curTime >= sesEnd) return;

   // ── Limita zilnica atinsa ──────────────────────────────────────
   if(g_daily_trades >= MaxDailyTrades) return;

   // ── Break-Even management ──────────────────────────────────────
   ManageBreakEven();

   // ── Directia trendului ─────────────────────────────────────────
   int trend = GetTrendDirection();
   if(trend == 0) return; // conflict 4H vs 1H – nu tranzactionam

   // ── Cauta / actualizeaza swing fib ────────────────────────────
   double new_hi = 0, new_lo = 0;
   bool   found  = FindFibSwing(trend, new_hi, new_lo);

   if(found)
   {
      // Daca swing-ul s-a schimbat, resetam state-ul entry-urilor
      bool changed = (!g_fib_valid || g_fib_dir != trend ||
                      MathAbs(new_hi - g_fib_high) > _Point ||
                      MathAbs(new_lo - g_fib_low)  > _Point);
      if(changed)
      {
         g_fib_high     = new_hi;
         g_fib_low      = new_lo;
         g_fib_dir      = trend;
         g_fib_valid    = true;
         g_entry1_taken = false;
         g_entry2_taken = false;
         double rng_pct = (new_hi - new_lo) / new_lo * 100.0;
         PrintFormat("📐 Fib setup NOU | Dir:%s | Hi:%.5f | Lo:%.5f | Range:%.2f%% | F0.750:%.5f | F0.786:%.5f | F0.886:%.5f",
                     trend == 1 ? "BUY" : "SELL",
                     g_fib_high, g_fib_low, rng_pct,
                     FibPrice(trend, g_fib_high, g_fib_low, Fib_Entry1_Low),
                     FibPrice(trend, g_fib_high, g_fib_low, Fib_Entry1_High),
                     FibPrice(trend, g_fib_high, g_fib_low, Fib_Entry2));
      }
   }
   else if(g_fib_valid)
   {
      // Swing-ul nu mai e detectat – verifica daca pretul a invalidat setup-ul
      // (pretul a trecut dincolo de nivelul 1.0, adica dincolo de swing extreme)
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double buf = SL_Buffer_Pts * _Point;
      if(g_fib_dir == 1 && bid < g_fib_low - buf)
      { g_fib_valid = false; PrintFormat("❌ Fib BUY invalidat – pret(%.5f) sub swing lo(%.5f)", bid, g_fib_low); }
      else if(g_fib_dir == -1 && ask > g_fib_high + buf)
      { g_fib_valid = false; PrintFormat("❌ Fib SELL invalidat – pret(%.5f) peste swing hi(%.5f)", ask, g_fib_high); }
      // Altfel pastram setup-ul activ (pretul e inca in zona valida)
   }

   if(!g_fib_valid) return;

   // ── Calculeaza preturile la nivelele fibonacci ─────────────────
   //
   //  BUY (dir=1):
   //    f_750 = hi - 0.750*(hi-lo)  [mai sus pe chart]
   //    f_786 = hi - 0.786*(hi-lo)  [mai jos pe chart, limita inferioara zona entry1]
   //    f_886 = hi - 0.886*(hi-lo)  [SL entry1, entry2]
   //    f_100 = hi - 1.000*(hi-lo) = lo  [SL entry2]
   //
   //  SELL (dir=-1):
   //    f_750 = lo + 0.750*(hi-lo)  [mai jos pe chart]
   //    f_786 = lo + 0.786*(hi-lo)  [mai sus pe chart, limita superioara zona entry1]
   //    f_886 = lo + 0.886*(hi-lo)
   //    f_100 = lo + 1.000*(hi-lo) = hi
   //
   double f_750 = FibPrice(g_fib_dir, g_fib_high, g_fib_low, Fib_Entry1_Low);
   double f_786 = FibPrice(g_fib_dir, g_fib_high, g_fib_low, Fib_Entry1_High);
   double f_886 = FibPrice(g_fib_dir, g_fib_high, g_fib_low, Fib_Entry2);
   double f_100 = FibPrice(g_fib_dir, g_fib_high, g_fib_low, 1.000);
   double buf   = SL_Buffer_Pts * _Point;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ── Verificare invalidare dinamica ────────────────────────────
   if(g_fib_dir == 1 && bid < f_100 - buf)
   { g_fib_valid = false; Print("❌ Fib BUY invalidat (sub 1.0)"); return; }
   if(g_fib_dir == -1 && ask > f_100 + buf)
   { g_fib_valid = false; Print("❌ Fib SELL invalidat (peste 1.0)"); return; }

   // ═══════════════════════════════════════════════════════════════
   // ENTRY 1: zona Fib 0.750 – 0.786
   //
   //  BUY:  bid intre f_786 (mai jos) si f_750 (mai sus)
   //        → f_786 <= bid <= f_750
   //        SL: sub f_886  TP: entry + RR * (entry - SL)
   //
   //  SELL: ask intre f_750 (mai jos) si f_786 (mai sus)
   //        → f_750 <= ask <= f_786
   //        SL: peste f_886  TP: entry - RR * (SL - entry)
   // ═══════════════════════════════════════════════════════════════
   if(!g_entry1_taken && g_daily_trades < MaxDailyTrades)
   {
      if(g_fib_dir == 1 && bid <= f_750 && bid >= f_786)
      {
         double entry     = ask;
         double sl        = f_886 - buf;
         double real_risk = MathAbs(entry - sl);
         double tp        = entry + real_risk * RRRatio;
         if(real_risk > 0 && tp > entry && sl < entry)
         {
            PrintFormat("🎯 Entry 1 BUY | Zona:%.5f–%.5f | Entry:%.5f | SL:%.5f | TP:%.5f | Risc:%.1f pts",
                        f_786, f_750, entry, sl, tp, real_risk / _Point);
            g_entry1_taken = true;
            if(SendOrder(ORDER_TYPE_BUY, entry, sl, tp))
               g_daily_trades++;
            else
               g_entry1_taken = false;
         }
         else
            PrintFormat("⚠️ Entry 1 BUY: SL/TP invalide. Entry=%.5f SL=%.5f TP=%.5f", entry, sl, tp);
      }
      else if(g_fib_dir == -1 && ask >= f_750 && ask <= f_786)
      {
         double entry     = bid;
         double sl        = f_886 + buf;
         double real_risk = MathAbs(sl - entry);
         double tp        = entry - real_risk * RRRatio;
         if(real_risk > 0 && tp < entry && sl > entry)
         {
            PrintFormat("🎯 Entry 1 SELL | Zona:%.5f–%.5f | Entry:%.5f | SL:%.5f | TP:%.5f | Risc:%.1f pts",
                        f_750, f_786, entry, sl, tp, real_risk / _Point);
            g_entry1_taken = true;
            if(SendOrder(ORDER_TYPE_SELL, entry, sl, tp))
               g_daily_trades++;
            else
               g_entry1_taken = false;
         }
         else
            PrintFormat("⚠️ Entry 1 SELL: SL/TP invalide. Entry=%.5f SL=%.5f TP=%.5f", entry, sl, tp);
      }
   }

   // ═══════════════════════════════════════════════════════════════
   // ENTRY 2: nivel Fib 0.886
   //
   //  BUY:  bid atinge sau coboara sub f_886
   //        SL: sub f_100 (swing low) – buf   TP: entry + RR * (entry - SL)
   //
   //  SELL: ask atinge sau urca peste f_886
   //        SL: peste f_100 (swing high) + buf  TP: entry - RR * (SL - entry)
   // ═══════════════════════════════════════════════════════════════
   if(!g_entry2_taken && g_daily_trades < MaxDailyTrades)
   {
      if(g_fib_dir == 1 && bid <= f_886)
      {
         double entry     = ask;
         double sl        = f_100 - buf;
         double real_risk = MathAbs(entry - sl);
         double tp        = entry + real_risk * RRRatio;
         if(real_risk > 0 && tp > entry && sl < entry)
         {
            PrintFormat("🎯 Entry 2 BUY | Nivel:%.5f(0.886) | Entry:%.5f | SL:%.5f(swing lo=%.5f) | TP:%.5f | Risc:%.1f pts",
                        f_886, entry, sl, f_100, tp, real_risk / _Point);
            g_entry2_taken = true;
            if(SendOrder(ORDER_TYPE_BUY, entry, sl, tp))
               g_daily_trades++;
            else
               g_entry2_taken = false;
         }
         else
            PrintFormat("⚠️ Entry 2 BUY: SL/TP invalide. Entry=%.5f SL=%.5f TP=%.5f", entry, sl, tp);
      }
      else if(g_fib_dir == -1 && ask >= f_886)
      {
         double entry     = bid;
         double sl        = f_100 + buf;
         double real_risk = MathAbs(sl - entry);
         double tp        = entry - real_risk * RRRatio;
         if(real_risk > 0 && tp < entry && sl > entry)
         {
            PrintFormat("🎯 Entry 2 SELL | Nivel:%.5f(0.886) | Entry:%.5f | SL:%.5f(swing hi=%.5f) | TP:%.5f | Risc:%.1f pts",
                        f_886, entry, sl, f_100, tp, real_risk / _Point);
            g_entry2_taken = true;
            if(SendOrder(ORDER_TYPE_SELL, entry, sl, tp))
               g_daily_trades++;
            else
               g_entry2_taken = false;
         }
         else
            PrintFormat("⚠️ Entry 2 SELL: SL/TP invalide. Entry=%.5f SL=%.5f TP=%.5f", entry, sl, tp);
      }
   }
}
//+------------------------------------------------------------------+
