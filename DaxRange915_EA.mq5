//+------------------------------------------------------------------+
//|  DaxRange915_EA.mq5                                              |
//|  DAX Range 9:15-9:30 Breakout — T1 / T2 / T3                   |
//|  Echivalent cu DaxRange915_1min.pine                             |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "1.00"
#include <Trade\Trade.mqh>

// ═══════════════════════════════════════════════════════════
//  INPUTS
// ═══════════════════════════════════════════════════════════
input group "═══ Strategie ═══"
input double i_offset    = 5.0;   // Offset stop (puncte)
input double i_tpR       = 3.0;   // TP Ratio (R)
input int    i_eodH      = 22;    // EOD ora (Romania)
input int    i_eodMin    = 0;     // EOD minut (Romania)
input int    i_tzOffset  = 0;     // Offset server→Romania (ore, ex: 0 daca server=EET)

input group "═══ Sizing ═══"
input bool   i_autoSize   = true;  // Calcul automat din $ risc
input double i_riskUSD    = 100.0; // Risc $ per trade
input double i_riskMargin = 30.0;  // Marja rotunjire $ (max +)
input double i_pointValue = 10.0;  // Valoare punct EUR/lot (GER40: 10)
input double i_qtyFixed   = 1.0;   // Loturi fixe (AUTO=off)
input double i_maxLots    = 2.0;   // Loturi maxime (cap)

input group "═══ Break-Even ═══"
input bool   i_beEnabled  = true;  // Activa Break-Even
input double i_beR        = 2.5;   // BE la (R)

// ═══════════════════════════════════════════════════════════
//  CONSTANTE & STARE GLOBALA
// ═══════════════════════════════════════════════════════════
#define MAGIC 9150

CTrade g_trade;

// Faze: 0=astept range, 1=T1 pending, 2=T1 activ,
//       4=T2 activ, 6=T3 activ, 9=done
int    g_phase   = 0;
int    g_dir     = 0;    // 1=long, -1=short
bool   g_t2Confirmed = false;  // T2 confirmat deschis (anti race-condition)
bool   g_t3Confirmed = false;  // T3 confirmat deschis (anti race-condition)

double g_rngH    = 0;
double g_rngL    = 0;
double g_t1BS    = 0;   // T1 Buy Stop  (range H + offset)
double g_t1SS    = 0;   // T1 Sell Stop (range L - offset)
double g_t1LSL   = 0;   // T1 Long SL
double g_t1LTP   = 0;   // T1 Long TP
double g_t1SSL   = 0;   // T1 Short SL
double g_t1STP   = 0;   // T1 Short TP
double g_qty     = 1.0;

bool     g_eodFired  = false;
datetime g_today     = 0;
bool     g_diagDone  = false;   // diagnostic print once per day

// Break-Even
double g_beEntryPx = 0;   // entry price trade curent
double g_beRisk    = 0;   // risc initial (SL distance)
bool   g_beMoved   = false;
int    g_curDir    = 0;   // directia trade-ului curent (1=long, -1=short)

