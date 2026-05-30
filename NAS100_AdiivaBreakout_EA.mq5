//+------------------------------------------------------------------+
//|  NAS100_AdiivaBreakout_EA.mq5                                    |
//|  Adiiva Breakout NAS100 — max 2 trades/zi (M5)                  |
//|  Echivalent cu NAS100_AdiivaBreakout_5min.pine                   |
//+------------------------------------------------------------------+
//
//  LOGICA:
//  1. R1 = H/L fereastra 9:30-9:45 ET
//  2. Prima bara care inchide in afara R1  → R2 (H/L bara respective)
//  3. Bara care inchide in afara R2        → Trade 1 (market, SL opus R2, TP=1R)
//  4. Daca T1 SL hit → R3 = H/L bara SL  → Trade 2 (aceeasi logica)
//  5. EOD la 16:00 ET → close all
//
#property copyright ""
#property version   "1.00"
#include <Trade\Trade.mqh>

// ═══════════════════════════════════════════════════════════
//  INPUTS
// ═══════════════════════════════════════════════════════════
input group "═══ Strategie ═══"
input double i_slBuf   = 0.0;   // SL Buffer (puncte)
input double i_tpR     = 1.0;   // TP Ratio (R)
input int    i_rsH     = 9;     // Range Start Hour (ET)
input int    i_rsM     = 30;    // Range Start Min (ET)
input int    i_reH     = 9;     // Range End Hour (ET)
input int    i_reM     = 45;    // Range End Min (ET)
input int    i_eeH     = 11;    // Entry cutoff Hour (ET)
input int    i_eeM     = 0;     // Entry cutoff Min (ET)
input int    i_eodH    = 16;    // EOD Hour (ET)
input int    i_eodM    = 0;     // EOD Min (ET)
input int    i_etOff   = -7;    // Offset server→ET (ore; server UTC+3, ET UTC-4 → -7)

input group "═══ Sizing ═══"
input double i_riskUSD = 100.0; // Risc $ per trade
input double i_maxLots = 5.0;   // Loturi maxime
input double i_ptVal   = 10.0;  // Valoare punct $/lot (NAS100: 10)

// ═══════════════════════════════════════════════════════════
//  CONSTANTE & STARE GLOBALA
// ═══════════════════════════════════════════════════════════
#define MAGIC 10015

CTrade g_trade;

// Faze: 0=astept R1, 1=R1 gata astept R2, 2=R2 gata astept entry,
//       3=trade1 activ, 4=SL1 hit astept entry T2, 5=trade2 activ, 6=done
int    g_phase   = 0;
int    g_dir     = 0;    // 1=long, -1=short

double g_r1H     = 0;
double g_r1L     = 0;
bool   g_r1Done  = false;

double g_actRH   = 0;   // range activ (R2 sau R3)
double g_actRL   = 0;

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

