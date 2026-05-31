//+------------------------------------------------------------------+
//|  NAS100_AVEMRange_EA.mq5                                         |
//|  AVEM Range NAS100 — 1 trade/zi (M1)                            |
//|  Echivalent cu AVEM_RangeBreakout.pine                           |
//+------------------------------------------------------------------+
//
//  LOGICA:
//  1. Range + Volume Profile (VAH/POC/VAL) din intervalul 9:30-9:45 ET
//  2. Prima bara M1 care inchide AFARA range → Breakout detectat
//  3. Prima bara M1 care inchide INAPOI in range → Entry (Re-Test)
//     - Breakout sus  → Long  (SL sub VAL / waitLow)
//     - Breakout jos  → Short (SL deasupra VAH / waitHigh)
//  4. TP = 1R, 1 trade/zi, EOD 16:00 ET
//
#property copyright ""
#property version   "1.00"
#include <Trade\Trade.mqh>

// ═══════════════════════════════════════════════════════════
//  INPUTS
// ═══════════════════════════════════════════════════════════
input group "═══ Strategie ═══"
input double i_slBuf    = 0.0;   // SL Buffer (puncte)
input double i_tpR      = 1.0;   // TP Ratio (R)
input int    i_rsH      = 9;     // Range Start Hour (ET)
input int    i_rsM      = 30;    // Range Start Min (ET)
input int    i_reH      = 9;     // Range End Hour (ET)
input int    i_reM      = 45;    // Range End Min (ET)
input int    i_eeH      = 11;    // Entry cutoff Hour (ET)
input int    i_eeM      = 0;     // Entry cutoff Min (ET)
input int    i_eodH     = 16;    // EOD Hour (ET)
input int    i_eodM     = 0;     // EOD Min (ET)
input int    i_etOff    = -7;    // Offset server→ET (server UTC+3, ET UTC-4 → -7)

input group "═══ Volume Profile ═══"
input int    i_ticksRow = 10;    // Ticks per row (NQ: 10)
input double i_tickSz   = 0.25;  // Tick size (NQ: 0.25 puncte)
input double i_vaPct    = 68.0;  // Value Area %

input group "═══ Sizing ═══"
input double i_riskUSD  = 100.0; // Risc $ per trade
input double i_maxLots  = 5.0;   // Loturi maxime
input double i_ptVal    = 10.0;  // Valoare punct $/lot (NAS100: 10)

// ═══════════════════════════════════════════════════════════
//  CONSTANTE & STARE
// ═══════════════════════════════════════════════════════════
#define MAGIC 10016

CTrade g_trade;

// Range
double g_rH = 0, g_rL = 0;
bool   g_rangeBuilt = false;

// Volume Profile
double g_poc = 0, g_vah = 0, g_val = 0;
bool   g_vpOk = false;

// Colectie bare M1 din range (pentru VP)
double g_vpH[], g_vpL[], g_vpV[];
int    g_vpN = 0;

// State machine: 0=astept breakout, 1=brkUp, 2=brkDn
int  g_state     = 0;
bool g_tradeDone = false;

// Dynamic SL tracking
double g_waitLow  = 0;   // 0 = nesetat
double g_waitHigh = 0;   // 0 = nesetat

bool     g_eodFired = false;
datetime g_today    = 0;
datetime g_lastBar  = 0;

// ═══════════════════════════════════════════════════════════
//  INIT
// ═══════════════════════════════════════════════════════════
int OnInit() {
    g_trade.SetExpertMagicNumber(MAGIC);
    g_trade.SetDeviationInPoints(30);
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);
    ArrayResize(g_vpH, 0);
    ArrayResize(g_vpL, 0);
    ArrayResize(g_vpV, 0);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {}

// ═══════════════════════════════════════════════════════════
//  HELPERS – timp
// ═══════════════════════════════════════════════════════════
datetime ETTime() { return TimeCurrent() + i_etOff * 3600; }