// ═══════════════════════════════════════════════════════════
//  INIT
// ═══════════════════════════════════════════════════════════
int OnInit() {
    g_trade.SetExpertMagicNumber(MAGIC);
    g_trade.SetDeviationInPoints(30);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {}

// ═══════════════════════════════════════════════════════════
//  HELPERS – timp
// ═══════════════════════════════════════════════════════════
datetime ROTime()   { return TimeCurrent() + i_tzOffset * 3600; }

void ROStruct(MqlDateTime &d) { TimeToStruct(ROTime(), d); }

// ═══════════════════════════════════════════════════════════
//  HELPERS – preturi
// ═══════════════════════════════════════════════════════════
double Norm(double price) {
    return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

// ═══════════════════════════════════════════════════════════
//  HELPERS – sizing
// ═══════════════════════════════════════════════════════════
double CalcQty(double slDist) {
    if (!i_autoSize) return MathMin(i_qtyFixed, i_maxLots);
    if (slDist <= 0 || i_pointValue <= 0) return 0.01;
    double exact  = i_riskUSD / (slDist * i_pointValue);
    double qtyUp  = MathCeil(exact   / 0.01) * 0.01;
    double qtyDn  = MathFloor(exact  / 0.01) * 0.01;
    double chosen = (qtyUp * slDist * i_pointValue <= i_riskUSD + i_riskMargin) ? qtyUp : qtyDn;
    return NormalizeDouble(MathMin(MathMax(0.01, chosen), i_maxLots), 2);
}

// ═══════════════════════════════════════════════════════════
//  HELPERS – pozitii / ordine
// ═══════════════════════════════════════════════════════════
// Returneaza ticket-ul primei pozitii al carei comment incepe cu pfx
ulong FindPos(const string pfx) {
    for (int i = PositionsTotal()-1; i >= 0; i--) {
        ulong t = PositionGetTicket(i);
        if (!t) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
        if ((int)PositionGetInteger(POSITION_MAGIC) != MAGIC) continue;
        if (StringFind(PositionGetString(POSITION_COMMENT), pfx) == 0)
            return t;
    }
    return 0;
}

void CloseAll(const string reason) {
    for (int i = PositionsTotal()-1; i >= 0; i--) {
        ulong t = PositionGetTicket(i);
        if (!t) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
        if ((int)PositionGetInteger(POSITION_MAGIC) != MAGIC) continue;
        if (!g_trade.PositionClose(t))
            PrintFormat("CloseAll[%s] ERR %d: %s", reason,
                        g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
    }
}

void CancelAll() {
    for (int i = OrdersTotal()-1; i >= 0; i--) {
        ulong t = OrderGetTicket(i);
        if (!t) continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if ((int)OrderGetInteger(ORDER_MAGIC) != MAGIC) continue;
        g_trade.OrderDelete(t);
    }
}

// ═══════════════════════════════════════════════════════════
//  HELPERS – detectie loss din ultimul deal inchis al zilei
// ═══════════════════════════════════════════════════════════
bool LastDealWasLoss() {
    HistorySelect(g_today, TimeCurrent() + 1);
    for (int i = HistoryDealsTotal()-1; i >= 0; i--) {
        ulong d = HistoryDealGetTicket(i);
        if (HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
        if ((int)HistoryDealGetInteger(d, DEAL_MAGIC) != MAGIC) continue;
        if (HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
        return HistoryDealGetInteger(d, DEAL_REASON) == DEAL_REASON_SL;
    }
    return false;
}

// ═══════════════════════════════════════════════════════════
//  HELPERS – range din bara M15 9:15 RO (o singura candela)
// ═══════════════════════════════════════════════════════════
bool GetRange(double &rH, double &rL) {
    rH = 0; rL = DBL_MAX;
    MqlDateTime todayRO;
    TimeToStruct(TimeCurrent() + i_tzOffset * 3600, todayRO);
    for (int i = 1; i <= 20; i++) {
        datetime bt = iTime(_Symbol, PERIOD_M15, i);
        if (!bt) continue;
        MqlDateTime d;
        TimeToStruct(bt + i_tzOffset * 3600, d);
        // bara trebuie sa fie din ziua curenta (exclude barele dinainte de GAP)
        if (d.day != todayRO.day || d.mon != todayRO.mon) break;
        if (d.hour == 9 && d.min == 15) {
            rH = iHigh(_Symbol, PERIOD_M15, i);
            rL = iLow(_Symbol, PERIOD_M15, i);
            return rH > 0 && rL < DBL_MAX / 2.0;
        }
        if (d.hour < 9) break;
    }
    return false;
}

// ═══════════════════════════════════════════════════════════
//  BREAK-EVEN
// ═══════════════════════════════════════════════════════════
void SetupBE(const string pfx) {
    ulong t = FindPos(pfx);
    if (!t) return;
    if (!PositionSelectByTicket(t)) return;
    g_beEntryPx = PositionGetDouble(POSITION_PRICE_OPEN);
    double sl   = PositionGetDouble(POSITION_SL);
    int    type = (int)PositionGetInteger(POSITION_TYPE);
    g_curDir    = (type == POSITION_TYPE_BUY) ? 1 : -1;
    g_beRisk    = (g_curDir == 1) ? g_beEntryPx - sl : sl - g_beEntryPx;
    g_beMoved   = false;
}

void CheckBE() {
    if (!i_beEnabled) return;
    if (g_phase != 2 && g_phase != 4 && g_phase != 6) return;

    string pfx = "";
    if      (g_phase == 2) pfx = (g_dir == 1) ? "T1L" : "T1S";
    else if (g_phase == 4) pfx = (g_dir == 1) ? "T2S" : "T2L";
    else if (g_phase == 6) pfx = (g_dir == 1) ? "T3L" : "T3S";

    if (g_beEntryPx == 0) SetupBE(pfx);   // prima initializare dupa entry
    if (g_beMoved || g_beRisk <= 0 || g_beEntryPx == 0) return;

    ulong ticket = FindPos(pfx);
    if (!ticket) return;

    double beLevel = (g_curDir == 1) ? g_beEntryPx + g_beRisk * i_beR
                                     : g_beEntryPx - g_beRisk * i_beR;
    double curPx   = (g_curDir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                     : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    if ((g_curDir == 1 && curPx < beLevel) || (g_curDir == -1 && curPx > beLevel)) return;

    if (!PositionSelectByTicket(ticket)) return;
    double curSL = PositionGetDouble(POSITION_SL);
    double newSL = Norm(g_beEntryPx);

    if ((g_curDir == 1 && newSL <= curSL) || (g_curDir == -1 && newSL >= curSL)) return;

    if (g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP))) {
        g_beMoved = true;
        PrintFormat("BE: SL mutat la entry %.2f  [target=%.2f  risk=%.2f  %.1fR]",
                    newSL, beLevel, g_beRisk, i_beR);
    } else {
        PrintFormat("BE ERR: %d %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
    }
}

// ═══════════════════════════════════════════════════════════
//  RESET ZI NOUA
// ═══════════════════════════════════════════════════════════
void ResetDay() {
    CloseAll("PREV DAY");
    CancelAll();
    g_phase    = 0;
    g_dir      = 0;
    g_rngH     = 0; g_rngL = 0;
    g_eodFired = false;
    g_diagDone = false;
    g_beEntryPx = 0; g_beRisk = 0; g_beMoved = false; g_curDir = 0;
    g_t2Confirmed = false; g_t3Confirmed = false;
    Print("Zi noua — stare resetata.");
}

// ═══════════════════════════════════════════════════════════
//  ON TICK
// ═══════════════════════════════════════════════════════════
void OnTick() {
    MqlDateTime dt;
    ROStruct(dt);

    // ── detectie zi noua ──────────────────────────────────
    datetime today = StringToTime(StringFormat("%04d.%02d.%02d",
                                               dt.year, dt.mon, dt.day));
    if (today != g_today) {
        if (g_today != 0) ResetDay();
        g_today = today;
    }

    // ── EOD ──────────────────────────────────────────────
    int roMins  = dt.hour * 60 + dt.min;
    int eodMins = i_eodH  * 60 + i_eodMin;
    bool eod    = roMins >= eodMins;

    if (eod && !g_eodFired && g_phase > 0 && g_phase < 9) {
        CancelAll();
        CloseAll("EOD");
        g_eodFired = true;
        g_phase    = 9;
        Print("EOD CLOSE");
        return;
    }
    if (g_phase == 9 || eod) return;

    CheckBE();

    // ════════════════════════════════════════════════════
    //  FAZA 0 → 1 : Plaseaza T1 la 9:30
    // ════════════════════════════════════════════════════
    if (g_phase == 0 && (dt.hour > 9 || (dt.hour == 9 && dt.min >= 30))) {

        // ── DIAGNOSTIC: afiseaza barele M15 si rezultatul GetRange (o data/zi) ──
        if (!g_diagDone) {
            g_diagDone = true;
            MqlDateTime todayDiag;
            TimeToStruct(TimeCurrent() + i_tzOffset * 3600, todayDiag);
            PrintFormat("DIAG [%02d:%02d %02d.%02d]: caut bara M15 9:15 ...",
                        dt.hour, dt.min, dt.day, dt.mon);
            for (int di = 1; di <= 8; di++) {
                datetime btt = iTime(_Symbol, PERIOD_M15, di);
                if (!btt) { PrintFormat("  bar[%d]: null — date M15 lipsa!", di); break; }
                MqlDateTime dd;
                TimeToStruct(btt + i_tzOffset * 3600, dd);
                PrintFormat("  bar[%d]: %04d.%02d.%02d %02d:%02d  (H=%.1f L=%.1f)",
                            di, dd.year, dd.mon, dd.day, dd.hour, dd.min,
                            iHigh(_Symbol, PERIOD_M15, di), iLow(_Symbol, PERIOD_M15, di));
                if (dd.day != todayDiag.day || dd.mon != todayDiag.mon) { Print("  → alta zi, opresc"); break; }
                if (dd.hour < 9) { Print("  → sub 9h, opresc"); break; }
            }
            double diagH, diagL;
            if (GetRange(diagH, diagL))
                PrintFormat("DIAG: GetRange OK → H=%.1f  L=%.1f", diagH, diagL);
            else
                Print("DIAG: GetRange ESUAT — bara 9:15 negasita in barele de mai sus!");
        }

        double rH, rL;
        if (!GetRange(rH, rL)) return;

        g_rngH  = rH; g_rngL = rL;
        g_t1BS  = Norm(rH + i_offset);
        g_t1SS  = Norm(rL - i_offset);
        double risk = g_t1BS - g_t1SS;
        g_t1LSL = Norm(g_t1SS);
        g_t1LTP = Norm(g_t1BS + risk * i_tpR);
        g_t1SSL = Norm(g_t1BS);
        g_t1STP = Norm(g_t1SS - risk * i_tpR);
        g_qty   = CalcQty(risk);

        if (!g_trade.BuyStop (g_qty, g_t1BS, _Symbol, g_t1LSL, g_t1LTP,
                              ORDER_TIME_GTC, 0, "T1L") ||
            !g_trade.SellStop(g_qty, g_t1SS, _Symbol, g_t1SSL, g_t1STP,
                              ORDER_TIME_GTC, 0, "T1S")) {
            PrintFormat("T1 order ERR: %d %s",
                        g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
            return;
        }
        g_phase = 1;
        PrintFormat("T1 plasate: BS=%.1f SS=%.1f qty=%.2f risk=%.1f pts",
                    g_t1BS, g_t1SS, g_qty, risk);
        return;
    }

    // ════════════════════════════════════════════════════
    //  FAZA 1 : Detecteaza umplere T1
    // ════════════════════════════════════════════════════
    if (g_phase == 1) {
        if (FindPos("T1L") != 0) {
            g_dir = 1;
            CancelAll();   // anuleaza T1S pending
            g_phase = 2;
            g_beEntryPx = 0; g_beRisk = 0; g_beMoved = false;
            Print("T1 Long umplut — faza 2");
        } else if (FindPos("T1S") != 0) {
            g_dir = -1;
            CancelAll();   // anuleaza T1L pending
            g_phase = 2;
            g_beEntryPx = 0; g_beRisk = 0; g_beMoved = false;
            Print("T1 Short umplut — faza 2");
        }
        return;
    }

    // ════════════════════════════════════════════════════
    //  FAZA 2 : T1 activ → detecteaza inchidere
    // ════════════════════════════════════════════════════
    if (g_phase == 2) {
        string pfx = (g_dir == 1) ? "T1L" : "T1S";
        if (FindPos(pfx) != 0) return;   // inca deschis

        // T1 s-a inchis
        if (!LastDealWasLoss()) {
            g_phase = 9;
            Print("T1 TP → sesiune done");
        } else {
            // T1 SL hit → T2 in directie opusa, IMEDIAT
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            bool ok;
            if (g_dir == 1) {   // T1 Long SL → T2 Short
                ok = g_trade.Sell(g_qty, _Symbol, bid, g_t1SSL, g_t1STP, "T2S");
                PrintFormat("T2 Short plasat: bid=%.1f SL=%.1f TP=%.1f", bid, g_t1SSL, g_t1STP);
            } else {            // T1 Short SL → T2 Long
                ok = g_trade.Buy(g_qty, _Symbol, ask, g_t1LSL, g_t1LTP, "T2L");
                PrintFormat("T2 Long plasat: ask=%.1f SL=%.1f TP=%.1f", ask, g_t1LSL, g_t1LTP);
            }
            if (!ok) PrintFormat("T2 ERR: %d %s",
                                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
            g_t2Confirmed = false;
            g_phase = 4;
            g_beEntryPx = 0; g_beRisk = 0; g_beMoved = false;
        }
        return;
    }

    // ════════════════════════════════════════════════════
    //  FAZA 4 : T2 activ → detecteaza inchidere
    // ════════════════════════════════════════════════════
    if (g_phase == 4) {
        string pfx = (g_dir == 1) ? "T2S" : "T2L";
        if (FindPos(pfx) != 0) { g_t2Confirmed = true; return; }   // inca deschis
        if (!g_t2Confirmed) return;   // race-condition: T2 nu e inca confirmat deschis

        if (!LastDealWasLoss()) {
            g_phase = 9;
            Print("T2 TP → sesiune done");
        } else {
            // T2 SL hit → T3 in directie opusa T2 (= aceeasi ca T1)
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            bool ok;
            if (g_dir == 1) {   // T1 Long, T2 Short SL → T3 Long
                ok = g_trade.Buy(g_qty, _Symbol, ask, g_t1LSL, g_t1LTP, "T3L");
                PrintFormat("T3 Long plasat: ask=%.1f SL=%.1f TP=%.1f", ask, g_t1LSL, g_t1LTP);
            } else {            // T1 Short, T2 Long SL → T3 Short
                ok = g_trade.Sell(g_qty, _Symbol, bid, g_t1SSL, g_t1STP, "T3S");
                PrintFormat("T3 Short plasat: bid=%.1f SL=%.1f TP=%.1f", bid, g_t1SSL, g_t1STP);
            }
            if (!ok) PrintFormat("T3 ERR: %d %s",
                                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
            g_t3Confirmed = false;
            g_phase = 6;
            g_beEntryPx = 0; g_beRisk = 0; g_beMoved = false;
        }
        return;
    }

    // ════════════════════════════════════════════════════
    //  FAZA 6 : T3 activ → detecteaza inchidere
    // ════════════════════════════════════════════════════
    if (g_phase == 6) {
        string pfx = (g_dir == 1) ? "T3L" : "T3S";
        if (FindPos(pfx) != 0) { g_t3Confirmed = true; return; }   // inca deschis
        if (!g_t3Confirmed) return;   // race-condition: T3 nu e inca confirmat deschis
        g_phase = 9;
        Print("T3 inchis → sesiune done");
    }
}
