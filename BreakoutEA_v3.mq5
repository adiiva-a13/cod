//+------------------------------------------------------------------+
//|  BreakoutEA_v3.mq5                                               |
//|  Versiune v3 - Entry la RETEST, SL bazat pe POC,                |
//|  Circuit Breaker auto-reset, fix reset range zilnic,            |
//|  DST auto-detect, fus orar configurabil                         |
//+------------------------------------------------------------------+
#property strict
#property description "Breakout EA cu VWAP saptamanal - Versiune v3"
// ─────────────────────────────────────────────
// 1. PARAMETRI DE INTRARE
// ─────────────────────────────────────────────
input group "=== RISK MANAGEMENT ==="
input double RiskMoney      = 350.0;   // Risc per tranzactie ($)
input double RRRatio        = 2.0;     // Raport Risc/Recompensa real
input double MaxLotLimit    = 10.0;    // Lot maxim
input double BE_Activation  = 1.2;     // Activare Break-Even (x risc)
input group "=== FILTRU RANGE ==="
input double MinPoints      = 1000.0;  // Range minim (puncte _Point) - DAX: 10pts×100
input double MaxPoints      = 8000.0;  // Range maxim (puncte _Point) - DAX: 80pts×100
input group "=== TIMP (ORA SERVER METATRADER) ==="
input int    RangeStartHour = 10;      // Ora start colectare range (ORA SERVER MT5)
input int    RangeStartMin  = 0;       // Minut start
input int    RangeEndHour   = 10;      // Ora final colectare range (ORA SERVER MT5)
input int    RangeEndMin    = 15;      // Minut final
input int    EntryEndHour   = 12;      // Ora limita intrare noi pozitii (ORA SERVER MT5)
input int    ExitHour       = 14;      // Ora inchidere fortata (ORA SERVER MT5)
input int    ExitMin        = 0;
input group "=== SESIUNEA 2 (optional) ==="
input bool   EnableSession2 = false;   // Activa a doua sesiune de tranzactionare
input int    R2StartHour    = 16;      // Ora start range sesiunea 2 (ORA SERVER MT5)
input int    R2StartMin     = 30;      // Minut start range sesiunea 2
input int    R2EndHour      = 16;      // Ora final range sesiunea 2 (ORA SERVER MT5)
input int    R2EndMin       = 45;      // Minut final range sesiunea 2
input int    Entry2EndHour  = 18;      // Ora limita intrare sesiunea 2 (ORA SERVER MT5)
input group "=== FUS ORAR ==="
input int    ServerOffsetWinter = 0;   // Offset 0 = orele de mai sus sunt direct ora server
input int    ServerOffsetSummer = 0;   // Offset 0 = orele de mai sus sunt direct ora server
// ─── Ghid configurare ───────────────────────────────────────────────
// Orele introduse mai sus sunt ORA SERVER din Market Watch (MT5).
// Offsetul este 0 deoarece nu mai facem conversie locala->server.
// Daca vrei sa revii la ore locale, seteaza offsetul corespunzator brokerului.
// ────────────────────────────────────────────────────────────────────
input group "=== ZILE ACTIVE ==="
input bool Mon = true;
input bool Tue = true;
input bool Wed = true;
input bool Thu = true;
input bool Fri = true;
input group "=== CIRCUIT BREAKER ==="
input int    MaxConsecLosses = 3;      // Pierderi consecutive inainte de oprire
input int    CB_PauseDays    = 2;      // Zile pauza automata dupa activare
input int    LookbackDays    = 7;      // Zile lookback pentru circuit breaker
input group "=== SESSION VOLUME PROFILE (SVP) ==="
input double ValueAreaPct   = 70.0;   // Value Area (% din volum total)
input double SL_Buffer_Pts  = 10.0;   // Buffer SL in puncte (dupa VAL/VAH/LL/LH)
input group "=== CONFIRMARE BREAKOUT ==="
input int    ConfirmBars    = 2;       // Bare M1 consecutive de confirmare
input group "=== SETARI AVANSATE ==="
input int    MagicNumber    = 9999;    // Magic number unic
input int    Slippage       = 10;      // Slippage maxim (puncte)
input bool   UseVWAP        = false;   // Filtru Weekly VWAP activ
// ─────────────────────────────────────────────
// 2. VARIABILE GLOBALE
// ─────────────────────────────────────────────
double   g_hi           = 0;
double   g_lo           = 0;
bool     g_range_set    = false;
datetime g_last_trade   = 0;
bool     g_traded_today = false;
datetime g_last_bar     = 0;
double   g_vwap         = 0;
string   VWAP_OBJ       = "WeeklyVWAP_Line";
// SVP (Session Volume Profile)
double   g_vah          = 0;
double   g_val          = 0;
double   g_poc          = 0;
bool     g_svp_set      = false;
// Directia setup: 1=BUY, -1=SELL, 0=normal range (din breakout)
int      g_setup_dir    = 0;
// Regim volatilitate: true = VAL+POC+VAH in aceeasi jumatate (SL via POC)
//                     false = normal range (SL via VAH/VAL)
bool     g_high_vol     = false;
// State machine breakout: 1=spart sus (g_hi), -1=spart jos (g_lo), 0=niciuna
int      g_breakout_dir = 0;
// ─────────────────────────────────────────────
// 2b. VARIABILE SESIUNEA 2
// ─────────────────────────────────────────────
double   g_hi2           = 0;
double   g_lo2           = 0;
bool     g_range_set2    = false;
bool     g_traded_s2     = false;
double   g_vah2          = 0;
double   g_val2          = 0;
double   g_poc2          = 0;
bool     g_svp_set2      = false;
int      g_setup_dir2    = 0;
bool     g_high_vol2     = false;
int      g_breakout_dir2 = 0;
// ─────────────────────────────────────────────
// 3. FUNCTII FUS ORAR SI DST
// ─────────────────────────────────────────────
// Returneaza ziua (1-31) a ultimei duminici dintr-o luna
// Functia este valabila doar pentru Martie (31 zile) si Octombrie (31 zile)
int LastSundayOfMonth(int year, int month)
{
   // Ziua de saptamana a lui 1 a lunii (0=Duminica)
   datetime d = StringToTime(StringFormat("%04d.%02d.01 00:00", year, month));
   MqlDateTime dt;
   TimeToStruct(d, dt);
   int firstDow  = dt.day_of_week;
   int daysInMon = 31; // Martie si Octombrie au ambele 31 de zile
   int lastDow   = (firstDow + daysInMon - 1) % 7;
   // Ultima duminica = ultima zi - cate zile e dupa duminica
   return daysInMon - lastDow;
}
// Detecteaza ora de vara europeana (EU DST):
// Incepe:  ultima duminica din Martie   la 02:00
// Se incheie: ultima duminica din Octombrie la 03:00
// Functia primeste ora SERVER (TimeCurrent)
bool IsEuropeanDST(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int y = dt.year;
   int m = dt.mon;
   int d = dt.day;
   int h = dt.hour;
   if(m < 3 || m > 10) return false;  // Ian, Feb, Nov, Dec = IARNA
   if(m > 3 && m < 10) return true;   // Apr-Sep = VARA
   int lastSun = LastSundayOfMonth(y, m);
   if(m == 3)  // Martie: DST porneste la ora 02:00
   {
      if(d < lastSun) return false;
      if(d > lastSun) return true;
      return (h >= 2);
   }
   else        // Octombrie: DST se termina la ora 03:00
   {
      if(d < lastSun) return true;
      if(d > lastSun) return false;
      return (h < 3);
   }
}
// Converteste ora locala -> ora server (tine cont de DST)
int ToServerHour(int localHour)
{
   int offset = IsEuropeanDST(TimeCurrent()) ? ServerOffsetSummer : ServerOffsetWinter;
   return (localHour + offset + 24) % 24;
}
// ─────────────────────────────────────────────
// 4. CIRCUIT BREAKER - cu magic number filter
// ─────────────────────────────────────────────
datetime g_halted_since = 0;
bool IsSystemHalted()
{
   if(g_halted_since > 0)
   {
      if(TimeCurrent() >= g_halted_since + CB_PauseDays * 86400)
      {
         Print("✅ Circuit Breaker resetat automat dupa ", CB_PauseDays, " zile. Reluam tranzactionarea.");
         g_halted_since = 0;
         return false;
      }
      static datetime last_cb_log = 0;
      if(TimeCurrent() - last_cb_log >= 86400)
      {
         int zile_ramase = (int)MathCeil((double)(g_halted_since + CB_PauseDays * 86400 - TimeCurrent()) / 86400.0);
         PrintFormat("⛔ Circuit Breaker activ | Pauza: %d zile ramase | Reset la: %s",
                     zile_ramase,
                     TimeToString(g_halted_since + CB_PauseDays * 86400, TIME_DATE));
         last_cb_log = TimeCurrent();
      }
      return true;
   }
   if(!HistorySelect(TimeCurrent() - LookbackDays * 86400, TimeCurrent()))
      return false;
   int losses = 0;
   int total  = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      if(profit < 0)
      {
         losses++;
         if(losses >= MaxConsecLosses)
         {
            g_halted_since = TimeCurrent();
            PrintFormat("⛔ Circuit Breaker activat: %d pierderi consecutive. Pauza %d zile pana la %s",
                        losses, CB_PauseDays,
                        TimeToString(g_halted_since + CB_PauseDays * 86400, TIME_DATE));
            return true;
         }
      }
      else if(profit > 0)
         break;
   }
   return false;
}
// ─────────────────────────────────────────────
// 5. CALCUL VWAP SAPTAMANAL (o data pe bara)
// ─────────────────────────────────────────────
double CalcWeeklyVWAP()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int dow = (dt.day_of_week == 0) ? 7 : dt.day_of_week;
   datetime week_start = StringToTime(TimeToString(TimeCurrent() - (dow - 1) * 86400, TIME_DATE));
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, _Period, week_start, TimeCurrent(), rates);
   if(copied <= 0) return 0;
   double sumPV = 0, sumV = 0;
   for(int i = 0; i < copied; i++)
   {
      double v  = (rates[i].tick_volume > 0) ? (double)rates[i].tick_volume : 1.0;
      double tp = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      sumPV += tp * v;
      sumV  += v;
   }
   double vwap_val = (sumV > 0) ? (sumPV / sumV) : 0;
   if(ObjectFind(0, VWAP_OBJ) < 0)
      ObjectCreate(0, VWAP_OBJ, OBJ_HLINE, 0, 0, vwap_val);
   else
      ObjectSetDouble(0, VWAP_OBJ, OBJPROP_PRICE, vwap_val);
   ObjectSetInteger(0, VWAP_OBJ, OBJPROP_COLOR,  clrCyan);
   ObjectSetInteger(0, VWAP_OBJ, OBJPROP_STYLE,  STYLE_DASH);
   ObjectSetInteger(0, VWAP_OBJ, OBJPROP_WIDTH,  1);
   ObjectSetString(0,  VWAP_OBJ, OBJPROP_TOOLTIP, "Weekly VWAP: " + DoubleToString(vwap_val, _Digits));
   return vwap_val;
}
// ─────────────────────────────────────────────
// 6. CALCUL SVP (Session Volume Profile 10:00-10:15)
// ─────────────────────────────────────────────
void CalcSVP()
{
   if(g_svp_set) return;
   int srv_start_h = ToServerHour(RangeStartHour);
   int srv_end_h   = ToServerHour(RangeEndHour);
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today        = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   datetime range_start  = today + srv_start_h * 3600 + RangeStartMin * 60;
   // -1 secunda pentru a evita bara deschisa exact la limita ferestrei
   datetime range_end_dt = today + srv_end_h   * 3600 + RangeEndMin   * 60 - 1;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int copied = CopyRates(_Symbol, PERIOD_M1, range_start, range_end_dt, r);
   if(copied <= 0)
   {
      Print("⚠️ SVP: bare M1 inca indisponibile, retentativa la tick urmator.");
      return;
   }
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0) return;
   // Gaseste extremele range-ului SVP
   double hi = r[0].high, lo = r[0].low;
   for(int i = 1; i < copied; i++)
   {
      if(r[i].high > hi) hi = r[i].high;
      if(r[i].low  < lo) lo = r[i].low;
   }
   int levels = (int)MathRound((hi - lo) / tick_size) + 1;
   if(levels <= 0 || levels > 50000) { Print("⚠️ SVP: prea multe nivele (", levels, "), skip."); return; }
   double vol_at[];
   ArrayResize(vol_at, levels);
   ArrayInitialize(vol_at, 0);
   double total_vol = 0;
   for(int i = 0; i < copied; i++)
   {
      int lo_idx = (int)MathRound((r[i].low  - lo) / tick_size);
      int hi_idx = (int)MathRound((r[i].high - lo) / tick_size);
      if(hi_idx >= levels) hi_idx = levels - 1;
      int span   = hi_idx - lo_idx + 1;
      if(span < 1) span = 1;
      double vol_per = (double)r[i].tick_volume / span;
      for(int j = lo_idx; j <= hi_idx; j++)
      {
         vol_at[j] += vol_per;
         total_vol  += vol_per;
      }
   }
   // POC = nivelul cu cel mai mare volum
   int poc_idx = 0;
   for(int i = 1; i < levels; i++)
      if(vol_at[i] > vol_at[poc_idx]) poc_idx = i;
   g_poc = lo + poc_idx * tick_size;
   // Expandeaza de la POC pana la ValueAreaPct% din volum total
   double target   = total_vol * ValueAreaPct / 100.0;
   double accum    = vol_at[poc_idx];
   int    vah_idx  = poc_idx;
   int    val_idx  = poc_idx;
   while(accum < target)
   {
      double next_up   = (vah_idx + 1 < levels) ? vol_at[vah_idx + 1] : 0;
      double next_down = (val_idx  - 1 >= 0)    ? vol_at[val_idx  - 1] : 0;
      if(next_up == 0 && next_down == 0) break;
      if(next_up >= next_down && vah_idx + 1 < levels)
         { vah_idx++; accum += vol_at[vah_idx]; }
      else if(val_idx - 1 >= 0)
         { val_idx--;  accum += vol_at[val_idx];  }
      else
         { vah_idx++; accum += vol_at[vah_idx]; }
   }
   g_vah     = NormalizeDouble(lo + vah_idx * tick_size, _Digits);
   g_val     = NormalizeDouble(lo + val_idx  * tick_size, _Digits);
   g_svp_set = true;
   PrintFormat("📊 SVP | POC: %.5f | VAH: %.5f | VAL: %.5f | Bare: %d | Vol total: %.0f",
               g_poc, g_vah, g_val, copied, total_vol);
   // ── Detecta regimul de volatilitate si directia setup ──
   // HIGH VOL: VAL + POC + VAH toate in aceeasi jumatate → SL via POC
   // NORMAL:   NU sunt toate in aceeasi jumatate → SL via VAH/VAL, directia din breakout
   double range_mid = (g_hi + g_lo) / 2.0;
   bool poc_up = (g_poc > range_mid);
   bool val_up = (g_val > range_mid);
   bool vah_up = (g_vah > range_mid);
   if(val_up && vah_up && poc_up)
   {
      g_high_vol  = true;
      g_setup_dir = -1; // SELL: asteptam spargere sus + retest g_hi → short
      PrintFormat("🔥 HIGH VOL SELL | VAL+POC+VAH in jumatatea SUPERIOARA | VAL=%.5f POC=%.5f VAH=%.5f | Retest g_hi=%.5f | SL via POC",
                  g_val, g_poc, g_vah, g_hi);
   }
   else if(!val_up && !vah_up && !poc_up)
   {
      g_high_vol  = true;
      g_setup_dir = 1; // BUY: asteptam spargere jos + retest g_lo → long
      PrintFormat("🔥 HIGH VOL BUY  | VAL+POC+VAH in jumatatea INFERIOARA | VAL=%.5f POC=%.5f VAH=%.5f | Retest g_lo=%.5f | SL via POC",
                  g_val, g_poc, g_vah, g_lo);
   }
   else
   {
      g_high_vol  = false;
      g_setup_dir = 0; // directia se determina la momentul breakout-ului
      PrintFormat("📍 NORMAL RANGE | VA traverseaza mijlocul | VAL=%.5f POC=%.5f VAH=%.5f Mid=%.5f | SL via VAH/VAL | Astept breakout",
                  g_val, g_poc, g_vah, range_mid);
   }
}
// ─────────────────────────────────────────────
// 7. SL BAZAT PE POC (retest entry)
//    SELL: SL peste ultimul swing high de dupa range care depaseste POC, altfel peste POC
//    BUY:  SL sub ultimul swing low de dupa range care e sub POC, altfel sub POC
// ─────────────────────────────────────────────
double GetRetestSL_Long()
{
   int srv_end_h = ToServerHour(RangeEndHour);
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today        = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   datetime range_end_dt = today + srv_end_h * 3600 + RangeEndMin * 60;
   MqlRates r[];
   ArraySetAsSeries(r, false); // r[0]=cel mai vechi, r[copied-1]=cel mai nou
   int copied = CopyRates(_Symbol, PERIOD_M1, range_end_dt, TimeCurrent(), r);
   double buf = MathMax(SL_Buffer_Pts, 20.0) * _Point;
   // Cauta ultimul (cel mai recent) swing low sub POC
   // Swing low la bara i: low[i] < low[i-1] && low[i] < low[i+1]
   double last_swing_low = -DBL_MAX;
   bool   found          = false;
   for(int i = copied - 2; i >= 1; i--)
   {
      if(r[i].low < r[i-1].low && r[i].low < r[i+1].low && r[i].low < g_poc)
      {
         last_swing_low = r[i].low;
         found = true;
         break; // cel mai recent → oprim
      }
   }
   double sl_ref = found ? last_swing_low : g_poc;
   double sl     = sl_ref - buf;
   if(found)
      PrintFormat("📍 BUY SL: ultimul swing low=%.5f (< POC=%.5f) → SL=%.5f (buf=%.1f pts)", last_swing_low, g_poc, sl, buf / _Point);
   else
      PrintFormat("📍 BUY SL: POC=%.5f (niciun swing low sub POC) → SL=%.5f (buf=%.1f pts)", g_poc, sl, buf / _Point);
   return NormalizeDouble(sl, _Digits);
}
double GetRetestSL_Short()
{
   int srv_end_h = ToServerHour(RangeEndHour);
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today        = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   datetime range_end_dt = today + srv_end_h * 3600 + RangeEndMin * 60;
   MqlRates r[];
   ArraySetAsSeries(r, false); // r[0]=cel mai vechi, r[copied-1]=cel mai nou
   int copied = CopyRates(_Symbol, PERIOD_M1, range_end_dt, TimeCurrent(), r);
   double buf = MathMax(SL_Buffer_Pts, 20.0) * _Point;
   // Cauta ultimul (cel mai recent) swing high peste POC
   // Swing high la bara i: high[i] > high[i-1] && high[i] > high[i+1]
   double last_swing_high = DBL_MAX;
   bool   found           = false;
   for(int i = copied - 2; i >= 1; i--)
   {
      if(r[i].high > r[i-1].high && r[i].high > r[i+1].high && r[i].high > g_poc)
      {
         last_swing_high = r[i].high;
         found = true;
         break; // cel mai recent → oprim
      }
   }
   double sl_ref = found ? last_swing_high : g_poc;
   double sl     = sl_ref + buf;
   if(found)
      PrintFormat("📍 SELL SL: ultimul swing high=%.5f (> POC=%.5f) → SL=%.5f (buf=%.1f pts)", last_swing_high, g_poc, sl, buf / _Point);
   else
      PrintFormat("📍 SELL SL: POC=%.5f (niciun swing high peste POC) → SL=%.5f (buf=%.1f pts)", g_poc, sl, buf / _Point);
   return NormalizeDouble(sl, _Digits);
}
// ─────────────────────────────────────────────
// 8. SL NORMAL RANGE (bazat pe VAH/VAL)
//    BUY (breakout sus + retest g_hi): SL sub VAL sau sub cel mai recent low < VAL
//    SELL (breakout jos + retest g_lo): SL peste VAH sau peste cel mai recent high > VAH
// ─────────────────────────────────────────────
double GetNormalSL_Long()
{
   int srv_end_h = ToServerHour(RangeEndHour);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime range_end_dt = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d",
                            dt.year, dt.mon, dt.day, srv_end_h, RangeEndMin));
   int start_shift = iBarShift(_Symbol, PERIOD_M1, range_end_dt, false);
   if(start_shift < 2) start_shift = 50;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int count = MathMin(start_shift + 1, 200);
   double buf = MathMax(SL_Buffer_Pts, 20.0) * _Point;
   if(CopyRates(_Symbol, PERIOD_M1, 1, count, r) < 3)
      return NormalizeDouble(g_val - buf, _Digits);
   double last_swing_low = 0;
   bool   found = false;
   for(int i = 1; i < (int)ArraySize(r) - 1; i++)
   {
      if(r[i].low < r[i-1].low && r[i].low < r[i+1].low && r[i].low < g_val)
      { last_swing_low = r[i].low; found = true; break; }
   }
   double sl_ref = found ? last_swing_low : g_val;
   double sl     = sl_ref - buf;
   if(found)
      PrintFormat("📍 BUY(Normal) SL: swing low=%.5f (< VAL=%.5f) → SL=%.5f (buf=%.1f pts)", last_swing_low, g_val, sl, buf/_Point);
   else
      PrintFormat("📍 BUY(Normal) SL: VAL=%.5f (niciun swing sub VAL) → SL=%.5f (buf=%.1f pts)", g_val, sl, buf/_Point);
   return NormalizeDouble(sl, _Digits);
}
double GetNormalSL_Short()
{
   int srv_end_h = ToServerHour(RangeEndHour);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime range_end_dt = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d",
                            dt.year, dt.mon, dt.day, srv_end_h, RangeEndMin));
   int start_shift = iBarShift(_Symbol, PERIOD_M1, range_end_dt, false);
   if(start_shift < 2) start_shift = 50;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int count = MathMin(start_shift + 1, 200);
   double buf = MathMax(SL_Buffer_Pts, 20.0) * _Point;
   if(CopyRates(_Symbol, PERIOD_M1, 1, count, r) < 3)
      return NormalizeDouble(g_vah + buf, _Digits);
   double last_swing_high = 0;
   bool   found = false;
   for(int i = 1; i < (int)ArraySize(r) - 1; i++)
   {
      if(r[i].high > r[i-1].high && r[i].high > r[i+1].high && r[i].high > g_vah)
      { last_swing_high = r[i].high; found = true; break; }
   }
   double sl_ref = found ? last_swing_high : g_vah;
   double sl     = sl_ref + buf;
   if(found)
      PrintFormat("📍 SELL(Normal) SL: swing high=%.5f (> VAH=%.5f) → SL=%.5f (buf=%.1f pts)", last_swing_high, g_vah, sl, buf/_Point);
   else
      PrintFormat("📍 SELL(Normal) SL: VAH=%.5f (niciun swing peste VAH) → SL=%.5f (buf=%.1f pts)", g_vah, sl, buf/_Point);
   return NormalizeDouble(sl, _Digits);
}
// ─────────────────────────────────────────────
// 9. COLECTARE RANGE - finalizata DUPA inchiderea ferestrei (10:15 server)
// ─────────────────────────────────────────────
void CollectRange()
{
   if(g_range_set) return;

   int srv_start_h    = ToServerHour(RangeStartHour);
   int srv_end_h      = ToServerHour(RangeEndHour);
   int range_end_time = srv_end_h * 100 + RangeEndMin;

   MqlDateTime dt;
   TimeCurrent(dt);
   int curTime = dt.hour * 100 + dt.min;

   // Colecteaza range-ul DOAR dupa ce fereastra s-a inchis complet
   if(curTime < range_end_time) return;

   datetime today        = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   datetime range_start  = today + srv_start_h * 3600 + RangeStartMin * 60;
   // -1 secunda pentru a evita bara deschisa exact la limita ferestrei
   datetime range_end_dt = today + srv_end_h   * 3600 + RangeEndMin   * 60 - 1;

   MqlRates r[];
   ArraySetAsSeries(r, false);
   int copied = CopyRates(_Symbol, PERIOD_M1, range_start, range_end_dt, r);
   if(copied <= 0)
   {
      Print("⚠️ Range: bare M1 inca indisponibile, retentativa la tick urmator.");
      return;
   }

   g_hi = r[0].high;
   g_lo = r[0].low;
   for(int i = 1; i < copied; i++)
   {
      if(r[i].high > g_hi) g_hi = r[i].high;
      if(r[i].low  < g_lo) g_lo = r[i].low;
   }
   g_range_set = true;
   PrintFormat("📐 Range finalizat: Hi=%.5f Lo=%.5f | Range=%.1f puncte | Bare: %d",
               g_hi, g_lo, (g_hi - g_lo) / _Point, copied);
}
// ─────────────────────────────────────────────
// 8b. SL SESIUNEA 2 (foloseste g_poc2 / g_vah2 / g_val2 si R2End*)
// ─────────────────────────────────────────────
double GetRetestSL_Long2()
{
   int srv_end_h = ToServerHour(R2EndHour);
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today        = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   datetime range_end_dt = today + srv_end_h * 3600 + R2EndMin * 60;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int copied = CopyRates(_Symbol, PERIOD_M1, range_end_dt, TimeCurrent(), r);
   double buf = MathMax(SL_Buffer_Pts, 20.0) * _Point;
   double last_swing_low = -DBL_MAX;
   bool   found          = false;
   for(int i = copied - 2; i >= 1; i--)
   {
      if(r[i].low < r[i-1].low && r[i].low < r[i+1].low && r[i].low < g_poc2)
      { last_swing_low = r[i].low; found = true; break; }
   }
   double sl_ref = found ? last_swing_low : g_poc2;
   double sl     = sl_ref - buf;
   if(found)
      PrintFormat("📍 [S2] BUY SL: swing low=%.5f (< POC=%.5f) → SL=%.5f (buf=%.1f pts)", last_swing_low, g_poc2, sl, buf/_Point);
   else
      PrintFormat("📍 [S2] BUY SL: POC=%.5f (niciun swing low sub POC) → SL=%.5f (buf=%.1f pts)", g_poc2, sl, buf/_Point);
   return NormalizeDouble(sl, _Digits);
}
double GetRetestSL_Short2()
{
   int srv_end_h = ToServerHour(R2EndHour);
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today        = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   datetime range_end_dt = today + srv_end_h * 3600 + R2EndMin * 60;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int copied = CopyRates(_Symbol, PERIOD_M1, range_end_dt, TimeCurrent(), r);
   double buf = MathMax(SL_Buffer_Pts, 20.0) * _Point;
   double last_swing_high = DBL_MAX;
   bool   found           = false;
   for(int i = copied - 2; i >= 1; i--)
   {
      if(r[i].high > r[i-1].high && r[i].high > r[i+1].high && r[i].high > g_poc2)
      { last_swing_high = r[i].high; found = true; break; }
   }
   double sl_ref = found ? last_swing_high : g_poc2;
   double sl     = sl_ref + buf;
   if(found)
      PrintFormat("📍 [S2] SELL SL: swing high=%.5f (> POC=%.5f) → SL=%.5f (buf=%.1f pts)", last_swing_high, g_poc2, sl, buf/_Point);
   else
      PrintFormat("📍 [S2] SELL SL: POC=%.5f (niciun swing high peste POC) → SL=%.5f (buf=%.1f pts)", g_poc2, sl, buf/_Point);
   return NormalizeDouble(sl, _Digits);
}
double GetNormalSL_Long2()
{
   int srv_end_h = ToServerHour(R2EndHour);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime range_end_dt = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d",
                            dt.year, dt.mon, dt.day, srv_end_h, R2EndMin));
   int start_shift = iBarShift(_Symbol, PERIOD_M1, range_end_dt, false);
   if(start_shift < 2) start_shift = 50;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int count = MathMin(start_shift + 1, 200);
   double buf = MathMax(SL_Buffer_Pts, 20.0) * _Point;
   if(CopyRates(_Symbol, PERIOD_M1, 1, count, r) < 3)
      return NormalizeDouble(g_val2 - buf, _Digits);
   double last_swing_low = 0;
   bool   found = false;
   for(int i = 1; i < (int)ArraySize(r) - 1; i++)
   {
      if(r[i].low < r[i-1].low && r[i].low < r[i+1].low && r[i].low < g_val2)
      { last_swing_low = r[i].low; found = true; break; }
   }
   double sl_ref = found ? last_swing_low : g_val2;
   double sl     = sl_ref - buf;
   if(found)
      PrintFormat("📍 [S2] BUY(Normal) SL: swing low=%.5f (< VAL=%.5f) → SL=%.5f (buf=%.1f pts)", last_swing_low, g_val2, sl, buf/_Point);
   else
      PrintFormat("📍 [S2] BUY(Normal) SL: VAL=%.5f (niciun swing sub VAL) → SL=%.5f (buf=%.1f pts)", g_val2, sl, buf/_Point);
   return NormalizeDouble(sl, _Digits);
}
double GetNormalSL_Short2()
{
   int srv_end_h = ToServerHour(R2EndHour);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime range_end_dt = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d",
                            dt.year, dt.mon, dt.day, srv_end_h, R2EndMin));
   int start_shift = iBarShift(_Symbol, PERIOD_M1, range_end_dt, false);
   if(start_shift < 2) start_shift = 50;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int count = MathMin(start_shift + 1, 200);
   double buf = MathMax(SL_Buffer_Pts, 20.0) * _Point;
   if(CopyRates(_Symbol, PERIOD_M1, 1, count, r) < 3)
      return NormalizeDouble(g_vah2 + buf, _Digits);
   double last_swing_high = 0;
   bool   found = false;
   for(int i = 1; i < (int)ArraySize(r) - 1; i++)
   {
      if(r[i].high > r[i-1].high && r[i].high > r[i+1].high && r[i].high > g_vah2)
      { last_swing_high = r[i].high; found = true; break; }
   }
   double sl_ref = found ? last_swing_high : g_vah2;
   double sl     = sl_ref + buf;
   if(found)
      PrintFormat("📍 [S2] SELL(Normal) SL: swing high=%.5f (> VAH=%.5f) → SL=%.5f (buf=%.1f pts)", last_swing_high, g_vah2, sl, buf/_Point);
   else
      PrintFormat("📍 [S2] SELL(Normal) SL: VAH=%.5f (niciun swing peste VAH) → SL=%.5f (buf=%.1f pts)", g_vah2, sl, buf/_Point);
   return NormalizeDouble(sl, _Digits);
}
// ─────────────────────────────────────────────
// 9b. COLECTARE RANGE + SVP SESIUNEA 2
// ─────────────────────────────────────────────
void CollectRange2()
{
   if(g_range_set2) return;

   int srv_start_h    = ToServerHour(R2StartHour);
   int srv_end_h      = ToServerHour(R2EndHour);
   int range_end_time = srv_end_h * 100 + R2EndMin;

   MqlDateTime dt;
   TimeCurrent(dt);
   int curTime = dt.hour * 100 + dt.min;

   if(curTime < range_end_time) return;

   datetime today        = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   datetime range_start  = today + srv_start_h * 3600 + R2StartMin * 60;
   datetime range_end_dt = today + srv_end_h   * 3600 + R2EndMin   * 60 - 1;

   MqlRates r[];
   ArraySetAsSeries(r, false);
   int copied = CopyRates(_Symbol, PERIOD_M1, range_start, range_end_dt, r);
   if(copied <= 0)
   {
      Print("⚠️ [S2] Range: bare M1 inca indisponibile, retentativa la tick urmator.");
      return;
   }

   g_hi2 = r[0].high;
   g_lo2 = r[0].low;
   for(int i = 1; i < copied; i++)
   {
      if(r[i].high > g_hi2) g_hi2 = r[i].high;
      if(r[i].low  < g_lo2) g_lo2 = r[i].low;
   }
   g_range_set2 = true;
   PrintFormat("📐 [S2] Range finalizat: Hi=%.5f Lo=%.5f | Range=%.1f puncte | Bare: %d",
               g_hi2, g_lo2, (g_hi2 - g_lo2) / _Point, copied);
}