double Norm(double price) {
    return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

// ═══════════════════════════════════════════════════════════
//  HELPERS – sizing
// ═══════════════════════════════════════════════════════════
double CalcLots(double riskPts) {
    if (riskPts <= 0) return 0;
    double lots = i_riskUSD / (riskPts * i_ptVal);
    lots = MathMax(0.01, MathFloor(lots * 100) / 100.0);
    return MathMin(lots, i_maxLots);
}

// ═══════════════════════════════════════════════════════════
//  HELPERS – pozitii
// ═══════════════════════════════════════════════════════════
ulong FindPos(const string pfx) {
    for (int i = PositionsTotal()-1; i >= 0; i--) {
        ulong t = PositionGetTicket(i);
        if (!t) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
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
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if ((int)PositionGetInteger(POSITION_MAGIC) != MAGIC) continue;
        if (!g_trade.PositionClose(t))
            PrintFormat("CloseAll[%s] ERR %d", reason, g_trade.ResultRetcode());
    }
}

// ═══════════════════════════════════════════════════════════
//  VOLUME PROFILE
// ═══════════════════════════════════════════════════════════
void CalcVP() {
    if (g_vpN == 0 || g_rH <= g_rL) return;

    double rowSize  = i_ticksRow * i_tickSz;
    double gridBase = MathFloor(g_rL / rowSize) * rowSize;
    int    rows     = MathMax(2, (int)MathCeil((g_rH - gridBase) / rowSize));

    double volBins[];
    ArrayResize(volBins, rows);
    ArrayInitialize(volBins, 0.0);

    for (int i = 0; i < g_vpN; i++) {
        double bH = MathMin(g_vpH[i], g_rH);
        double bL = MathMax(g_vpL[i], g_rL);
        double bV = g_vpV[i];
        if (bH <= bL) continue;
        int loBin = MathMax(0, MathMin(rows-1, (int)MathFloor((bL - gridBase) / rowSize)));
        int hiBin = MathMax(0, MathMin(rows-1, (int)MathFloor((bH - gridBase) / rowSize)));
        double vpp = bV / (hiBin - loBin + 1);
        for (int b = loBin; b <= hiBin; b++)
            volBins[b] += vpp;
    }

    // POC
    double maxVol = 0;
    int    pocBin = 0;
    for (int b = 0; b < rows; b++) {
        if (volBins[b] > maxVol) { maxVol = volBins[b]; pocBin = b; }
    }
    g_poc = gridBase + (pocBin + 0.5) * rowSize;

    // Value Area
    double totalVol = 0;
    for (int b = 0; b < rows; b++) totalVol += volBins[b];
    double vaTarget = totalVol * i_vaPct / 100.0;

    int    vaLo  = pocBin, vaHi = pocBin;
    double vaVol = maxVol;
    for (int _i = 0; _i < rows; _i++) {
        if (vaVol >= vaTarget || (vaHi >= rows-1 && vaLo <= 0)) break;
        double addUp = (vaHi < rows-1) ? volBins[vaHi+1] : 0.0;
        double addDn = (vaLo > 0)      ? volBins[vaLo-1] : 0.0;
        if (addUp >= addDn) { vaHi++; vaVol += addUp; }
        else                { vaLo--; vaVol += addDn; }
    }
    g_vah  = gridBase + (vaHi + 1) * rowSize;
    g_val  = gridBase + vaLo * rowSize;
    g_vpOk = true;

    PrintFormat("VP: POC=%.2f  VAH=%.2f  VAL=%.2f  (rows=%d  rowSz=%.2f  bars=%d)",
                g_poc, g_vah, g_val, rows, rowSize, g_vpN);
}

// ═══════════════════════════════════════════════════════════
//  SL CALCULATION
// ═══════════════════════════════════════════════════════════
double SlLong(double ref) {
    double sl;
    // Prioritate: waitLow < VAL < RL
    if (g_waitLow > 0)
        sl = g_waitLow - i_slBuf;
    else if (g_vpOk)
        sl = g_val - i_slBuf;
    else
        sl = g_rL - i_slBuf;

    // Garanteaza SL <= VAL
    if (g_vpOk) sl = MathMin(sl, g_val - i_slBuf);

    // Garda: SL trebuie sa fie sub ref
    if (sl >= ref) sl = g_rL - i_slBuf;
    if (sl >= ref) sl = ref - 10.0 * i_tickSz;

    return Norm(sl);
}

double SlShort(double ref) {
    double sl;
    // Prioritate: waitHigh > VAH > RH
    if (g_waitHigh > 0)
        sl = g_waitHigh + i_slBuf;
    else if (g_vpOk)
        sl = g_vah + i_slBuf;
    else
        sl = g_rH + i_slBuf;

    // Garanteaza SL >= VAH
    if (g_vpOk) sl = MathMax(sl, g_vah + i_slBuf);

    // Garda: SL trebuie sa fie deasupra ref
    if (sl <= ref) sl = g_rH + i_slBuf;
    if (sl <= ref) sl = ref + 10.0 * i_tickSz;

    return Norm(sl);
}

// ═══════════════════════════════════════════════════════════
//  RESET ZI NOUA
// ═══════════════════════════════════════════════════════════
void ResetDay() {
    CloseAll("NEW DAY");
    g_rH = 0; g_rL = 0; g_rangeBuilt = false;
    g_poc = 0; g_vah = 0; g_val = 0; g_vpOk = false;
    g_vpN = 0;
    ArrayResize(g_vpH, 0);
    ArrayResize(g_vpL, 0);
    ArrayResize(g_vpV, 0);
    g_state     = 0;
    g_tradeDone = false;
    g_waitLow   = 0;
    g_waitHigh  = 0;
    g_eodFired  = false;
    Print("Zi noua — stare resetata.");
}

// ═══════════════════════════════════════════════════════════
//  PROCESEAZA LA INCHIDEREA FIECAREI BARE M1
// ═══════════════════════════════════════════════════════════
void ProcessBarClose() {
    double   barH = iHigh (_Symbol, PERIOD_M1, 1);
    double   barL = iLow  (_Symbol, PERIOD_M1, 1);
    double   barC = iClose(_Symbol, PERIOD_M1, 1);
    long     barV = iVolume(_Symbol, PERIOD_M1, 1);
    datetime barT = iTime (_Symbol, PERIOD_M1, 1);

    MqlDateTime dt;
    TimeToStruct(barT + i_etOff * 3600, dt);
    int etMins  = dt.hour * 60 + dt.min;
    int rsMins  = i_rsH * 60 + i_rsM;
    int reMins  = i_reH * 60 + i_reM;
    int eeMins  = i_eeH * 60 + i_eeM;
    int eodMins = i_eodH * 60 + i_eodM;

    bool inRange      = etMins >= rsMins && etMins < reMins;
    bool tradeActive  = etMins > reMins  && etMins < eodMins;
    bool entryAllowed = tradeActive && etMins < eeMins;

    // ── Colectare bare in range pentru VP ─────────────────
    if (inRange) {
        g_rH = (g_rH == 0) ? barH : MathMax(g_rH, barH);
        g_rL = (g_rL == 0) ? barL : MathMin(g_rL, barL);
        g_vpN++;
        ArrayResize(g_vpH, g_vpN);
        ArrayResize(g_vpL, g_vpN);
        ArrayResize(g_vpV, g_vpN);
        g_vpH[g_vpN-1] = barH;
        g_vpL[g_vpN-1] = barL;
        // volum tick; fallback la range bara daca volum 0
        g_vpV[g_vpN-1] = (barV > 0) ? (double)barV : (barH - barL > 0 ? barH - barL : i_tickSz);
    }

    // ── Calcul VP la finalul range-ului (o singura data) ──
    if (!g_rangeBuilt && g_rH > 0 && tradeActive) {
        g_rangeBuilt = true;
        CalcVP();
        PrintFormat("Range gata: H=%.2f  L=%.2f  [ET %02d:%02d]",
                    g_rH, g_rL, dt.hour, dt.min);
    }

    if (!g_rangeBuilt || g_tradeDone) return;

    // ── Detectie Breakout ─────────────────────────────────
    if (g_state == 0 && entryAllowed) {
        if (barC > g_rH) {
            g_state = 1;
            PrintFormat("Breakout UP: close=%.2f > RH=%.2f  [ET %02d:%02d]",
                        barC, g_rH, dt.hour, dt.min);
        } else if (barC < g_rL) {
            g_state = 2;
            PrintFormat("Breakout DN: close=%.2f < RL=%.2f  [ET %02d:%02d]",
                        barC, g_rL, dt.hour, dt.min);
        }
    }

    // ── Dynamic SL tracking (in asteptarea retestului) ────
    // Long: cel mai mic low sub VAL (indiferent daca e sub RL)
    if (g_state == 1 && g_vpOk && tradeActive) {
        if (barL < g_val)
            g_waitLow = (g_waitLow == 0) ? barL : MathMin(g_waitLow, barL);
    }
    // Short: cel mai mare high peste VAH (inclusiv wicks peste RH)
    if (g_state == 2 && g_vpOk && tradeActive) {
        if (barH > g_vah)
            g_waitHigh = (g_waitHigh == 0) ? barH : MathMax(g_waitHigh, barH);
    }

    // ── Retest + Entry ────────────────────────────────────
    bool retestL = (g_state == 1) && entryAllowed && barC >= g_rL && barC <= g_rH;
    bool retestS = (g_state == 2) && entryAllowed && barC >= g_rL && barC <= g_rH;

    if (retestL) {
        double sl      = SlLong(barC);
        double riskPts = barC - sl;
        double lots    = CalcLots(riskPts);
        if (lots >= 0.01) {
            double tp  = Norm(barC + riskPts * i_tpR);
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            if (!g_trade.Buy(lots, _Symbol, ask, sl, tp, "NY Long"))
                PrintFormat("Buy ERR %d: %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
            else {
                PrintFormat("NY RT Long: lots=%.2f ask=%.2f SL=%.2f TP=%.2f  [ET %02d:%02d]",
                            lots, ask, sl, tp, dt.hour, dt.min);
                g_tradeDone = true;
                g_state     = 0;
            }
        }
    } else if (retestS) {
        double sl      = SlShort(barC);
        double riskPts = sl - barC;
        double lots    = CalcLots(riskPts);
        if (lots >= 0.01) {
            double tp  = Norm(barC - riskPts * i_tpR);
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            if (!g_trade.Sell(lots, _Symbol, bid, sl, tp, "NY Short"))
                PrintFormat("Sell ERR %d: %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
            else {
                PrintFormat("NY RT Short: lots=%.2f bid=%.2f SL=%.2f TP=%.2f  [ET %02d:%02d]",
                            lots, bid, sl, tp, dt.hour, dt.min);
                g_tradeDone = true;
                g_state     = 0;
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  ON TICK
// ═══════════════════════════════════════════════════════════
void OnTick() {
    MqlDateTime dt;
    TimeToStruct(ETTime(), dt);
    datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));

    if (today != g_today) {
        if (g_today != 0) ResetDay();
        g_today = today;
    }

    int etMins  = dt.hour * 60 + dt.min;
    int eodMins = i_eodH * 60 + i_eodM;
    bool eod    = etMins >= eodMins;

    if (eod && !g_eodFired) {
        CloseAll("EOD");
        g_eodFired  = true;
        g_tradeDone = true;
        Print("EOD CLOSE");
        return;
    }
    if (eod) return;

    // proceseaza la fiecare bara M1 noua
    datetime currentBar = iTime(_Symbol, PERIOD_M1, 0);
    if (currentBar == g_lastBar || currentBar == 0) return;
    g_lastBar = currentBar;

    ProcessBarClose();
}
