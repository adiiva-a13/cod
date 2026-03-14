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
// Directia setup bazata pe pozitia POC: 1=BUY, -1=SELL, 0=neutru
int      g_setup_dir    = 0;
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
   // Determina directia setup bazata pe pozitia POC fata de mijlocul range-ului
   double range_mid = (g_hi + g_lo) / 2.0;
   if(g_poc > range_mid)
   {
      g_setup_dir = -1;
      PrintFormat("📍 Setup: SELL | POC (%.5f) in jumatatea SUPERIOARA | Mid: %.5f | Retest la g_hi=%.5f",
                  g_poc, range_mid, g_hi);
   }
   else if(g_poc < range_mid)
   {
      g_setup_dir = 1;
      PrintFormat("📍 Setup: BUY  | POC (%.5f) in jumatatea INFERIOARA | Mid: %.5f | Retest la g_lo=%.5f",
                  g_poc, range_mid, g_lo);
   }
   else
   {
      g_setup_dir = 0;
      PrintFormat("📍 Setup: NEUTRU | POC (%.5f) exact la mijloc (%.5f) - nicio tranzactie.", g_poc, range_mid);
   }
}
// ─────────────────────────────────────────────
// 7. SL BAZAT PE POC (retest entry)
//    BUY:  SL sub POC, sau sub cel mai mic low de dupa range daca e sub POC
//    SELL: SL peste POC, sau peste cel mai mare high de dupa range daca e peste POC
// ─────────────────────────────────────────────
double GetRetestSL_Long()
{
   int srv_end_h = ToServerHour(RangeEndHour);
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today        = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   datetime range_end_dt = today + srv_end_h * 3600 + RangeEndMin * 60;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   // Bara 1 = ultima bara inchisa (bara de retest)
   int copied = CopyRates(_Symbol, PERIOD_M1, 1, 1, r);
   double buf = MathMax(SL_Buffer_Pts, 20.0) * _Point;
   // Ultimul low format dupa inchiderea range-ului = low-ul barei de retest
   double last_low = (copied > 0) ? r[0].low : g_poc;
   double sl_ref   = (last_low < g_poc) ? last_low : g_poc;
   double sl       = sl_ref - buf;
   if(last_low < g_poc)
      PrintFormat("📍 BUY SL: ultimul low=%.5f (< POC=%.5f) → SL=%.5f (buf=%.1f pts)", last_low, g_poc, sl, buf / _Point);
   else
      PrintFormat("📍 BUY SL: POC=%.5f (ultimul low >= POC) → SL=%.5f (buf=%.1f pts)", g_poc, sl, buf / _Point);
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
   ArraySetAsSeries(r, true);
   // Bara 1 = ultima bara inchisa (bara de retest)
   int copied = CopyRates(_Symbol, PERIOD_M1, 1, 1, r);
   double buf = MathMax(SL_Buffer_Pts, 20.0) * _Point;
   // Ultimul high format dupa inchiderea range-ului = high-ul barei de retest
   double last_high = (copied > 0) ? r[0].high : g_poc;
   double sl_ref    = (last_high > g_poc) ? last_high : g_poc;
   double sl        = sl_ref + buf;
   if(last_high > g_poc)
      PrintFormat("📍 SELL SL: ultimul high=%.5f (> POC=%.5f) → SL=%.5f (buf=%.1f pts)", last_high, g_poc, sl, buf / _Point);
   else
      PrintFormat("📍 SELL SL: POC=%.5f (ultimul high <= POC) → SL=%.5f (buf=%.1f pts)", g_poc, sl, buf / _Point);
   return NormalizeDouble(sl, _Digits);
}
// ─────────────────────────────────────────────
// 8. COLECTARE RANGE - finalizata DUPA inchiderea ferestrei (10:15 server)
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
// 9. TRIMITERE ORDIN cu calcul lot bazat pe ContractSize
// ─────────────────────────────────────────────
bool SendOrder(ENUM_ORDER_TYPE type, double entry, double sl, double tp)
{
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
      if(res.retcode == 10019 || res.retcode == 10018)
      {
         PrintFormat("⛔ Eroare %d (%s) - ziua blocata.", res.retcode,
                     res.retcode == 10019 ? "No Money" : "Market Closed");
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
         Print("⚠️ EA restartat: tranzactie detectata azi, intrare blocata.");
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
   // Fara setup valid (POC la mijloc) - nicio tranzactie
   if(g_setup_dir == 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ── Detectare RETEST pe ConfirmBars bare M1 consecutive ──
   // BUY setup (POC in jumatatea inferioara): asteptam retest la g_lo (low <= g_lo)
   // SELL setup (POC in jumatatea superioara): asteptam retest la g_hi (high >= g_hi)
   bool do_buy  = false;
   bool do_sell = false;
   int  bars_check = MathMax(ConfirmBars, 1);
   MqlRates rm1[];
   ArraySetAsSeries(rm1, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, bars_check, rm1) < bars_check) return;

   if(g_setup_dir == 1) // BUY: retest la baza range-ului
   {
      bool retest_ok = true;
      for(int i = 0; i < bars_check; i++)
         if(rm1[i].low > g_lo) { retest_ok = false; break; }
      do_buy = retest_ok && (!UseVWAP || bid > g_vwap);
   }
   else // SELL: retest la varful range-ului
   {
      bool retest_ok = true;
      for(int i = 0; i < bars_check; i++)
         if(rm1[i].high < g_hi) { retest_ok = false; break; }
      do_sell = retest_ok && (!UseVWAP || ask < g_vwap);
   }

   // ── BUY Retest ──
   if(do_buy)
   {
      double entry     = ask;
      double sl        = GetRetestSL_Long();
      double real_risk = MathAbs(entry - sl);
      double tp        = entry + (real_risk * RRRatio);
      if(real_risk <= 0 || tp <= entry || sl >= entry)
      {
         Print("⚠️ BUY: valori invalide SL/TP (SL>=entry?), skip. Entry=", entry, " SL=", sl);
         return;
      }
      PrintFormat("📊 BUY Retest (%d bare) | Range: %.2f pts | Entry: %.5f | SL: %.5f (POC=%.5f) | TP: %.5f | Risc: %.2f pts",
                  bars_check, diff_pts, entry, sl, g_poc, tp, real_risk / _Point);
      g_traded_today = true;
      if(!SendOrder(ORDER_TYPE_BUY, entry, sl, tp))
         g_traded_today = false;
   }
   // ── SELL Retest ──
   else if(do_sell)
   {
      double entry     = bid;
      double sl        = GetRetestSL_Short();
      double real_risk = MathAbs(sl - entry);
      double tp        = entry - (real_risk * RRRatio);
      if(real_risk <= 0 || tp >= entry || sl <= entry)
      {
         Print("⚠️ SELL: valori invalide SL/TP (SL<=entry?), skip. Entry=", entry, " SL=", sl);
         return;
      }
      PrintFormat("📊 SELL Retest (%d bare) | Range: %.2f pts | Entry: %.5f | SL: %.5f (POC=%.5f) | TP: %.5f | Risc: %.2f pts",
                  bars_check, diff_pts, entry, sl, g_poc, tp, real_risk / _Point);
      g_traded_today = true;
      if(!SendOrder(ORDER_TYPE_SELL, entry, sl, tp))
         g_traded_today = false;
   }
}
//+------------------------------------------------------------------+