void CalcSVP2()
{
   if(g_svp_set2) return;
   int srv_start_h = ToServerHour(R2StartHour);
   int srv_end_h   = ToServerHour(R2EndHour);
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today        = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   datetime range_start  = today + srv_start_h * 3600 + R2StartMin * 60;
   datetime range_end_dt = today + srv_end_h   * 3600 + R2EndMin   * 60 - 1;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int copied = CopyRates(_Symbol, PERIOD_M1, range_start, range_end_dt, r);
   if(copied <= 0)
   {
      Print("⚠️ [S2] SVP: bare M1 inca indisponibile, retentativa la tick urmator.");
      return;
   }
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0) return;
   double hi = r[0].high, lo = r[0].low;
   for(int i = 1; i < copied; i++)
   {
      if(r[i].high > hi) hi = r[i].high;
      if(r[i].low  < lo) lo = r[i].low;
   }
   int levels = (int)MathRound((hi - lo) / tick_size) + 1;
   if(levels <= 0 || levels > 50000) { Print("⚠️ [S2] SVP: prea multe nivele (", levels, "), skip."); return; }
   double vol_at[];
   ArrayResize(vol_at, levels);
   ArrayInitialize(vol_at, 0);
   double total_vol = 0;
   for(int i = 0; i < copied; i++)
   {
      int lo_idx = (int)MathRound((r[i].low  - lo) / tick_size);
      int hi_idx = (int)MathRound((r[i].high - lo) / tick_size);
      if(hi_idx >= levels) hi_idx = levels - 1;
      int span   = hi_idx - lo_idx + 1;
      if(span < 1) span = 1;
      double vol_per = (double)r[i].tick_volume / span;
      for(int j = lo_idx; j <= hi_idx; j++)
      {
         vol_at[j] += vol_per;
         total_vol  += vol_per;
      }
   }
   int poc_idx = 0;
   for(int i = 1; i < levels; i++)
      if(vol_at[i] > vol_at[poc_idx]) poc_idx = i;
   g_poc2 = lo + poc_idx * tick_size;
   double target   = total_vol * ValueAreaPct / 100.0;
   double accum    = vol_at[poc_idx];
   int    vah_idx  = poc_idx;
   int    val_idx  = poc_idx;
   while(accum < target)
   {
      double next_up   = (vah_idx + 1 < levels) ? vol_at[vah_idx + 1] : 0;
      double next_down = (val_idx  - 1 >= 0)    ? vol_at[val_idx  - 1] : 0;
      if(next_up == 0 && next_down == 0) break;
      if(next_up >= next_down && vah_idx + 1 < levels)
         { vah_idx++; accum += vol_at[vah_idx]; }
      else if(val_idx - 1 >= 0)
         { val_idx--;  accum += vol_at[val_idx];  }
      else
         { vah_idx++; accum += vol_at[vah_idx]; }
   }
   g_vah2     = NormalizeDouble(lo + vah_idx * tick_size, _Digits);
   g_val2     = NormalizeDouble(lo + val_idx  * tick_size, _Digits);
   g_svp_set2 = true;
   PrintFormat("📊 [S2] SVP | POC: %.5f | VAH: %.5f | VAL: %.5f | Bare: %d | Vol total: %.0f",
               g_poc2, g_vah2, g_val2, copied, total_vol);
   double range_mid = (g_hi2 + g_lo2) / 2.0;
   bool poc_up = (g_poc2 > range_mid);
   bool val_up = (g_val2 > range_mid);
   bool vah_up = (g_vah2 > range_mid);
   if(val_up && vah_up && poc_up)
   {
      g_high_vol2  = true;
      g_setup_dir2 = -1;
      PrintFormat("🔥 [S2] HIGH VOL SELL | VAL+POC+VAH in jumatatea SUPERIOARA | VAL=%.5f POC=%.5f VAH=%.5f | Retest g_hi2=%.5f | SL via POC",
                  g_val2, g_poc2, g_vah2, g_hi2);
   }
   else if(!val_up && !vah_up && !poc_up)
   {
      g_high_vol2  = true;
      g_setup_dir2 = 1;
      PrintFormat("🔥 [S2] HIGH VOL BUY  | VAL+POC+VAH in jumatatea INFERIOARA | VAL=%.5f POC=%.5f VAH=%.5f | Retest g_lo2=%.5f | SL via POC",
                  g_val2, g_poc2, g_vah2, g_lo2);
   }
   else
   {
      g_high_vol2  = false;
      g_setup_dir2 = 0;
      PrintFormat("📍 [S2] NORMAL RANGE | VA traverseaza mijlocul | VAL=%.5f POC=%.5f VAH=%.5f Mid=%.5f | SL via VAH/VAL | Astept breakout",
                  g_val2, g_poc2, g_vah2, range_mid);
   }
}
// ─────────────────────────────────────────────
// 9. TRIMITERE ORDIN cu calcul lot bazat pe ContractSize
// ─────────────────────────────────────────────
bool SendOrder(ENUM_ORDER_TYPE type, double entry, double sl, double tp)
{
   // Verifica si ajusteaza SL/TP pentru minimum stop level al brokerului
   int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stops_level > 0)
   {
      double min_dist = (stops_level + 5) * _Point; // +5 puncte buffer extra
      if(type == ORDER_TYPE_SELL)
      {
         if(sl < entry + min_dist)
         {
            PrintFormat("⚠️ SL prea aproape (StopLevel=%d pts). Ajustez SL: %.5f → %.5f", stops_level, sl, entry + min_dist);
            sl = NormalizeDouble(entry + min_dist, _Digits);
         }
         if(tp > entry - min_dist)
         {
            PrintFormat("⚠️ TP prea aproape (StopLevel=%d pts). Ajustez TP: %.5f → %.5f", stops_level, tp, entry - min_dist);
            tp = NormalizeDouble(entry - min_dist, _Digits);
         }
      }
      else // BUY
      {
         if(sl > entry - min_dist)
         {
            PrintFormat("⚠️ SL prea aproape (StopLevel=%d pts). Ajustez SL: %.5f → %.5f", stops_level, sl, entry - min_dist);
            sl = NormalizeDouble(entry - min_dist, _Digits);
         }
         if(tp < entry + min_dist)
         {
            PrintFormat("⚠️ TP prea aproape (StopLevel=%d pts). Ajustez TP: %.5f → %.5f", stops_level, tp, entry + min_dist);
            tp = NormalizeDouble(entry + min_dist, _Digits);
         }
      }
   }
   double real_risk_price = MathAbs(entry - sl);
   if(real_risk_price <= 0)
   {
      Print("❌ Risc calculat = 0, ordin anulat.");
      return false;
   }
   double contract_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double tick_size     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(contract_size <= 0 || tick_size <= 0 || tick_value <= 0)
   {
      Print("❌ Date simbol invalide (ContractSize/TickSize/TickValue).");
      return false;
   }
   double point_value   = tick_value / tick_size;
   double lot_calc      = RiskMoney / (real_risk_price * point_value);
   double vol_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vol_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lot_before_cap = lot_calc;
   double lot = MathFloor(lot_calc / vol_step) * vol_step;
   lot = MathMax(lot, vol_min);
   lot = MathMin(lot, MathMin(MaxLotLimit, vol_max));
   double risc_real = real_risk_price * point_value * lot;
   PrintFormat("💰 Lot calc: %.2f → dupa limite: %.2f | SL: %.2f pts | PointVal: %.4f | ContractSize: %.0f | Risc real: $%.2f (target: $%.2f)%s",
               lot_before_cap, lot,
               real_risk_price, point_value, contract_size,
               risc_real, RiskMoney,
               (lot_calc - lot > vol_step) ? " ⚠️ LOT TAIAT DE MaxLotLimit!" : "");
   // FIX #1: Verifica market deschis (previne Error 10018)
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode != SYMBOL_TRADE_MODE_FULL)
   {
      PrintFormat("❌ Market inchis (SYMBOL_TRADE_MODE=%d) - ordin anulat. Retcode 10018 prevenit.", (int)tradeMode);
      return false;
   }
   double ask_chk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid_chk = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask_chk <= 0 || bid_chk <= 0)
   {
      Print("❌ Preturi invalide (ask/bid = 0) - market probabil inchis.");
      return false;
   }
   // FIX #2: Verifica si ajusteaza lot daca margin insuficient (previne Error 10019)
   double margin_needed = 0;
   if(!OrderCalcMargin(type, _Symbol, lot, entry, margin_needed))
   {
      Print("❌ Nu se poate calcula marginea necesara.");
      return false;
   }
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin_needed > free_margin * 0.95)
   {
      PrintFormat("⚠️ Margin insuficient la lot=%.2f (necesar=%.2f | disponibil=%.2f) - reduc lot-ul...",
                  lot, margin_needed, free_margin);
      // Reduce lot treptat pana incape in margin disponibil
      double reduced_lot = MathFloor((lot - vol_step) / vol_step) * vol_step;
      while(reduced_lot >= vol_min)
      {
         if(!OrderCalcMargin(type, _Symbol, reduced_lot, entry, margin_needed)) break;
         if(margin_needed <= free_margin * 0.95) break;
         reduced_lot = MathFloor((reduced_lot - vol_step) / vol_step) * vol_step;
      }
      if(reduced_lot < vol_min || margin_needed > free_margin * 0.95)
      {
         PrintFormat("❌ Margin insuficient chiar si la lot minim (%.2f). Free margin=$%.2f - ordin anulat.",
                     vol_min, free_margin);
         return false;
      }
      PrintFormat("✅ Lot redus: %.2f → %.2f (margin necesar=%.2f | disponibil=%.2f)",
                  lot, reduced_lot, margin_needed, free_margin);
      lot = reduced_lot;
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
   req.comment   = "BreakoutEA v3";
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)      req.type_filling = ORDER_FILLING_FOK;
   else if((filling & SYMBOL_FILLING_IOC) != 0) req.type_filling = ORDER_FILLING_IOC;
   else                                          req.type_filling = ORDER_FILLING_RETURN;
   bool sent = OrderSend(req, res);
   if(sent)
      PrintFormat("✅ Ordin %s | Lot: %.2f | Entry: %.5f | SL: %.5f | TP: %.5f | Risc real: $%.2f",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lot, entry, sl, tp,
                  real_risk_price * point_value * lot);
   else
   {
      PrintFormat("❌ Eroare ordin: %d - %s", res.retcode, res.comment);
      if(res.retcode == 10019 || res.retcode == 10018 || res.retcode == 10016)
      {
         PrintFormat("⛔ Eroare %d (%s) - ziua blocata.", res.retcode,
                     res.retcode == 10019 ? "No Money" :
                     res.retcode == 10018 ? "Market Closed" : "Invalid Stops");
         return true;
      }
   }
   return sent;
}
// ─────────────────────────────────────────────
// 10. BREAK-EVEN MANAGEMENT (cu magic filter)
// ─────────────────────────────────────────────
void ManageBreakEven()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      double op   = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double risk = MathAbs(op - sl);
      if(risk <= 0) continue;
      double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double be_level = risk * BE_Activation;
      double new_sl   = 0;
      bool   need_be  = false;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         if(bid >= op + be_level && sl < op)
         {
            new_sl  = NormalizeDouble(op + SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) * 2, _Digits);
            need_be = true;
         }
      }
      else
      {
         if(ask <= op - be_level && (sl > op || sl == 0))
         {
            new_sl  = NormalizeDouble(op - SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) * 2, _Digits);
            need_be = true;
         }
      }
      if(need_be)
      {
         MqlTradeRequest req = {};
         MqlTradeResult  res = {};
         req.action   = TRADE_ACTION_SLTP;
         req.position = ticket;
         req.symbol   = _Symbol;
         req.sl       = new_sl;
         req.tp       = NormalizeDouble(tp, _Digits);
         if(OrderSend(req, res))
            PrintFormat("🔒 BE activat pentru pozitia #%d la %.5f", ticket, new_sl);
         else
            Print("⚠️ Eroare BE: ", res.retcode);
      }
   }
}
// ─────────────────────────────────────────────
// 11. INCHIDERE FORTATA LA ORA DE EXIT
// ─────────────────────────────────────────────
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action    = TRADE_ACTION_DEAL;
      req.position  = ticket;
      req.symbol    = _Symbol;
      req.volume    = PositionGetDouble(POSITION_VOLUME);
      req.magic     = MagicNumber;
      req.deviation = Slippage;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         req.type  = ORDER_TYPE_SELL;
         req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      }
      else
      {
         req.type  = ORDER_TYPE_BUY;
         req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      }
      uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
      if((filling & SYMBOL_FILLING_FOK) != 0)      req.type_filling = ORDER_FILLING_FOK;
      else if((filling & SYMBOL_FILLING_IOC) != 0) req.type_filling = ORDER_FILLING_IOC;
      else                                          req.type_filling = ORDER_FILLING_RETURN;
      if(OrderSend(req, res))
         Print("🔴 Pozitie inchisa la ora de exit: #", ticket);
      else
         Print("⚠️ Eroare la inchidere: ", res.retcode);
   }
}
// ─────────────────────────────────────────────
// 12. NUMAR POZITII DESCHISE (cu magic filter)
// ─────────────────────────────────────────────
int CountMyPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}
// ─────────────────────────────────────────────
// 13. OnInit / OnDeinit
// ─────────────────────────────────────────────
int OnInit()
{
   Print("✅ BreakoutEA v3 initializat pe ", _Symbol, " | Magic: ", MagicNumber);
   MqlDateTime srv;
   TimeCurrent(srv);
   bool dst    = IsEuropeanDST(TimeCurrent());
   int  offset = dst ? ServerOffsetSummer : ServerOffsetWinter;
   PrintFormat("🕐 Ora SERVER: %02d:%02d | DST: %s | Offset aplicat: %+dh",
               srv.hour, srv.min,
               dst ? "VARA (activ)" : "IARNA (inactiv)",
               offset);
   PrintFormat("📅 Fereastra locala:  Range %02d:%02d-%02d:%02d | Entry pana %02d:00 | Exit %02d:%02d",
               RangeStartHour, RangeStartMin,
               RangeEndHour,   RangeEndMin,
               EntryEndHour,
               ExitHour,       ExitMin);
   PrintFormat("📅 Fereastra SERVER:  Range %02d:%02d-%02d:%02d | Entry pana %02d:00 | Exit %02d:%02d",
               ToServerHour(RangeStartHour), RangeStartMin,
               ToServerHour(RangeEndHour),   RangeEndMin,
               ToServerHour(EntryEndHour),
               ToServerHour(ExitHour),       ExitMin);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double cs = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double pv = (ts > 0) ? tv / ts : 0;
   PrintFormat("📋 Symbol info | TickSize=%.6f | TickValue=%.6f | ContractSize=%.2f | PointValue=%.4f$/pt/lot",
               ts, tv, cs, pv);
   PrintFormat("📋 Range filter | Min=%.1f pts | Max=%.1f pts | RiskMoney=$%.0f | La SL=20pts → lot≈%.2f",
               MinPoints, MaxPoints, RiskMoney, (pv > 0 ? RiskMoney / (20.0 * pv) : 0));
   if(EnableSession2)
      PrintFormat("📅 [S2] Fereastra SERVER:  Range %02d:%02d-%02d:%02d | Entry pana %02d:00",
                  ToServerHour(R2StartHour), R2StartMin,
                  ToServerHour(R2EndHour),   R2EndMin,
                  ToServerHour(Entry2EndHour));
   // Restaureaza g_traded_today dupa restart
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(HistorySelect(today, TimeCurrent()))
   {
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
         g_last_trade   = today;
         g_traded_today = true;
         Print("⚠️ EA restartat: tranzactie [S1] detectata azi, intrare S1 blocata.");
         break;
      }
   }
   // Restaureaza g_traded_s2 dupa restart
   if(EnableSession2 && HistorySelect(today, TimeCurrent()))
   {
      datetime r2_end_dt = today + ToServerHour(R2EndHour) * 3600 + R2EndMin * 60;
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
         datetime deal_time = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         if(deal_time >= r2_end_dt)
         {
            g_traded_s2 = true;
            Print("⚠️ EA restartat: tranzactie [S2] detectata azi, intrare S2 blocata.");
         }
         break;
      }
   }
   // Restaureaza g_halted_since dupa restart
   if(HistorySelect(TimeCurrent() - LookbackDays * 86400, TimeCurrent()))
   {
      int losses = 0;
      datetime last_loss_time = 0;
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                       + HistoryDealGetDouble(ticket, DEAL_SWAP)
                       + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         if(profit < 0)
         {
            losses++;
            if(last_loss_time == 0)
               last_loss_time = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
            if(losses >= MaxConsecLosses)
            {
               if(TimeCurrent() < last_loss_time + CB_PauseDays * 86400)
               {
                  g_halted_since = last_loss_time;
                  PrintFormat("⚠️ EA restartat: Circuit Breaker era activ. Pauza pana la %s",
                              TimeToString(g_halted_since + CB_PauseDays * 86400, TIME_DATE));
               }
               break;
            }
         }
         else if(profit > 0) break;
      }
   }
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   ObjectDelete(0, VWAP_OBJ);
   Print("EA oprit. Motiv: ", reason);
}
// ─────────────────────────────────────────────
// 14. OnTick PRINCIPAL
// ─────────────────────────────────────────────
void OnTick()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int curTime = dt.hour * 100 + dt.min;
   int exitTime  = ToServerHour(ExitHour)      * 100 + ExitMin;
   int entry_end = ToServerHour(EntryEndHour)  * 100;
   int range_end = ToServerHour(RangeEndHour)  * 100 + RangeEndMin;
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   // --- Reset range la inceputul fiecarei zile ---
   static datetime last_reset_day = 0;
   if(today != last_reset_day)
   {
      g_hi           = 0;
      g_lo           = 0;
      g_range_set    = false;
      g_traded_today = false;
      g_vah          = 0;
      g_val          = 0;
      g_poc          = 0;
      g_svp_set      = false;
      g_setup_dir    = 0;
      g_high_vol     = false;
      g_breakout_dir = 0;
      // Reset sesiunea 2
      g_hi2           = 0;
      g_lo2           = 0;
      g_range_set2    = false;
      g_traded_s2     = false;
      g_vah2          = 0;
      g_val2          = 0;
      g_poc2          = 0;
      g_svp_set2      = false;
      g_setup_dir2    = 0;
      g_high_vol2     = false;
      g_breakout_dir2 = 0;
      last_reset_day = today;
      Print("🔄 Reset range + SVP pentru ziua noua: ", TimeToString(today, TIME_DATE));
      bool dst    = IsEuropeanDST(TimeCurrent());
      int  offset = dst ? ServerOffsetSummer : ServerOffsetWinter;
      PrintFormat("🕐 Ora server: %02d:%02d | DST: %s | Offset: %+dh | Fereastra server: %02d:%02d-%02d:%02d",
                  dt.hour, dt.min,
                  dst ? "VARA" : "IARNA",
                  offset,
                  ToServerHour(RangeStartHour), RangeStartMin,
                  ToServerHour(RangeEndHour),   RangeEndMin);
   }
   // --- Inchidere fortata la ora de exit ---
   if(curTime >= exitTime)
   {
      if(CountMyPositions() > 0)
      {
         Print("⏰ Ora de exit atinsa (", ToServerHour(ExitHour), ":", ExitMin, " server) - inchid pozitii.");
         CloseAllPositions();
      }
      return;
   }
   // --- Calculeaza VWAP o data pe bara noua (doar daca e activ) ---
   datetime current_bar = iTime(_Symbol, _Period, 0);
   if(current_bar != g_last_bar)
   {
      g_vwap     = UseVWAP ? CalcWeeklyVWAP() : 0;
      g_last_bar = current_bar;
   }
   // --- Colecteaza range-ul ---
   CollectRange();
   // --- Calculeaza SVP imediat dupa ce range-ul e finalizat ---
   if(g_range_set && !g_svp_set)
      CalcSVP();
   // --- Sesiunea 2 (optional) ---
   if(EnableSession2)
   {
      CollectRange2();
      if(g_range_set2 && !g_svp_set2)
         CalcSVP2();
   }
   // --- Manage Break-Even ---
   ManageBreakEven();
   // ── LOGICA DE INTRARE ──────────────────────
   bool day_ok = (dt.day_of_week == 1 && Mon)
              || (dt.day_of_week == 2 && Tue)
              || (dt.day_of_week == 3 && Wed)
              || (dt.day_of_week == 4 && Thu)
              || (dt.day_of_week == 5 && Fri);
   bool can_trade = day_ok
                 && g_range_set
                 && g_svp_set
                 && (g_hi > 0 && g_lo > 0)
                 && (g_vah > 0 && g_val > 0)
                 && curTime > range_end
                 && curTime < entry_end
                 && !g_traded_today
                 && CountMyPositions() == 0
                 && !IsSystemHalted();
   static datetime last_skip_log = 0;
   if(!can_trade && !g_traded_today && curTime > range_end && curTime < entry_end && today != last_skip_log)
   {
      last_skip_log = today;
      PrintFormat("❓ Zi netraduta %s | range_set:%s | hi:%.2f lo:%.2f | halted:%s | positions:%d",
                  TimeToString(TimeCurrent(), TIME_DATE),
                  g_range_set ? "DA" : "NU",
                  g_hi, g_lo,
                  IsSystemHalted() ? "DA" : "NU",
                  CountMyPositions());
   }
   if(!can_trade) return;
   // Verifica range valid
   double diff       = g_hi - g_lo;
   double diff_pts   = diff / _Point;
   if(diff_pts < MinPoints || diff_pts > MaxPoints)
   {
      static datetime last_range_dbg = 0;
      if(TimeCurrent() - last_range_dbg >= 3600)
      {
         PrintFormat("⚠️ Range invalid: %.1f puncte (min:%.1f max:%.1f) - skip",
                     diff_pts, MinPoints, MaxPoints);
         last_range_dbg = TimeCurrent();
      }
      return;
   }
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ═══════════════════════════════════════════════════════════════
   // LOGICA UNIFICATA: Breakout (1 bara confirmare) + Retest entry
   //
   // STEP 1 – Detectare breakout pe ultima bara inchisa (M1 bar[1])
   // ─────────────────────────────────────────────────────────────
   // HIGH VOL SELL (g_setup_dir==-1): astept bara inchisa PESTE g_hi
   // HIGH VOL BUY  (g_setup_dir== 1): astept bara inchisa SUB  g_lo
   // NORMAL        (g_setup_dir== 0): accept oricare directie
   //
   // STEP 2 – Retest (pretul revine la g_hi sau g_lo)
   //   Chiar daca bara de retest inchide inauntrul range-ului → INTRA
   //
   // SL:
   //   HIGH VOL → GetRetestSL_Long/Short (bazat pe POC)
   //   NORMAL   → GetNormalSL_Long/Short (bazat pe VAH/VAL)
   // ═══════════════════════════════════════════════════════════════

   if(g_breakout_dir == 0)
   {
      // ── STEP 1: Verifica daca ultima bara inchisa a spart range-ul ──
      MqlRates rb[];
      ArraySetAsSeries(rb, true);
      if(CopyRates(_Symbol, PERIOD_M1, 1, 1, rb) < 1) return;

      bool broke_up   = (rb[0].close > g_hi);
      bool broke_down = (rb[0].close < g_lo);

      if(g_high_vol)
      {
         // HIGH VOL SELL: asteptam spargere sus (bara inchisa > g_hi) → vom SELL la retest
         if(g_setup_dir == -1 && broke_up)
         {
            g_breakout_dir = 1;
            PrintFormat("📈 BREAKOUT SUS g_hi=%.5f (bara inchisa=%.5f) | HIGH VOL SELL – astept retest", g_hi, rb[0].close);
         }
         // HIGH VOL BUY: asteptam spargere jos (bara inchisa < g_lo) → vom BUY la retest
         else if(g_setup_dir == 1 && broke_down)
         {
            g_breakout_dir = -1;
            PrintFormat("📉 BREAKOUT JOS g_lo=%.5f (bara inchisa=%.5f) | HIGH VOL BUY – astept retest", g_lo, rb[0].close);
         }
      }
      else // NORMAL RANGE: accept oricare directie
      {
         if(broke_up)
         {
            g_breakout_dir = 1;
            PrintFormat("📈 BREAKOUT SUS g_hi=%.5f (bara inchisa=%.5f) | NORMAL BUY – astept retest", g_hi, rb[0].close);
         }
         else if(broke_down)
         {
            g_breakout_dir = -1;
            PrintFormat("📉 BREAKOUT JOS g_lo=%.5f (bara inchisa=%.5f) | NORMAL SELL – astept retest", g_lo, rb[0].close);
         }
      }
      return; // nu intra pana nu vine retestul
   }

   // ── STEP 2: Retest – pretul a revenit la nivelul spart ──
   // g_breakout_dir == 1: spart SUS → retest = pretul coboara la g_hi
   // g_breakout_dir == -1: spart JOS → retest = pretul urca la g_lo

   if(g_breakout_dir == 1) // spart PESTE g_hi
   {
      // Retest: bid a revenit la g_hi (indiferent daca bara inchide inauntru)
      if(bid > g_hi) return; // inca nu s-a retest

      if(g_high_vol) // HIGH VOL SELL: vand la retest g_hi
      {
         if(UseVWAP && ask >= g_vwap) return; // filtru VWAP
         double entry     = bid;
         double sl        = GetRetestSL_Short();
         double real_risk = MathAbs(sl - entry);
         double tp        = entry - (real_risk * RRRatio);
         if(real_risk <= 0 || tp >= entry || sl <= entry)
         { Print("⚠️ SELL(HighVol): SL/TP invalide. Entry=", entry, " SL=", sl); return; }
         PrintFormat("📊 SELL Retest HIGH VOL | Range:%.2fpts | Entry:%.5f | SL:%.5f(POC=%.5f) | TP:%.5f | Risc:%.2fpts",
                     diff_pts, entry, sl, g_poc, tp, real_risk/_Point);
         g_traded_today = true;
         if(!SendOrder(ORDER_TYPE_SELL, entry, sl, tp)) g_traded_today = false;
      }
      else // NORMAL BUY: cumpar la retest g_hi (suport dupa breakout sus)
      {
         if(UseVWAP && bid < g_vwap) return; // filtru VWAP
         double entry     = ask;
         double sl        = GetNormalSL_Long();
         double real_risk = MathAbs(entry - sl);
         double tp        = entry + (real_risk * RRRatio);
         if(real_risk <= 0 || tp <= entry || sl >= entry)
         { Print("⚠️ BUY(Normal): SL/TP invalide. Entry=", entry, " SL=", sl); return; }
         PrintFormat("📊 BUY Retest NORMAL | Range:%.2fpts | Entry:%.5f | SL:%.5f(VAL=%.5f) | TP:%.5f | Risc:%.2fpts",
                     diff_pts, entry, sl, g_val, tp, real_risk/_Point);
         g_traded_today = true;
         if(!SendOrder(ORDER_TYPE_BUY, entry, sl, tp)) g_traded_today = false;
      }
   }
   else // g_breakout_dir == -1: spart SUB g_lo
   {
      // Retest: ask a revenit la g_lo (indiferent daca bara inchide inauntru)
      if(ask < g_lo) return; // inca nu s-a retest

      if(g_high_vol) // HIGH VOL BUY: cumpar la retest g_lo
      {
         if(UseVWAP && bid < g_vwap) return; // filtru VWAP
         double entry     = ask;
         double sl        = GetRetestSL_Long();
         double real_risk = MathAbs(entry - sl);
         double tp        = entry + (real_risk * RRRatio);
         if(real_risk <= 0 || tp <= entry || sl >= entry)
         { Print("⚠️ BUY(HighVol): SL/TP invalide. Entry=", entry, " SL=", sl); return; }
         PrintFormat("📊 BUY Retest HIGH VOL | Range:%.2fpts | Entry:%.5f | SL:%.5f(POC=%.5f) | TP:%.5f | Risc:%.2fpts",
                     diff_pts, entry, sl, g_poc, tp, real_risk/_Point);
         g_traded_today = true;
         if(!SendOrder(ORDER_TYPE_BUY, entry, sl, tp)) g_traded_today = false;
      }
      else // NORMAL SELL: vand la retest g_lo (rezistenta dupa breakout jos)
      {
         if(UseVWAP && ask >= g_vwap) return; // filtru VWAP
         double entry     = bid;
         double sl        = GetNormalSL_Short();
         double real_risk = MathAbs(sl - entry);
         double tp        = entry - (real_risk * RRRatio);
         if(real_risk <= 0 || tp >= entry || sl <= entry)
         { Print("⚠️ SELL(Normal): SL/TP invalide. Entry=", entry, " SL=", sl); return; }
         PrintFormat("📊 SELL Retest NORMAL | Range:%.2fpts | Entry:%.5f | SL:%.5f(VAH=%.5f) | TP:%.5f | Risc:%.2fpts",
                     diff_pts, entry, sl, g_vah, tp, real_risk/_Point);
         g_traded_today = true;
         if(!SendOrder(ORDER_TYPE_SELL, entry, sl, tp)) g_traded_today = false;
      }
   }

   // ══════════════════════════════════════════════════════════════
   // LOGICA SESIUNEA 2
   // ══════════════════════════════════════════════════════════════
   if(!EnableSession2) return;

   int range_end2 = ToServerHour(R2EndHour)    * 100 + R2EndMin;
   int entry_end2 = ToServerHour(Entry2EndHour) * 100;

   bool can_trade2 = day_ok
                  && g_range_set2
                  && g_svp_set2
                  && (g_hi2 > 0 && g_lo2 > 0)
                  && (g_vah2 > 0 && g_val2 > 0)
                  && curTime > range_end2
                  && curTime < entry_end2
                  && !g_traded_s2
                  && CountMyPositions() == 0
                  && !IsSystemHalted();

   if(!can_trade2) return;

   // Verifica range valid sesiunea 2
   double diff2     = g_hi2 - g_lo2;
   double diff_pts2 = diff2 / _Point;
   if(diff_pts2 < MinPoints || diff_pts2 > MaxPoints)
   {
      static datetime last_range_dbg2 = 0;
      if(TimeCurrent() - last_range_dbg2 >= 3600)
      {
         PrintFormat("⚠️ [S2] Range invalid: %.1f puncte (min:%.1f max:%.1f) - skip",
                     diff_pts2, MinPoints, MaxPoints);
         last_range_dbg2 = TimeCurrent();
      }
      return;
   }

   if(g_breakout_dir2 == 0)
   {
      MqlRates rb2[];
      ArraySetAsSeries(rb2, true);
      if(CopyRates(_Symbol, PERIOD_M1, 1, 1, rb2) < 1) return;

      bool broke_up2   = (rb2[0].close > g_hi2);
      bool broke_down2 = (rb2[0].close < g_lo2);

      if(g_high_vol2)
      {
         if(g_setup_dir2 == -1 && broke_up2)
         {
            g_breakout_dir2 = 1;
            PrintFormat("📈 [S2] BREAKOUT SUS g_hi2=%.5f (bara inchisa=%.5f) | HIGH VOL SELL – astept retest", g_hi2, rb2[0].close);
         }
         else if(g_setup_dir2 == 1 && broke_down2)
         {
            g_breakout_dir2 = -1;
            PrintFormat("📉 [S2] BREAKOUT JOS g_lo2=%.5f (bara inchisa=%.5f) | HIGH VOL BUY – astept retest", g_lo2, rb2[0].close);
         }
      }
      else
      {
         if(broke_up2)
         {
            g_breakout_dir2 = 1;
            PrintFormat("📈 [S2] BREAKOUT SUS g_hi2=%.5f (bara inchisa=%.5f) | NORMAL BUY – astept retest", g_hi2, rb2[0].close);
         }
         else if(broke_down2)
         {
            g_breakout_dir2 = -1;
            PrintFormat("📉 [S2] BREAKOUT JOS g_lo2=%.5f (bara inchisa=%.5f) | NORMAL SELL – astept retest", g_lo2, rb2[0].close);
         }
      }
      return;
   }

   if(g_breakout_dir2 == 1)
   {
      if(bid > g_hi2) return;

      if(g_high_vol2)
      {
         if(UseVWAP && ask >= g_vwap) return;
         double entry     = bid;
         double sl        = GetRetestSL_Short2();
         double real_risk = MathAbs(sl - entry);
         double tp        = entry - (real_risk * RRRatio);
         if(real_risk <= 0 || tp >= entry || sl <= entry)
         { Print("⚠️ [S2] SELL(HighVol): SL/TP invalide. Entry=", entry, " SL=", sl); return; }
         PrintFormat("📊 [S2] SELL Retest HIGH VOL | Range:%.2fpts | Entry:%.5f | SL:%.5f(POC=%.5f) | TP:%.5f | Risc:%.2fpts",
                     diff_pts2, entry, sl, g_poc2, tp, real_risk/_Point);
         g_traded_s2 = true;
         if(!SendOrder(ORDER_TYPE_SELL, entry, sl, tp)) g_traded_s2 = false;
      }
      else
      {
         if(UseVWAP && bid < g_vwap) return;
         double entry     = ask;
         double sl        = GetNormalSL_Long2();
         double real_risk = MathAbs(entry - sl);
         double tp        = entry + (real_risk * RRRatio);
         if(real_risk <= 0 || tp <= entry || sl >= entry)
         { Print("⚠️ [S2] BUY(Normal): SL/TP invalide. Entry=", entry, " SL=", sl); return; }
         PrintFormat("📊 [S2] BUY Retest NORMAL | Range:%.2fpts | Entry:%.5f | SL:%.5f(VAL=%.5f) | TP:%.5f | Risc:%.2fpts",
                     diff_pts2, entry, sl, g_val2, tp, real_risk/_Point);
         g_traded_s2 = true;
         if(!SendOrder(ORDER_TYPE_BUY, entry, sl, tp)) g_traded_s2 = false;
      }
   }
   else
   {
      if(ask < g_lo2) return;

      if(g_high_vol2)
      {
         if(UseVWAP && bid < g_vwap) return;
         double entry     = ask;
         double sl        = GetRetestSL_Long2();
         double real_risk = MathAbs(entry - sl);
         double tp        = entry + (real_risk * RRRatio);
         if(real_risk <= 0 || tp <= entry || sl >= entry)
         { Print("⚠️ [S2] BUY(HighVol): SL/TP invalide. Entry=", entry, " SL=", sl); return; }
         PrintFormat("📊 [S2] BUY Retest HIGH VOL | Range:%.2fpts | Entry:%.5f | SL:%.5f(POC=%.5f) | TP:%.5f | Risc:%.2fpts",
                     diff_pts2, entry, sl, g_poc2, tp, real_risk/_Point);
         g_traded_s2 = true;
         if(!SendOrder(ORDER_TYPE_BUY, entry, sl, tp)) g_traded_s2 = false;
      }
      else
      {
         if(UseVWAP && ask >= g_vwap) return;
         double entry     = bid;
         double sl        = GetNormalSL_Short2();
         double real_risk = MathAbs(sl - entry);
         double tp        = entry - (real_risk * RRRatio);
         if(real_risk <= 0 || tp >= entry || sl <= entry)
         { Print("⚠️ [S2] SELL(Normal): SL/TP invalide. Entry=", entry, " SL=", sl); return; }
         PrintFormat("📊 [S2] SELL Retest NORMAL | Range:%.2fpts | Entry:%.5f | SL:%.5f(VAH=%.5f) | TP:%.5f | Risc:%.2fpts",
                     diff_pts2, entry, sl, g_vah2, tp, real_risk/_Point);
         g_traded_s2 = true;
         if(!SendOrder(ORDER_TYPE_SELL, entry, sl, tp)) g_traded_s2 = false;
      }
   }
}
//+------------------------------------------------------------------+