bool LastDealWasLoss() {
    HistorySelect(g_today, TimeCurrent() + 1);
    for (int i = HistoryDealsTotal()-1; i >= 0; i--) {
        ulong d = HistoryDealGetTicket(i);
        if (HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
        if ((int)HistoryDealGetInteger(d, DEAL_MAGIC) != MAGIC) continue;
        if (HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_OUT)
            return HistoryDealGetDouble(d, DEAL_PROFIT) < 0;
    }
    return false;
}

void ResetDay() {
    CloseAll("NEW DAY");
    g_phase    = 0;
    g_dir      = 0;
    g_r1H      = 0; g_r1L     = 0; g_r1Done = false;
    g_actRH    = 0; g_actRL   = 0;
    g_eodFired = false;
    Print("Zi noua — stare resetata.");
}

// ═══════════════════════════════════════════════════════════
//  PROCESEAZA LA INCHIDEREA FIECAREI BARE M5
// ═══════════════════════════════════════════════════════════
void ProcessBarClose() {
    double barH = iHigh (_Symbol, PERIOD_M5, 1);
    double barL = iLow  (_Symbol, PERIOD_M5, 1);
    double barC = iClose(_Symbol, PERIOD_M5, 1);
    datetime barT = iTime(_Symbol, PERIOD_M5, 1);

    MqlDateTime dt;
    TimeToStruct(barT + i_etOff * 3600, dt);
    int etMins  = dt.hour * 60 + dt.min;
    int rsMins  = i_rsH * 60 + i_rsM;
    int reMins  = i_reH * 60 + i_reM;
    int eeMins  = i_eeH * 60 + i_eeM;
    int eodMins = i_eodH * 60 + i_eodM;

    bool inRange      = etMins >= rsMins && etMins < reMins;
    bool entryAllowed = etMins >= reMins && etMins < eeMins;

    //--- Capturare R1
    if (inRange && g_phase == 0) {
        g_r1H = (g_r1H == 0) ? barH : MathMax(g_r1H, barH);
        g_r1L = (g_r1L == 0) ? barL : MathMin(g_r1L, barL);
    }

    //--- R1 tocmai s-a terminat
    if (!g_r1Done && g_r1H > 0 && etMins >= reMins && etMins < eodMins && g_phase == 0) {
        g_r1Done = true;
        g_phase  = 1;
        PrintFormat("R1 gata: H=%.2f L=%.2f  [bara ET %02d:%02d]",
                    g_r1H, g_r1L, dt.hour, dt.min);
    }

    //--- Faza 1: prima bara care inchide in afara R1 → H/L ei = R2
    if (g_phase == 1 && entryAllowed && g_r1H > 0) {
        if (barC > g_r1H || barC < g_r1L) {
            g_actRH = barH;
            g_actRL = barL;
            g_phase = 2;
            PrintFormat("R2 format: H=%.2f L=%.2f  (%s R1)  [bara ET %02d:%02d]",
                        g_actRH, g_actRL, barC > g_r1H ? "deasupra" : "sub", dt.hour, dt.min);
        }
    }

    //--- Faza 2 sau 4: bara care inchide in afara range activ → entry
    if ((g_phase == 2 || g_phase == 4) && entryAllowed && g_actRH > 0) {
        if (barC > g_actRH) {
            double sl      = Norm(g_actRL - i_slBuf);
            double riskPts = barC - sl;
            double lots    = CalcLots(riskPts);
            if (lots >= 0.01) {
                double tp  = Norm(barC + riskPts * i_tpR);
                double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                g_dir = 1;
                if (!g_trade.Buy(lots, _Symbol, ask, sl, tp, "NY Long"))
                    PrintFormat("Buy ERR %d: %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
                else
                    PrintFormat("T%d Long: lots=%.2f ask=%.2f SL=%.2f TP=%.2f  [ET %02d:%02d]",
                                g_phase == 2 ? 1 : 2, lots, ask, sl, tp, dt.hour, dt.min);
                g_phase = (g_phase == 2) ? 3 : 5;
            }
        } else if (barC < g_actRL) {
            double sl      = Norm(g_actRH + i_slBuf);
            double riskPts = sl - barC;
            double lots    = CalcLots(riskPts);
            if (lots >= 0.01) {
                double tp  = Norm(barC - riskPts * i_tpR);
                double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                g_dir = -1;
                if (!g_trade.Sell(lots, _Symbol, bid, sl, tp, "NY Short"))
                    PrintFormat("Sell ERR %d: %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
                else
                    PrintFormat("T%d Short: lots=%.2f bid=%.2f SL=%.2f TP=%.2f  [ET %02d:%02d]",
                                g_phase == 2 ? 1 : 2, lots, bid, sl, tp, dt.hour, dt.min);
                g_phase = (g_phase == 2) ? 3 : 5;
            }
        }
    }

    //--- Faza 3: Trade 1 activ → detecteaza inchidere
    if (g_phase == 3) {
        string pfx = (g_dir == 1) ? "NY Long" : "NY Short";
        if (FindPos(pfx) == 0) {
            if (LastDealWasLoss()) {
                // SL hit → R3 = H/L bara pe care s-a inchis
                g_actRH = barH;
                g_actRL = barL;
                g_phase = 4;
                PrintFormat("T1 SL hit — R3: H=%.2f L=%.2f  [ET %02d:%02d]",
                            g_actRH, g_actRL, dt.hour, dt.min);
            } else {
                g_phase = 6;
                Print("T1 TP → sesiune done");
            }
        }
    }

    //--- Faza 5: Trade 2 → sesiune done indiferent de rezultat
    if (g_phase == 5) {
        string pfx = (g_dir == 1) ? "NY Long" : "NY Short";
        if (FindPos(pfx) == 0) {
            g_phase = 6;
            PrintFormat("T2 inchis → sesiune done  [ET %02d:%02d]", dt.hour, dt.min);
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  ON TICK
// ═══════════════════════════════════════════════════════════
void OnTick() {
    //--- detectie zi noua (ET)
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

    //--- EOD
    if (eod && !g_eodFired && g_phase > 0 && g_phase < 6) {
        CloseAll("EOD");
        g_eodFired = true;
        g_phase    = 6;
        Print("EOD CLOSE");
        return;
    }
    if (g_phase == 6 || eod) return;

    //--- proceseaza la fiecare bara M5 noua
    datetime currentBar = iTime(_Symbol, PERIOD_M5, 0);
    if (currentBar == g_lastBar || currentBar == 0) return;
    g_lastBar = currentBar;

    ProcessBarClose();
}
