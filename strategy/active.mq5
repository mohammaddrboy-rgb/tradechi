//+------------------------------------------------------------------+
//|              SignalBot_MultiIndicator_MT5.mq5  v6.16             |
//|  INSTITUTIONAL EDITION + TRADE MGR + MACRO-RISK + SAFETY LAYER   |
//|  + VOLATILITY AUTO-CLOSE + CHART IMAGE ATTACHMENT                |
//|                                                                  |
//|  v6.16 NEW — every full BUY/SELL signal is now accompanied by a  |
//|  chart screenshot showing Entry/SL/TP1/TP2/TP3 as horizontal     |
//|  lines with labels, sent to the SAME Telegram chat right after   |
//|  the existing text message. The text message itself is           |
//|  UNCHANGED — this is a separate, additional photo post, not a    |
//|  modification of the signal format.                              |
//|                                                                  |
//|  HOW IT WORKS                                                    |
//|   1. DrawSignalChart() draws 5 horizontal lines (Entry/SL/TP1-3) |
//|      on THIS chart, each with a colored screen-anchored label     |
//|      positioned at the line's actual pixel height (via           |
//|      ChartTimePriceToXY), and clears the previous signal's lines  |
//|      first so they don't stack up over time.                    |
//|   2. CaptureChartScreenshot() calls MT5's native ChartScreenShot() |
//|      to save a PNG of the current chart to MQL5/Files.           |
//|   3. SendTelegramPhoto() reads that file and POSTs it to          |
//|      Telegram's sendPhoto endpoint using a hand-built             |
//|      multipart/form-data body (WebRequest doesn't have a built-in |
//|      file-upload helper, so this is constructed manually — a      |
//|      well-established MQL5 pattern for this exact purpose).       |
//|                                                                  |
//|  NO NEW URL WHITELISTING NEEDED — sendPhoto is the same           |
//|  api.telegram.org domain your text messages already use.         |
//|                                                                  |
//|  SCOPE: only the full trade signal (BUY/SELL) message gets an     |
//|  image. Startup messages, WATCH heads-ups, Golden/Death Cross,    |
//|  Crisis/Spike/Breaking-News alerts do not — they have no          |
//|  SL/TP levels to plot.                                           |
//|                                                                  |
//|  TEST ON DEMO FIRST — screenshot capture and multipart file       |
//|  upload are more environment-sensitive than pure text/logic       |
//|  features (chart panel size, terminal permissions, etc.).        |
//|                                                                  |
//|  Every other v6.0–v6.15 strategy behavior is UNCHANGED.           |
//|                                                                  |
//|  SETUP                                                           |
//|   Tools > Options > Expert Advisors > Allow WebRequest           |
//|   Add: https://api.telegram.org                                  |
//|   Add: https://localhost:5005  (Facebook signal server)          |
//|   Add your breaking-news endpoint's domain if using that feature.|
//|   Check "Allow live trading" for the Trade Manager AND the        |
//|   Volatility Auto-Close feature.                                 |
//+------------------------------------------------------------------+
#property copyright "SignalBot v6.16"
#property version   "6.16"
#property strict

//─────────────────────────── INPUTS ────────────────────────────────

// Telegram
input string  InpBotToken              = "8645295769:AAFNKoOjTjIqb7B9mEQ9jXZ61gswIXTFBWw";
input string  InpChatID                = "-1003939765500";
input bool    InpSendStartupMessage    = true;

// Bias MAs
input int     InpWeeklyEMA             = 21;
input int     InpDailyMA               = 200;
input int     InpCrossFastMA           = 50;
input int     InpCrossSlowMA           = 200;
input bool    InpAlertGoldenDeathCross = true;

// Structure H1
input int     InpH1EMA                 = 50;
input int     InpSwingLookback         = 60;
input int     InpFractalWing           = 4;    // v6.1: was 2 — requires real structure, not noise

// M15 triggers
input int     InpRSIPeriod             = 14;
input int     InpRSIOversold           = 32;
input int     InpRSIOverbought         = 68;
input int     InpMACDFast              = 12;
input int     InpMACDSlow              = 26;
input int     InpMACDSignalP           = 9;
input double  InpVolumeMultiplier      = 1.4;

// M5 scalp
input int     InpM5EMAFast             = 8;
input int     InpM5EMASlow             = 21;
input int     InpM5RSIPeriod           = 9;
input int     InpM5RSIOversold         = 35;
input int     InpM5RSIOverbought       = 65;

// Risk / SL / TP
input int     InpATRPeriod             = 14;
input double  InpSLATRMult             = 1.2;   // fallback SL if no fractal found
input double  InpMinSLATRMult          = 1.0;   // v6.1 NEW — SL can never be tighter than this × ATR
input double  InpRRRatio               = 2.0;   // TP2 = entry ± SL_dist × RR
input double  InpTP1Ratio              = 1.0;   // TP1 = entry ± SL_dist × TP1
input double  InpTP3Ratio              = 3.0;   // TP3 for remainder after TP2

// Signal filter
input int     InpMinScore              = 14;    // v6.14: was 12 (52% of the new /23 max after v6.13 added 3 points).
                                                  // 14/23 = 61% restores the original v6.1 intent (12/20 = 60%,
                                                  // deliberately stricter than v5's 41.7%). Rationale: HTF alignment
                                                  // alone caps at 5, so 14 forces real institutional structure
                                                  // (BOS/OB/FVG) AND entry precision (sweep/KZ/AMD/div) to also be
                                                  // present — not just a trending bias with weak confirmation.
input bool    InpAlertFullSignal       = true;
input int     InpCooldownBars          = 2;
input bool    InpShowWatchSignals      = true;

// AMD
input bool    InpAMDEnable             = true;
input int     InpAMDAccumBars          = 20;
input double  InpAMDATRRatio           = 0.6;
input double  InpAMDWickRatio          = 0.6;

// ADX Regime Filter
input bool    InpADXEnable             = true;
input int     InpADXPeriod             = 14;
input int     InpADXMinTrend           = 22;

// Session Filter (kept as broad gate — Kill Zone handles precision inside)
input bool    InpSessionEnable         = true;
input int     InpSessionStartHour      = 7;
input int     InpSessionEndHour        = 20;

// ── NEW 1: Kill Zone Filter ─────────────────────────────────────────
input bool    InpKillZoneEnable        = true;
// London Kill Zone
input int     InpLKZ_Start             = 7;     // 07:00 UTC
input int     InpLKZ_End               = 9;     // 09:00 UTC
// New York Kill Zone
input int     InpNYKZ_Start            = 12;    // 12:00 UTC
input int     InpNYKZ_End              = 14;    // 14:00 UTC
// London Close Kill Zone
input int     InpLCKZ_Start            = 15;    // 15:00 UTC
input int     InpLCKZ_End              = 16;    // 16:00 UTC

// Spread Filter
input bool    InpSpreadEnable          = true;
input int     InpMaxSpreadPoints       = 30;

// ── NEW 2: Liquidity Sweep ──────────────────────────────────────────
input bool    InpLiqSweepEnable        = true;
input int     InpLiqSweepLookback      = 20;    // M15 bars to scan for recent highs/lows
input double  InpLiqSweepWickRatio     = 0.55;  // wick must be >= this fraction of candle range

// ── NEW 3: Fair Value Gap ───────────────────────────────────────────
input bool    InpFVGEnable             = true;
input int     InpFVGLookback           = 30;    // H1 bars to scan for FVGs

// ── NEW 4: CHoCH / BOS ─────────────────────────────────────────────
input bool    InpCHoCHEnable           = true;
input int     InpCHoCHLookback         = 40;    // H1 bars for structure tracking

// ── NEW 5: Premium / Discount ──────────────────────────────────────
input bool    InpPDEnable              = true;
input ENUM_TIMEFRAMES InpPDTimeframe   = PERIOD_H4; // HTF for range calculation
input int     InpPDLookback            = 50;    // bars to find HTF range

// ── NEW 6: RSI Divergence ───────────────────────────────────────────
input bool    InpDivEnable             = true;
input int     InpDivLookback           = 20;    // bars to scan for divergence

// ── NEW 7: Order Block ──────────────────────────────────────────────
input bool    InpOBEnable              = true;
input int     InpOBLookback            = 40;    // H1 bars to scan for OBs
input double  InpOBImpulseATR          = 1.5;   // impulse candle must be >= N×ATR

// ── NEW 8: News Blackout ────────────────────────────────────────────
// Enter upcoming high-impact news times manually (UTC).
// Format: HHMM as integer. Set unused slots to 0.
input bool    InpNewsEnable            = true;
input int     InpNewsTime1             = 0;     // e.g. 1330 = 13:30 UTC
input int     InpNewsTime2             = 0;
input int     InpNewsTime3             = 0;
input int     InpNewsTime4             = 0;
input int     InpNewsBufferMins        = 30;    // block N mins before AND after

// ── NEW 9: Candle Pattern ───────────────────────────────────────────
input bool    InpCandleEnable          = true;  // require pattern at key level
input double  InpPinWickRatio          = 0.6;   // pin bar wick >= this fraction of range

// ── NEW 10: ATR Volatility Regime ──────────────────────────────────
input bool    InpVolRegimeEnable       = true;
input int     InpVolRegimePeriod       = 20;    // ATR avg period
input double  InpVolRegimeMin          = 0.80;  // ATR must be >= 80% of avg
input double  InpVolRegimeMax          = 1.80;  // ATR must be <= 180% of avg

// ── NEW 11: DXY Correlation ────────────────────────────────────────
input bool    InpDXYEnable             = true;  // v6.12: was false — enabled by default (fails open safely if no DXY symbol)
input string  InpDXYSymbol             = ""; // v6.13: blank = auto-detect broker's DXY symbol; set explicitly to override
input int     InpDXYMA                 = 50;    // DXY MA period on D1

// Facebook bridge
input bool    InpFacebookEnable        = true;
input string  InpFacebookURL           = "https://localhost:5005/signal";
input string  InpFacebookBasis         = "SMC Structure + Liquidity Sweep + Kill Zone";

// Debug
input bool    InpDebugLog              = false;

// ── v6.11 NEW: Integrated Trade Manager ─────────────────────────────
// Merged from the standalone TradeManager_BE_PartialClose.mq5 EA.
// Manages any open position on this chart's symbol — closes a portion
// at TP1 (1R) and moves the remaining stop to breakeven. Does NOT open
// trades itself; only manages positions that already exist (opened by
// you manually or by a copier reading this bot's Telegram signals).
input bool    InpMgrEnable             = true;   // master switch for trade management
input double  InpMgrPartialClosePct    = 50.0;   // % of position to close at TP1
input double  InpMgrTP1RMultiple       = 1.0;    // TP1 = entry ± (SL distance × this) — matches InpTP1Ratio
input double  InpMgrBEBufferPoints     = 20;     // extra points beyond breakeven (covers spread/commission)
input long    InpMgrMagicFilter        = 0;      // v6.15 FIX: comment corrected — 0 does NOT mean "manage all" anymore.
                                                  // Priority order: magic filter (if >0) > comment tag (if set) >
                                                  // InpMgrManageAllPositions explicit opt-in. See v6.13 Fix 3/7.
input bool    InpMgrDebugLog           = true;   // log every partial-close / BE-move action

// ── v6.12 NEW: A. Crisis Mode ────────────────────────────────────────
// Manual toggle — flip ON yourself when you know an active, unscheduled
// macro/geopolitical shock is unfolding (e.g. a live conflict headline
// cycle). Does not detect anything automatically; it's a deliberate,
// user-controlled risk dial for exactly the situation no indicator
// can see coming.
input bool    InpCrisisMode            = false;  // master switch — OFF by default, flip ON manually when needed
input double  InpCrisisSLMultiplier    = 2.0;    // multiplies InpMinSLATRMult while crisis mode is active
input int     InpCrisisScoreBoost      = 3;      // added on top of InpMinScore while crisis mode is active
input string  InpCrisisPairs           = "EURUSD,GBPUSD"; // comma-separated symbols fully suspended during crisis mode (blank = none suspended, just widen/raise)

// ── v6.12 NEW: B. Volatility Spike Circuit Breaker ──────────────────
// Detects the CURRENT, still-forming M5 candle's range exceeding a
// multiple of its recent average — BEFORE the candle closes. This is
// what ATR-based filters can't do (they only see the previous closed
// bar). After a detected spike, new signals pause for a cooldown.
input bool    InpSpikeBreakerEnable       = true;
input double  InpSpikeBreakerMult         = 2.5;  // forming candle range must exceed this × recent avg to trigger
input int     InpSpikeBreakerLookback     = 10;   // bars used to compute the recent average range (M5)
input int     InpSpikeBreakerCooldownMins = 30;   // minutes to pause new signals after a detected spike

// ── v6.12 NEW: C. Native Economic Calendar ──────────────────────────
// Uses MT5's built-in CalendarValueHistory() to automatically block
// signals around scheduled high-impact events for the traded symbol's
// currencies — no manual HHMM entry needed. Runs ALONGSIDE the existing
// manual InpNewsTime1-4 filter, not as a replacement for it (that one
// still catches anything you specifically want extra buffer around).
input bool    InpCalendarEnable           = true;
input int     InpCalendarMinImportance    = 3;    // MQL5 native scale: 1=low, 2=moderate, 3=high
input int     InpCalendarBufferMins       = 30;   // minutes to block before AND after a matching event

// ── v6.13 NEW: Fix 2/6. Duplicate-Instance Guard ────────────────────
input bool    InpDupGuardEnable        = true;
input int     InpDupGuardStaleSecs     = 30;    // heartbeat older than this = treat other "instance" as dead

// ── v6.13 NEW: Fix 3/7. Trade Manager Safety ────────────────────────
// Default behavior changed: the manager now manages NOTHING unless one
// of these is explicitly configured. InpMgrMagicFilter (existing input,
// still 0 by default) takes priority if set; otherwise the comment tag;
// otherwise it manages nothing unless InpMgrManageAllPositions=true.
input string  InpMgrCommentTagFilter   = "";     // only manage positions whose comment CONTAINS this text
input bool    InpMgrManageAllPositions = false;  // explicit opt-in required to manage ALL positions (old v6.11 default)

// ── v6.13 NEW: Fix 4. Volume Profile (tick-volume approximation) ────
// NOTE: MT5 tick volume is a count of price changes, not literal traded
// size — OTC FX has no centralized tape. This is a reasonable proxy for
// activity concentration, not true volume-at-price.
input bool    InpVolProfileEnable      = true;
input int     InpVolProfileBars        = 100;    // M15 bars used to build the profile
input int     InpVolProfileBins        = 24;     // number of price bins across the range

// ── v6.13 NEW: Fix 4. Order Flow (DOM / Level 2) ─────────────────────
// NOTE: most retail FX/CFD brokers do NOT expose real Depth-of-Market
// data via MQL5. This gracefully degrades to "no confluence contributed"
// if MarketBookAdd() fails for this symbol/broker — it never blocks
// signals, it just won't add its bonus point when unavailable.
input bool    InpOrderFlowEnable       = true;

// ── v6.13 NEW: Fix 4. COT Positioning (manual weekly input) ─────────
// NOTE: true real-time CFTC Commitment-of-Traders data is NOT
// accessible from inside MQL5 — it's published weekly (Fridays) and
// there's no built-in feed. This is an honest workaround: update this
// string once a week yourself from the published COT report, same
// pattern as the manual news calendar.
input bool    InpCOTEnable             = false;
input string  InpCOTBiasOverrides      = ""; // e.g. "EURUSD:1,GBPUSD:-1,XAUUSD:0"  (1=bullish,-1=bearish,0=neutral)

// ── v6.13 NEW: Fix 5. Portfolio Correlation Awareness ────────────────
// Caps simultaneous same-direction USD-exposure positions across the
// WHOLE account (not just this chart's symbol) — the exact pattern
// that had EURUSD/GBPUSD/XAUUSD all firing the same USD-strength bet
// three times over in the July dataset.
input bool    InpCorrelationEnable      = true;
input int     InpMaxCorrelatedPositions = 2;   // max simultaneous same-direction USD-exposure positions

// ── v6.13 NEW: Fix 9. Breaking News Auto-Detection ──────────────────
// Optional. Polls a user-supplied URL on an interval and scans the
// returned text for high-severity keywords. OFF by default — requires
// you to supply a working, whitelisted endpoint. See chat notes for
// a recommended architecture (a small intermediary you control, rather
// than pointing this directly at a complex third-party news API).
input bool    InpBreakingNewsEnable       = false;
input string  InpBreakingNewsURL          = "";
input string  InpBreakingNewsKeywords     = "war,attack,strike,invasion,missile,explosion,closed,closure,emergency,martial law,coup,nuclear,military action,ceasefire collapse";
input int     InpBreakingNewsCheckMins    = 5;
input int     InpBreakingNewsCooldownMins = 60;

// ── v6.14 NEW: Volatility Auto-Close ─────────────────────────────────
// Closes existing open positions (not just pausing new signals) when
// real-time volatility spikes extremely. OFF by default — this is a
// consequential action (fully closes real trades), so it requires
// explicit opt-in. Uses the SAME eligibility rule as the Trade Manager
// (InpMgrMagicFilter / InpMgrCommentTagFilter / InpMgrManageAllPositions)
// so it only ever touches positions this EA is already authorized to
// manage — it will never close something unrelated.
input bool    InpVolCloseEnable       = false;  // master switch — closes real positions when ON
input double  InpVolCloseMult         = 4.0;    // forming candle range must exceed this × its recent avg (stricter than the signal-pause threshold, intentionally)
input int     InpVolCloseLookback     = 10;     // bars used for the recent-average calculation
input int     InpVolCloseCooldownMins = 15;     // minimum time between auto-close attempts

// ── v6.16 NEW: Chart Image Attachment ────────────────────────────────
// Every full BUY/SELL signal gets a chart screenshot with Entry/SL/
// TP1/TP2/TP3 drawn as horizontal lines, sent right after the existing
// (unchanged) text message. Uses the same Telegram bot/chat — no new
// URL to whitelist.
input bool    InpChartImageEnable     = true;
input int     InpChartImageWidth      = 1000;   // screenshot width in pixels
input int     InpChartImageHeight     = 600;    // screenshot height in pixels
input bool    InpChartImageKeepFiles  = true;    // keep the PNG in MQL5/Files after sending (for your own review)
input color   InpChartImgEntryColor   = clrWhite;
input color   InpChartImgSLColor      = clrRed;
input color   InpChartImgTP1Color     = clrLimeGreen;
input color   InpChartImgTP2Color     = clrLime;
input color   InpChartImgTP3Color     = clrSpringGreen;

//─────────────────────────── HANDLES ───────────────────────────────
int h_w_ema, h_d_ma, h_d_fast, h_d_slow, h_h1_ema;
int h_rsi, h_macd, h_atr, h_adx;
int h_m5_ef, h_m5_es, h_m5_rsi, h_m5_macd;
int h_h1_rsi;     // NEW 6: RSI on H1 for divergence
int h_atr_d1;     // NEW 10: ATR on D1 for vol regime check
int h_dxy_ma;     // NEW 11: DXY MA handle

datetime g_lastBarTime    = 0;
datetime g_lastSignalTime = 0;
bool     g_startupSent    = false;

// v6.11 NEW — tracks which position tickets have already had their
// partial close + breakeven move applied, so it only happens once.
ulong    g_mgrProcessed[];

// v6.12 NEW — tracks the last time a volatility spike was detected,
// used by the circuit breaker cooldown (Fix B).
datetime g_lastSpikeTime  = 0;

// v6.13 NEW globals
string   g_dxyResolvedSymbol = "";     // cached auto-detected DXY symbol name
bool     g_isDuplicate       = false;  // set true if another live instance is detected
bool     g_domSubscribed     = false;  // whether MarketBookAdd succeeded (order-flow feature)
int      g_lastSpikeDir      = 0;      // direction of the most recent detected spike
bool     g_lastSpikeAligned  = true;   // was that spike aligned with the D1 trend?
datetime g_lastNewsCheck     = 0;      // last time the breaking-news endpoint was polled
datetime g_lastNewsAlert     = 0;      // last time a keyword match paused signals
datetime g_lastVolCloseTime  = 0;      // v6.14 — last time the volatility auto-close fired
datetime g_lastWatchTime     = 0;      // v6.15 — last time a WATCH-tier heads-up was sent

//─────────────────────────── EMOJI ─────────────────────────────────
string _Emoji(ushort hi,ushort lo){ushort s[2];s[0]=hi;s[1]=lo;return ShortArrayToString(s);}
string _EmojiB(ushort b){ushort s[1];s[0]=b;return ShortArrayToString(s);}
string E_GREEN() {return _Emoji(0xD83D,0xDFE2);}
string E_RED()   {return _Emoji(0xD83D,0xDD34);}
string E_MONEY() {return _Emoji(0xD83D,0xDCB0);}
string E_UP()    {return _Emoji(0xD83D,0xDCC8);}
string E_DOWN()  {return _Emoji(0xD83D,0xDCC9);}
string E_TARGET(){return _Emoji(0xD83C,0xDFAF);}
string E_STOP()  {return _Emoji(0xD83D,0xDED1);}
string E_CHECK() {return _EmojiB(0x2705);}
string E_RULER() {return _Emoji(0xD83D,0xDCD0);}
string E_CLOCK() {return _Emoji(0xD83D,0xDD51);}
string E_ROBOT() {return _Emoji(0xD83E,0xDD16);}
string E_CHART() {return _Emoji(0xD83D,0xDCCA);}
string E_STAR()  {return _Emoji(0xD83C,0xDF1F);}
string E_SKULL() {return _Emoji(0xD83D,0xDC80);}
string E_FIRE()  {return _Emoji(0xD83D,0xDD25);}
string E_WARN()  {return _EmojiB(0x26A0);}
string E_LOCK()  {return _Emoji(0xD83D,0xDD12);}
string E_ZONE()  {return _Emoji(0xD83D,0xDCCD);}
string E_SWEEP() {return _Emoji(0xD83C,0xDF00);}
string SEP(){return _EmojiB(0x2015)+_EmojiB(0x2015)+_EmojiB(0x2015)+_EmojiB(0x2015)+
             _EmojiB(0x2015)+_EmojiB(0x2015)+_EmojiB(0x2015)+_EmojiB(0x2015)+
             _EmojiB(0x2015)+_EmojiB(0x2015)+_EmojiB(0x2015);}

//─────────────────────────── v6.13 FIX 1: DXY AUTO-DETECT ──────────
// If InpDXYSymbol is left blank, scans the broker's symbol list for
// common Dollar Index naming variants instead of silently failing when
// the hardcoded default ("DXY") doesn't match this broker's ticker.
string ResolveDXYSymbol()
{
   if(StringLen(InpDXYSymbol)>0) return(InpDXYSymbol); // explicit override wins
   if(StringLen(g_dxyResolvedSymbol)>0) return(g_dxyResolvedSymbol); // cached

   string candidates[]={"DXY","USDX","DX","USDOLLAR","USDIDX","DOLLAR","USDX.a","DXYm","DX.F","USDX_"};

   // v6.15 FIX: the `selected` parameter was inverted from what the
   // comments claimed — MQL5 semantics are selected=true → Market Watch
   // subset, selected=false → the broker's FULL symbol list. The two
   // passes below now actually do what their comments say.

   // Pass 1: symbols already in Market Watch (fast, small list)
   int total=SymbolsTotal(true);
   for(int i=0;i<total;i++)
   {
      string s=SymbolName(i,true);
      string sUpper=s; StringToUpper(sUpper);
      for(int j=0;j<ArraySize(candidates);j++)
      {
         string c=candidates[j]; StringToUpper(c);
         if(sUpper==c || StringFind(sUpper,c)==0)
         { g_dxyResolvedSymbol=s; return(s); }
      }
   }
   // Pass 2: the broker's FULL symbol list (broader fallback — may
   // include symbols not yet added to Market Watch)
   total=SymbolsTotal(false);
   for(int i=0;i<total;i++)
   {
      string s=SymbolName(i,false);
      string sUpper=s; StringToUpper(sUpper);
      for(int j=0;j<ArraySize(candidates);j++)
      {
         string c=candidates[j]; StringToUpper(c);
         if(sUpper==c || StringFind(sUpper,c)==0)
         { g_dxyResolvedSymbol=s; return(s); }
      }
   }
   return(""); // not found — DXYAligned() will fail open and log why
}

//─────────────────────────── v6.13 FIX 2/6: DUPLICATE-INSTANCE GUARD ─
// Uses a terminal-wide GlobalVariable as a heartbeat, keyed by symbol.
// If a fresh heartbeat already exists when this instance starts, a
// second live copy of this EA is almost certainly running on the same
// symbol (the exact failure mode that produced ~23 duplicate rows in
// the July dataset). This instance then disables signal generation and
// trade management rather than double-firing.
string GuardVarName(){ return("SIGBOT_HB_"+_Symbol); }

bool CheckAndClaimSingleton()
{
   if(!InpDupGuardEnable) return(true);
   string var=GuardVarName();
   if(GlobalVariableCheck(var))
   {
      datetime last=(datetime)GlobalVariableGet(var);
      if(TimeCurrent()-last < InpDupGuardStaleSecs)
         return(false); // fresh heartbeat from another instance — genuine duplicate
      // stale — previous instance likely crashed or was removed; safe to claim
   }
   GlobalVariableSet(var,(double)TimeCurrent());
   return(true);
}

void UpdateHeartbeat()
{
   if(!InpDupGuardEnable || g_isDuplicate) return;
   GlobalVariableSet(GuardVarName(),(double)TimeCurrent());
}

void ReleaseSingleton()
{
   if(!InpDupGuardEnable || g_isDuplicate) return;
   string var=GuardVarName();
   if(GlobalVariableCheck(var)) GlobalVariableDel(var);
}

//+------------------------------------------------------------------+
int OnInit()
{
   h_w_ema  = iMA(_Symbol,PERIOD_W1, InpWeeklyEMA,  0,MODE_EMA,PRICE_CLOSE);
   h_d_ma   = iMA(_Symbol,PERIOD_D1, InpDailyMA,    0,MODE_SMA,PRICE_CLOSE);
   h_d_fast = iMA(_Symbol,PERIOD_D1, InpCrossFastMA,0,MODE_SMA,PRICE_CLOSE);
   h_d_slow = iMA(_Symbol,PERIOD_D1, InpCrossSlowMA,0,MODE_SMA,PRICE_CLOSE);
   h_h1_ema = iMA(_Symbol,PERIOD_H1, InpH1EMA,      0,MODE_EMA,PRICE_CLOSE);
   h_rsi    = iRSI(_Symbol,PERIOD_M15,InpRSIPeriod,    PRICE_CLOSE);
   h_macd   = iMACD(_Symbol,PERIOD_M15,InpMACDFast,InpMACDSlow,InpMACDSignalP,PRICE_CLOSE);
   h_atr    = iATR(_Symbol,PERIOD_M15,InpATRPeriod);
   h_adx    = iADX(_Symbol,PERIOD_D1, InpADXPeriod);
   h_m5_ef  = iMA(_Symbol,PERIOD_M5,InpM5EMAFast,0,MODE_EMA,PRICE_CLOSE);
   h_m5_es  = iMA(_Symbol,PERIOD_M5,InpM5EMASlow, 0,MODE_EMA,PRICE_CLOSE);
   h_m5_rsi = iRSI(_Symbol,PERIOD_M5,InpM5RSIPeriod,PRICE_CLOSE);
   h_m5_macd= iMACD(_Symbol,PERIOD_M5,InpMACDFast,InpMACDSlow,InpMACDSignalP,PRICE_CLOSE);
   // NEW handles
   h_h1_rsi = iRSI(_Symbol,PERIOD_H1,InpRSIPeriod,PRICE_CLOSE);
   h_atr_d1 = iATR(_Symbol,PERIOD_M15,InpVolRegimePeriod); // M15 ATR for vol regime

   // v6.13 FIX 1 — DXY handle now uses the resolver (auto-detect or override)
   h_dxy_ma = INVALID_HANDLE;
   if(InpDXYEnable)
   {
      string dxySym=ResolveDXYSymbol();
      if(StringLen(dxySym)>0)
      {
         h_dxy_ma=iMA(dxySym,PERIOD_D1,InpDXYMA,0,MODE_SMA,PRICE_CLOSE);
         if(h_dxy_ma==INVALID_HANDLE)
            Print("[v6.13 DXY] WARNING: symbol '",dxySym,"' found but handle creation failed — filter inactive.");
         else
            Print("[v6.13 DXY] Auto-detected DXY symbol: '",dxySym,"' — filter active.");
      }
      else
      {
         Print("[v6.13 DXY] WARNING: DXY filter enabled but no matching symbol found on this broker. ",
               "Filter will pass-through with NO effect until you set InpDXYSymbol manually. ",
               "This is now logged instead of failing silently.");
      }
   }

   bool bad = (h_w_ema==INVALID_HANDLE||h_d_ma==INVALID_HANDLE||
               h_d_fast==INVALID_HANDLE||h_d_slow==INVALID_HANDLE||
               h_h1_ema==INVALID_HANDLE||h_rsi==INVALID_HANDLE||
               h_macd==INVALID_HANDLE||h_atr==INVALID_HANDLE||
               h_adx==INVALID_HANDLE||h_m5_ef==INVALID_HANDLE||
               h_m5_es==INVALID_HANDLE||h_m5_rsi==INVALID_HANDLE||
               h_m5_macd==INVALID_HANDLE||h_h1_rsi==INVALID_HANDLE||
               h_atr_d1==INVALID_HANDLE);
   if(bad){ Print("ERROR: handle creation failed"); return(INIT_FAILED); }

   ArrayResize(g_mgrProcessed,0); // v6.11

   // v6.13 FIX 2/6 — duplicate-instance guard: claim the singleton slot
   g_isDuplicate = !CheckAndClaimSingleton();
   if(g_isDuplicate)
   {
      Print("[v6.13 DupGuard] *** WARNING *** Another live instance of this EA appears to ",
            "already be running on ",_Symbol,". This instance will NOT generate signals or ",
            "manage trades to avoid duplicate/conflicting orders. Remove the duplicate chart/EA.");
      Comment("SignalBot v6.16: DUPLICATE INSTANCE DETECTED on ",_Symbol,
              " — signal generation and trade management are DISABLED here. Remove the duplicate.");
   }

   // v6.13 FIX 4 — subscribe to DOM/Level 2 for the order-flow confluence,
   // if the broker/symbol supports it (most retail FX/CFD brokers don't;
   // this fails silently into "feature simply inactive", not an error).
   if(InpOrderFlowEnable) g_domSubscribed=MarketBookAdd(_Symbol);

   Print("SignalBot MT5 v6.16 initialised on ",_Symbol,
         g_isDuplicate ? " | *** DUPLICATE — DISABLED ***" : "",
         InpMgrEnable ? " | Trade Manager: ON" : " | Trade Manager: OFF",
         InpCrisisMode ? " | CRISIS MODE: ON" : " | Crisis Mode: off",
         InpSpikeBreakerEnable ? " | Spike Breaker: ON" : " | Spike Breaker: OFF",
         InpCalendarEnable ? " | Native Calendar: ON" : " | Native Calendar: OFF",
         InpBreakingNewsEnable ? " | Breaking News: ON" : " | Breaking News: off",
         InpCorrelationEnable ? " | Correlation Cap: ON" : " | Correlation Cap: OFF",
         InpVolCloseEnable ? " | VOL AUTO-CLOSE: ON" : " | Vol Auto-Close: off",
         InpChartImageEnable ? " | Chart Image: ON" : " | Chart Image: OFF",
         g_domSubscribed ? " | Order Flow: ACTIVE" : " | Order Flow: unavailable on this broker",
         InpDXYEnable ? " | DXY Filter: ON" : " | DXY Filter: OFF");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   int arr[]={h_w_ema,h_d_ma,h_d_fast,h_d_slow,h_h1_ema,
              h_rsi,h_macd,h_atr,h_adx,
              h_m5_ef,h_m5_es,h_m5_rsi,h_m5_macd,
              h_h1_rsi,h_atr_d1,h_dxy_ma};
   for(int i=0;i<ArraySize(arr);i++)
      if(arr[i]!=INVALID_HANDLE) IndicatorRelease(arr[i]);

   ReleaseSingleton();               // v6.13 — free the duplicate-guard slot on clean removal
   if(g_domSubscribed) MarketBookRelease(_Symbol); // v6.13 — release DOM subscription
   Comment(""); // clear any duplicate-instance warning left on the chart
}

//─────────────────────────── v6.11 TRADE MANAGER ───────────────────
// Merged from TradeManager_BE_PartialClose.mq5. Manages open positions
// on this chart's symbol: partial close at TP1 (1R) + move remaining
// SL to breakeven. Runs every tick, independent of the signal-scan
// bar-close gate below, so it reacts immediately to price.

bool MgrAlreadyProcessed(ulong ticket)
{
   for(int i=0;i<ArraySize(g_mgrProcessed);i++)
      if(g_mgrProcessed[i]==ticket) return(true);
   return(false);
}

void MgrMarkProcessed(ulong ticket)
{
   int n=ArraySize(g_mgrProcessed);
   ArrayResize(g_mgrProcessed,n+1);
   g_mgrProcessed[n]=ticket;
}

double MgrNormalizeVolume(double vol,string sym)
{
   double step=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   double minV=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   if(step<=0) step=0.01;
   double norm=MathFloor(vol/step)*step;
   if(norm<minV) norm=minV;
   return(NormalizeDouble(norm,2));
}

// v6.15 NEW — shared eligibility check, previously duplicated separately
// inside both ManageOpenPositions() and CloseOnExtremeVolatility(). A
// single copy means a future change to the eligibility rule only needs
// to happen once. ASSUMES the position is already selected via
// PositionSelectByTicket() by the caller.
bool IsPositionEligible()
{
   long   magic  = PositionGetInteger(POSITION_MAGIC);
   string comment= PositionGetString(POSITION_COMMENT);
   if(InpMgrMagicFilter>0)
      return(magic==InpMgrMagicFilter);
   if(StringLen(InpMgrCommentTagFilter)>0)
      return(StringFind(comment,InpMgrCommentTagFilter)>=0);
   return(InpMgrManageAllPositions); // explicit opt-in required
}

// v6.15 NEW — prunes g_mgrProcessed of tickets for positions that are no
// longer open (closed positions can never be selected again, so keeping
// their ticket in the array forever just wastes memory and scan time).
// Called once per new M5 bar, not every tick, since it's a minor
// housekeeping task rather than anything time-sensitive.
void PruneMgrProcessed()
{
   int total=ArraySize(g_mgrProcessed);
   if(total==0) return;
   ulong kept[];
   for(int i=0;i<total;i++)
   {
      ulong t=g_mgrProcessed[i];
      if(PositionSelectByTicket(t))
      {
         int n=ArraySize(kept);
         ArrayResize(kept,n+1);
         kept[n]=t;
      }
   }
   ArrayResize(g_mgrProcessed,ArraySize(kept));
   for(int i=0;i<ArraySize(kept);i++) g_mgrProcessed[i]=kept[i];
}

void ManageOpenPositions()
{
   if(!InpMgrEnable) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      string sym=PositionGetString(POSITION_SYMBOL);
      if(sym!=_Symbol) continue;

      // v6.15 — now calls the shared IsPositionEligible() instead of a
      // hand-duplicated copy of this logic (see v6.13 Fix 3/7 for why
      // the default behavior requires magic/comment/opt-in match).
      if(!IsPositionEligible()) continue;

      if(MgrAlreadyProcessed(ticket)) continue;

      long   type   = PositionGetInteger(POSITION_TYPE);
      double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double curBid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double curAsk = SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      if(sl==0) continue; // no SL set — can't compute R, skip (safety)

      double slDist=MathAbs(entry-sl);
      if(slDist<=0) continue;

      double tp1Level;
      double curPrice;
      bool   reachedTP1=false;

      if(type==POSITION_TYPE_BUY)
      {
         tp1Level = entry + slDist*InpMgrTP1RMultiple;
         curPrice = curBid;
         reachedTP1 = (curPrice >= tp1Level);
      }
      else // SELL
      {
         tp1Level = entry - slDist*InpMgrTP1RMultiple;
         curPrice = curAsk;
         reachedTP1 = (curPrice <= tp1Level);
      }

      if(!reachedTP1) continue;

      // ── Step 1: Partial close ────────────────────────────────────
      double closeVol=MgrNormalizeVolume(volume*InpMgrPartialClosePct/100.0,sym);

      // v6.13 FIX 7 — if the remainder after a partial close would fall
      // below the broker's minimum tradable lot, that remainder can
      // never actually be placed/managed. Close the FULL position
      // instead of leaving an unbrokerable sliver stuck open.
      // v6.15 FIX — changed from "remainingVol>0 && remainingVol<minVol"
      // to just "remainingVol<minVol": the old condition missed the case
      // where MgrNormalizeVolume's minimum-lot rounding already pushed
      // closeVol up to the full position size (remainingVol==0 exactly),
      // which used to skip the fullClose flag and cause a pointless,
      // failing SL-to-breakeven attempt on an already-closed position.
      double minVol=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
      double remainingVol=volume-closeVol;
      bool fullClose=false;
      if(remainingVol<minVol)
      {
         closeVol=volume;
         fullClose=true;
      }

      if(closeVol>0)
      {
         MqlTradeRequest req; MqlTradeResult res;
         ZeroMemory(req); ZeroMemory(res);
         req.action   = TRADE_ACTION_DEAL;
         req.position = ticket;
         req.symbol   = sym;
         req.volume   = closeVol;
         req.type     = (type==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
         req.price    = (type==POSITION_TYPE_BUY)?curBid:curAsk;
         req.deviation= 20;
         req.type_filling = ORDER_FILLING_IOC;

         bool closeOk=OrderSend(req,res);
         if(InpMgrDebugLog)
            Print("[TradeManager] ",(fullClose?"Full close (remainder below broker min) ":"Partial close "),
                  "ticket=",ticket," vol=",closeVol," result=",closeOk," retcode=",res.retcode);
      }

      // ── Step 2: Move remaining SL to breakeven + buffer ──────────
      // Skipped entirely if the position was fully closed above — there's
      // no remainder left to protect.
      if(!fullClose)
      {
         double point=SymbolInfoDouble(sym,SYMBOL_POINT);
         double beSL;
         if(type==POSITION_TYPE_BUY)
            beSL = entry + InpMgrBEBufferPoints*point;
         else
            beSL = entry - InpMgrBEBufferPoints*point;

         double tp=PositionGetDouble(POSITION_TP);

         MqlTradeRequest modReq; MqlTradeResult modRes;
         ZeroMemory(modReq); ZeroMemory(modRes);
         modReq.action   = TRADE_ACTION_SLTP;
         modReq.position = ticket;
         modReq.symbol   = sym;
         modReq.sl       = beSL;
         modReq.tp       = tp;

         bool beOk=OrderSend(modReq,modRes);
         if(InpMgrDebugLog)
            Print("[TradeManager] Move SL to BE ticket=",ticket,
                  " newSL=",DoubleToString(beSL,_Digits)," result=",beOk,
                  " retcode=",modRes.retcode);
      }

      // Mark processed regardless of partial success, to avoid a retry
      // loop spamming orders every tick if the partial close failed once.
      MgrMarkProcessed(ticket);
   }
}

//─────────────────────────── v6.12 A. CRISIS MODE ──────────────────
// Manual, user-controlled risk dial. Does not detect anything itself —
// it exists because no indicator can know a live geopolitical story is
// unfolding. Effective values are computed here rather than mutating
// the input variables directly (MQL5 inputs are read-only at runtime).

double GetEffectiveMinSLATRMult()
{
   double v=InpMinSLATRMult;
   if(InpCrisisMode) v*=InpCrisisSLMultiplier;
   return(v);
}

int GetEffectiveMinScore()
{
   int v=InpMinScore;
   if(InpCrisisMode) v+=InpCrisisScoreBoost;
   return(v);
}

bool SymbolSuspendedByCrisis()
{
   if(!InpCrisisMode) return(false);
   if(StringLen(InpCrisisPairs)==0) return(false);
   string list[];
   int n=StringSplit(InpCrisisPairs,',',list);
   for(int i=0;i<n;i++)
   {
      string s=list[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(s==_Symbol) return(true);
   }
   return(false);
}

//─────────────────────────── v6.12/13 B. SPIKE CIRCUIT BREAKER ─────
// Detects the CURRENT, still-forming M5 candle's range exceeding a
// multiple of its own recent average — checked every tick, so it
// reacts mid-candle rather than waiting for the bar to close like
// ATR-based filters do. Runs independently of the signal bar-close
// gate so it catches spikes even between signal scans.
//
// v6.13 FIX 8 — now direction-aware. A spike ALIGNED with the D1 trend
// is more likely a genuine breakout (news confirming the existing
// bias); a spike AGAINST the D1 trend is more likely a whipsaw or
// stop-hunt. Only counter-trend spikes, or a candidate signal that
// opposes the spike's own direction, get the full cooldown. A spike
// that matches both the D1 trend AND the candidate signal's direction
// is allowed through — the "blunt instrument" problem this fixes.
int DailyBias(); // forward declaration (defined further below, used here)

bool VolatilitySpikeDetected()
{
   if(!InpSpikeBreakerEnable) return(false);
   double curRange=iHigh(_Symbol,PERIOD_M5,0)-iLow(_Symbol,PERIOD_M5,0);
   double sum=0;
   for(int i=1;i<=InpSpikeBreakerLookback;i++)
      sum += (iHigh(_Symbol,PERIOD_M5,i)-iLow(_Symbol,PERIOD_M5,i));
   double avg=sum/InpSpikeBreakerLookback;
   if(avg<=0) return(false);
   return(curRange >= avg*InpSpikeBreakerMult);
}

int SpikeDirection()
{
   double o=iOpen(_Symbol,PERIOD_M5,0);
   double c=SymbolInfoDouble(_Symbol,SYMBOL_BID); // current price, forming candle has no fixed close yet
   if(c>o) return(1);
   if(c<o) return(-1);
   return(0);
}

void CheckVolatilitySpike()
{
   if(!InpSpikeBreakerEnable) return;
   if(VolatilitySpikeDetected())
   {
      bool freshLog=(g_lastSpikeTime==0 || TimeCurrent()-g_lastSpikeTime>60);
      g_lastSpikeTime=TimeCurrent();
      g_lastSpikeDir=SpikeDirection();
      int db=DailyBias();
      g_lastSpikeAligned=(g_lastSpikeDir!=0 && g_lastSpikeDir==db);
      if(freshLog)
         Print("[v6.13 SpikeBreaker] Volatility spike detected on ",_Symbol,
               " dir=",g_lastSpikeDir," alignedWithD1=",g_lastSpikeAligned,
               " — cooldown ",InpSpikeBreakerCooldownMins," min",
               (g_lastSpikeAligned?" (same-direction signals still allowed)":" (all signals blocked)"));
   }
}

bool InSpikeCooldown(int signalTrend)
{
   if(!InpSpikeBreakerEnable) return(false);
   if(g_lastSpikeTime==0) return(false);
   if((TimeCurrent()-g_lastSpikeTime) >= InpSpikeBreakerCooldownMins*60) return(false); // cooldown expired

   // v6.13: if the spike was aligned with the D1 trend AND the candidate
   // signal shares that same direction, don't block — likely a genuine
   // breakout continuation, not a whipsaw.
   if(g_lastSpikeAligned && signalTrend==g_lastSpikeDir) return(false);

   return(true); // misaligned spike, or signal opposes the spike direction — block
}

//─────────────────────────── v6.12 C. NATIVE ECONOMIC CALENDAR ─────
// Uses MT5's built-in calendar (CalendarValueHistory / CalendarEventById
// / CalendarCountryById) to automatically block signals around scheduled
// high-impact events for the traded symbol's base/quote currencies.
// Runs ALONGSIDE the existing manual InpNewsTime1-4 filter, not instead
// of it. Fails open (returns false / no blackout) if the terminal's
// calendar data isn't available, matching the fail-safe pattern used
// elsewhere in this bot when a data source is missing.

bool CalendarBlackout()
{
   if(!InpCalendarEnable) return(false);

   datetime from=TimeCurrent()-InpCalendarBufferMins*60;
   datetime to  =TimeCurrent()+InpCalendarBufferMins*60;

   string base =StringSubstr(_Symbol,0,3);
   string quote=StringSubstr(_Symbol,3,3);

   MqlCalendarValue values[];
   int total=CalendarValueHistory(values,from,to,NULL,NULL);
   if(total<=0) return(false); // no events in window, or calendar unavailable — fail open

   for(int i=0;i<total;i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id,ev)) continue;
      if((int)ev.importance < InpCalendarMinImportance) continue;

      MqlCalendarCountry ctry;
      if(!CalendarCountryById(ev.country_id,ctry)) continue;

      if(ctry.currency==base || ctry.currency==quote)
         return(true); // high-impact event for a relevant currency inside the buffer window
   }
   return(false);
}

//─────────────────────────── v6.13 FIX 4a: VOLUME PROFILE ──────────
// Approximates a Point of Control (POC) and Value Area from M15 tick
// volume distributed across price bins. HONEST LIMITATION: MT5 tick
// volume is a count of price changes, not literal executed size — OTC
// FX has no centralized tape, so this is a proxy for activity
// concentration, not a true volume-at-price profile like you'd get
// from a centralized futures/equity feed.
bool GetVolumeProfile(int trend, double entry, double &pocPrice, double &vaHigh, double &vaLow)
{
   pocPrice=0; vaHigh=0; vaLow=0;
   if(!InpVolProfileEnable) return(false);

   double hi[],lo[]; long vol[];
   ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(vol,true);
   int n =CopyHigh(_Symbol,PERIOD_M15,0,InpVolProfileBars,hi);
   int n2=CopyLow(_Symbol,PERIOD_M15,0,InpVolProfileBars,lo);
   int n3=CopyTickVolume(_Symbol,PERIOD_M15,0,InpVolProfileBars,vol);
   if(n<=0||n2<=0||n3<=0) return(false);

   double rangeHigh=-DBL_MAX, rangeLow=DBL_MAX;
   for(int i=0;i<n;i++){ if(hi[i]>rangeHigh) rangeHigh=hi[i]; if(lo[i]<rangeLow) rangeLow=lo[i]; }
   double span=rangeHigh-rangeLow;
   if(span<=0) return(false);

   int bins=InpVolProfileBins;
   double binSize=span/bins;
   double binVol[]; ArrayResize(binVol,bins); ArrayInitialize(binVol,0);

   for(int i=0;i<n;i++)
   {
      int binStart=(int)MathFloor((lo[i]-rangeLow)/binSize);
      int binEnd  =(int)MathFloor((hi[i]-rangeLow)/binSize);
      if(binStart<0) binStart=0; if(binEnd>=bins) binEnd=bins-1;
      int touched=binEnd-binStart+1; if(touched<1) touched=1;
      double share=(double)vol[i]/touched;
      for(int b=binStart;b<=binEnd && b<bins;b++) binVol[b]+=share;
   }

   int pocBin=0; double maxV=0;
   for(int b=0;b<bins;b++) if(binVol[b]>maxV){ maxV=binVol[b]; pocBin=b; }
   pocPrice=rangeLow+(pocBin+0.5)*binSize;

   double totalVol=0; for(int b=0;b<bins;b++) totalVol+=binVol[b];
   double target=totalVol*0.70;
   double captured=binVol[pocBin];
   int lowB=pocBin, highB=pocBin;
   while(captured<target && (lowB>0 || highB<bins-1))
   {
      double nextLow = (lowB>0)? binVol[lowB-1] : -1;
      double nextHigh= (highB<bins-1)? binVol[highB+1] : -1;
      if(nextHigh>=nextLow){ highB++; captured+=binVol[highB]; }
      else                 { lowB--;  captured+=binVol[lowB];  }
   }
   vaLow =rangeLow+lowB*binSize;
   vaHigh=rangeLow+(highB+1)*binSize;

   bool nearPOC = MathAbs(entry-pocPrice) <= binSize*1.5;
   bool inValueArea = (entry>=vaLow && entry<=vaHigh);
   return(nearPOC || inValueArea);
}

//─────────────────────────── v6.13 FIX 4b: ORDER FLOW (DOM) ────────
// Uses MT5's native Depth-of-Market API. HONEST LIMITATION: most
// retail FX/CFD brokers do NOT expose real Level 2 data via MQL5 —
// MarketBookAdd() will simply fail, and this gracefully degrades to
// "no confluence contributed" rather than blocking any signal.
bool GetOrderFlowImbalance(int trend)
{
   if(!InpOrderFlowEnable || !g_domSubscribed) return(false);

   MqlBookInfo book[];
   if(!MarketBookGet(_Symbol,book)) return(false);

   double bidVol=0, askVol=0;
   for(int i=0;i<ArraySize(book);i++)
   {
      if(book[i].type==BOOK_TYPE_BUY)  bidVol+=book[i].volume;
      if(book[i].type==BOOK_TYPE_SELL) askVol+=book[i].volume;
   }
   if(bidVol+askVol<=0) return(false);

   double imbalance=(bidVol-askVol)/(bidVol+askVol); // -1..+1
   if(trend==1)  return(imbalance>0.15);  // meaningful resting buy-side interest
   return(imbalance<-0.15);               // meaningful resting sell-side interest
}

//─────────────────────────── v6.13 FIX 4c: COT POSITIONING ─────────
// HONEST LIMITATION: real-time CFTC Commitment-of-Traders data is NOT
// accessible from inside MQL5 — it's published weekly (Fridays) with
// no built-in feed. This is a manual workaround, same pattern as the
// manual news calendar: update InpCOTBiasOverrides yourself once a
// week from the published report.
int GetCOTBias()
{
   if(!InpCOTEnable || StringLen(InpCOTBiasOverrides)==0) return(0);
   string pairs[];
   int n=StringSplit(InpCOTBiasOverrides,',',pairs);
   for(int i=0;i<n;i++)
   {
      string entry=pairs[i];
      int colonPos=StringFind(entry,":");
      if(colonPos<0) continue;
      string sym=StringSubstr(entry,0,colonPos);
      string valStr=StringSubstr(entry,colonPos+1);
      StringTrimLeft(sym); StringTrimRight(sym);
      StringTrimLeft(valStr); StringTrimRight(valStr);
      if(sym==_Symbol) return((int)StringToInteger(valStr));
   }
   return(0);
}

//─────────────────────────── v6.13 FIX 5: PORTFOLIO CORRELATION ────
// Caps simultaneous same-direction USD-exposure positions across the
// WHOLE account, not just this chart's symbol — directly targets the
// pattern in the July dataset where EURUSD/GBPUSD/XAUUSD all fired the
// same USD-strength bet within minutes of each other.
int CountCorrelatedUSDExposure(int newTrend)
{
   bool newSymUsdBase =(StringSubstr(_Symbol,0,3)=="USD");
   bool newSymUsdQuote=(StringSubstr(_Symbol,3,3)=="USD");
   if(!newSymUsdBase && !newSymUsdQuote) return(0); // not a USD pair — correlation check doesn't apply

   bool newUsdLong = newSymUsdBase ? (newTrend==1) : (newTrend==-1);

   int count=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      string sym=PositionGetString(POSITION_SYMBOL);
      bool symUsdBase =(StringSubstr(sym,0,3)=="USD");
      bool symUsdQuote=(StringSubstr(sym,3,3)=="USD");
      if(!symUsdBase && !symUsdQuote) continue;

      long type=PositionGetInteger(POSITION_TYPE);
      bool posUsdLong = symUsdBase ? (type==POSITION_TYPE_BUY) : (type==POSITION_TYPE_SELL);
      if(posUsdLong==newUsdLong) count++;
   }
   return(count);
}

//─────────────────────────── v6.13 FIX 9: BREAKING NEWS DETECTION ──
// Polls a user-supplied URL on an interval (not every tick) and scans
// the returned text for high-severity keywords. Requires a working,
// WebRequest-whitelisted endpoint — OFF by default. See chat notes for
// a recommended architecture (a small intermediary you control that
// aggregates real news and returns plain text/JSON, rather than
// pointing this directly at a complex third-party API with auth).
bool BreakingNewsCheck()
{
   if(!InpBreakingNewsEnable) return(false);
   if(StringLen(InpBreakingNewsURL)==0) return(false);

   bool stillCoolingDown=(g_lastNewsAlert!=0 &&
                          (TimeCurrent()-g_lastNewsAlert) < InpBreakingNewsCooldownMins*60);

   // Only actually poll every InpBreakingNewsCheckMins — return the
   // existing cooldown state in between polls.
   if(g_lastNewsCheck!=0 && (TimeCurrent()-g_lastNewsCheck) < InpBreakingNewsCheckMins*60)
      return(stillCoolingDown);

   g_lastNewsCheck=TimeCurrent();

   char data[]; char result[]; string headers;
   ResetLastError();
   int code=WebRequest("GET",InpBreakingNewsURL,"",5000,data,result,headers);
   if(code!=200)
   {
      if(InpDebugLog) Print("[v6.13 BreakingNews] Fetch failed, code=",code," err=",GetLastError());
      return(stillCoolingDown);
   }

   string body=CharArrayToString(result);
   string bodyLower=body; StringToLower(bodyLower);

   string kw[];
   int n=StringSplit(InpBreakingNewsKeywords,',',kw);
   for(int i=0;i<n;i++)
   {
      string k=kw[i]; StringTrimLeft(k); StringTrimRight(k); StringToLower(k);
      if(StringLen(k)==0) continue;
      if(StringFind(bodyLower,k)>=0)
      {
         g_lastNewsAlert=TimeCurrent();
         Print("[v6.13 BreakingNews] Keyword match: '",k,"' — pausing signals for ",
               InpBreakingNewsCooldownMins," min");
         PostToTelegram(E_WARN()+" <b>Breaking News Alert</b>\nKeyword match: "+k+
                        "\nSignals paused "+IntegerToString(InpBreakingNewsCooldownMins)+
                        " min on "+_Symbol);
         return(true);
      }
   }
   return(stillCoolingDown);
}

//─────────────────────────── v6.14 NEW: VOLATILITY AUTO-CLOSE ──────
// Closes existing open positions when real-time volatility spikes
// extremely — separate from (and stricter than) the Spike Breaker,
// which only pauses NEW signal generation. This one acts on positions
// that already exist. Uses the same forming-candle detection method
// (checked every tick, not lagging like ATR) but with its own,
// independently-tunable threshold, since closing a live position is a
// bigger decision than declining to open a new one.

bool ExtremeVolatilityForClose()
{
   if(!InpVolCloseEnable) return(false);
   double curRange=iHigh(_Symbol,PERIOD_M5,0)-iLow(_Symbol,PERIOD_M5,0);
   double sum=0;
   for(int i=1;i<=InpVolCloseLookback;i++)
      sum += (iHigh(_Symbol,PERIOD_M5,i)-iLow(_Symbol,PERIOD_M5,i));
   double avg=sum/InpVolCloseLookback;
   if(avg<=0) return(false);
   return(curRange >= avg*InpVolCloseMult);
}

void CloseOnExtremeVolatility()
{
   if(!InpVolCloseEnable) return;
   if(g_lastVolCloseTime!=0 && (TimeCurrent()-g_lastVolCloseTime) < InpVolCloseCooldownMins*60) return;
   if(!ExtremeVolatilityForClose()) return;

   int closedCount=0;
   int failedCount=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      string sym=PositionGetString(POSITION_SYMBOL);
      if(sym!=_Symbol) continue;

      // v6.15 — now calls the shared IsPositionEligible() instead of a
      // hand-duplicated copy (see v6.13 Fix 3/7).
      if(!IsPositionEligible()) continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double curBid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double curAsk=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      MqlTradeRequest req; MqlTradeResult res;
      ZeroMemory(req); ZeroMemory(res);
      req.action   = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol   = sym;
      req.volume   = vol;
      req.type     = (type==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
      req.price    = (type==POSITION_TYPE_BUY)?curBid:curAsk;
      req.deviation= 20;
      req.type_filling = ORDER_FILLING_IOC;

      bool ok=OrderSend(req,res);
      // v6.15 FIX (Bug 1) — only count as closed if the send genuinely
      // succeeded (TRADE_RETCODE_DONE), not merely "a request was sent".
      // The old version set closedAny=true unconditionally, which meant
      // a REJECTED close order still produced a Telegram message
      // claiming positions had been closed to protect capital — false
      // reassurance during exactly the chaotic conditions that triggered
      // this feature in the first place.
      if(ok && res.retcode==TRADE_RETCODE_DONE) closedCount++;
      else                                      failedCount++;
      Print("[v6.15 VolClose] Extreme volatility — closing ticket=",ticket,
            " vol=",vol," result=",ok," retcode=",res.retcode);
   }

   if(closedCount>0 || failedCount>0)
      g_lastVolCloseTime=TimeCurrent(); // cooldown applies whether or not it fully succeeded, to avoid retry-spam

   if(closedCount>0)
   {
      string msg=E_WARN()+" <b>Extreme Volatility — Position(s) Closed</b>\n"+_Symbol+
                 "\nCurrent candle range exceeded "+DoubleToString(InpVolCloseMult,1)+
                 "x its recent average. "+IntegerToString(closedCount)+" position(s) closed to protect capital.";
      if(failedCount>0)
         msg+="\n"+E_WARN()+" WARNING: "+IntegerToString(failedCount)+
              " close attempt(s) FAILED — check the Experts log and verify manually.";
      PostToTelegram(msg);
   }
   else if(failedCount>0)
   {
      // Every close attempt failed — say so honestly instead of staying silent.
      PostToTelegram(E_WARN()+" <b>Extreme Volatility Detected — Auto-Close FAILED</b>\n"+_Symbol+
                     "\n"+IntegerToString(failedCount)+" close attempt(s) failed. "+
                     "Positions are still OPEN. Check the Experts log and close manually if needed.");
   }
}

void OnTick()
{
   // v6.13 FIX 2/6 — if this instance detected a duplicate at startup,
   // do nothing at all: no signals, no trade management. Keep a visible
   // warning on the chart so it's obvious why nothing is happening.
   if(g_isDuplicate)
   {
      Comment("SignalBot v6.16: DUPLICATE INSTANCE DETECTED on ",_Symbol,
              " — signal generation and trade management are DISABLED here. Remove the duplicate.");
      return;
   }
   UpdateHeartbeat(); // v6.13 — keep this instance's singleton claim fresh

   // v6.14 NEW — extreme-volatility auto-close runs FIRST, before the
   // routine Trade Manager logic below: if capital protection is
   // triggered, there's no point also attempting a partial-close/BE
   // move on the same position in the same tick.
   CloseOnExtremeVolatility();

   // v6.11 — trade management runs every tick, BEFORE the signal
   // bar-close gate below, so open positions are managed in real time
   // regardless of whether a new M5 bar (and therefore a new signal
   // scan) has formed yet.
   ManageOpenPositions();

   // v6.12 — spike detection also runs every tick, independent of
   // the bar-close gate, so it catches a spike mid-candle rather than
   // waiting for the M5 bar to close. v6.13: now also records direction
   // and D1-trend alignment, used by the smarter cooldown logic below.
   CheckVolatilitySpike();

   if(!g_startupSent)
   {
      g_startupSent=true;
      if(InpSendStartupMessage)
      {
         string msg=E_ROBOT()+" <b>SignalBot MT5 v6.16 — Chart Image Attached</b>\n"
                    +SEP()+"\n"
                    +E_CHART()+" Symbol : "+_Symbol+"\n"
                    +E_CLOCK()+" Stack  : W1 > D1 > H4 > H1 > M15 > M5\n"
                    +E_CHECK()+" Kill Zones  : "+(InpKillZoneEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+" Liq Sweep   : "+(InpLiqSweepEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+" FVG         : "+(InpFVGEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+" CHoCH/BOS   : "+(InpCHoCHEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+" Prem/Disc   : "+(InpPDEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+" Divergence  : "+(InpDivEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+" Order Block : "+(InpOBEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+" News Block  : "+(InpNewsEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+" Candle Pat  : "+(InpCandleEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+" Vol Regime  : "+(InpVolRegimeEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+" DXY Filter  : "+(InpDXYEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+ " Min score   : "+IntegerToString(GetEffectiveMinScore())+" / 23"+
                       (InpCrisisMode?" (base "+IntegerToString(InpMinScore)+" +"+IntegerToString(InpCrisisScoreBoost)+" crisis boost)":"")+"\n"
                    +E_CHECK()+ " Trade Mgr   : "+(InpMgrEnable?"ON ("+DoubleToString(InpMgrPartialClosePct,0)+"% @ TP1 + BE)":"OFF")+"\n"
                    +E_WARN()+  " Crisis Mode : "+(InpCrisisMode?"ON (widened SL, raised score)":"off")+"\n"
                    +E_CHECK()+ " Spike Breaker: "+(InpSpikeBreakerEnable?"ON (direction-aware)":"OFF")+"\n"
                    +E_CHECK()+ " Native Calendar: "+(InpCalendarEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+ " Vol Profile : "+(InpVolProfileEnable?"ON":"OFF")+"\n"
                    +E_CHECK()+ " Order Flow  : "+(g_domSubscribed?"ACTIVE":(InpOrderFlowEnable?"unavailable on broker":"OFF"))+"\n"
                    +E_CHECK()+ " COT Bias    : "+(InpCOTEnable?"ON (manual weekly)":"off")+"\n"
                    +E_CHECK()+ " Correlation Cap: "+(InpCorrelationEnable?"ON (max "+IntegerToString(InpMaxCorrelatedPositions)+")":"OFF")+"\n"
                    +E_WARN()+  " Breaking News: "+(InpBreakingNewsEnable?"ON":"off")+"\n"
                    +E_CHECK()+ " Dup Guard   : "+(InpDupGuardEnable?(g_isDuplicate?"DUPLICATE DETECTED":"ON"):"OFF")+"\n"
                    +E_WARN()+  " Vol Auto-Close: "+(InpVolCloseEnable?"ON (closes eligible positions)":"off")+"\n"
                    +E_CHECK()+ " Chart Image : "+(InpChartImageEnable?"ON ("+IntegerToString(InpChartImageWidth)+"x"+IntegerToString(InpChartImageHeight)+")":"OFF")+"\n"
                    +E_CHECK()+ " Monitoring markets...";
         PostToTelegram(msg);
      }
   }

   datetime t=iTime(_Symbol,PERIOD_M5,0);
   if(t==g_lastBarTime) return;
   g_lastBarTime=t;
   PruneMgrProcessed(); // v6.15 — housekeeping, once per bar rather than every tick
   ProcessSignals();
}

//─────────────────────────── BUFFER HELPER ─────────────────────────
double BufVal(int handle,int buf,int shift)
{
   if(handle==INVALID_HANDLE) return(EMPTY_VALUE);
   double b[]; ArraySetAsSeries(b,true);
   int got=CopyBuffer(handle,buf,0,shift+3,b);
   if(got<=shift) return(EMPTY_VALUE);
   return(b[shift]);
}

//─────────────────────────── FILTERS ───────────────────────────────

bool MarketIsTrending()
{
   if(!InpADXEnable) return(true);
   double adx=BufVal(h_adx,0,1);
   if(adx==EMPTY_VALUE) return(true);
   return(adx>=InpADXMinTrend);
}

bool InSession()
{
   if(!InpSessionEnable) return(true);
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   return(dt.hour>=InpSessionStartHour && dt.hour<InpSessionEndHour);
}

bool SpreadOK()
{
   if(!InpSpreadEnable) return(true);
   long spread=(long)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   return(spread<=InpMaxSpreadPoints);
}

// ── NEW 1: Kill Zone ───────────────────────────────────────────────
// Returns true when inside London KZ, NY KZ, or London Close KZ.
// Also returns a string label for the message.
bool InKillZone(string &kzLabel)
{
   if(!InpKillZoneEnable){ kzLabel="Session"; return(true); }
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int h=dt.hour;
   if(h>=InpLKZ_Start  && h<InpLKZ_End) { kzLabel="London KZ";      return(true); }
   if(h>=InpNYKZ_Start && h<InpNYKZ_End){ kzLabel="New York KZ";    return(true); }
   if(h>=InpLCKZ_Start && h<InpLCKZ_End){ kzLabel="London Close KZ";return(true); }
   kzLabel="";
   return(false);
}

// ── NEW 8: News Blackout ────────────────────────────────────────────
// Returns true if current time is within InpNewsBufferMins of any
// configured news time. Times are stored as HHMM integers (e.g. 1330).
bool NewsBlackout()
{
   if(!InpNewsEnable) return(false);
   int times[4];
   times[0]=InpNewsTime1; times[1]=InpNewsTime2;
   times[2]=InpNewsTime3; times[3]=InpNewsTime4;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int nowMins=dt.hour*60+dt.min;
   for(int i=0;i<4;i++)
   {
      if(times[i]==0) continue;
      int hh=times[i]/100, mm=times[i]%100;
      int eventMins=hh*60+mm;
      if(MathAbs(nowMins-eventMins)<=InpNewsBufferMins) return(true);
   }
   return(false);
}

// ── NEW 10: ATR Volatility Regime ──────────────────────────────────
// Returns true when ATR is in the 80–180% band of its own N-bar average.
bool VolRegimeOK()
{
   if(!InpVolRegimeEnable) return(true);
   double cur=BufVal(h_atr,0,1);
   if(cur==EMPTY_VALUE) return(true);
   double arr[]; ArraySetAsSeries(arr,true);
   if(CopyBuffer(h_atr_d1,0,0,InpVolRegimePeriod+2,arr)<=0) return(true);
   double avg=0;
   for(int i=1;i<=InpVolRegimePeriod;i++) avg+=arr[i];
   avg/=InpVolRegimePeriod;
   if(avg<=0) return(true);
   double ratio=cur/avg;
   return(ratio>=InpVolRegimeMin && ratio<=InpVolRegimeMax);
}

//─────────────────────────── BIAS ──────────────────────────────────
int WeeklyBias()
{
   double e=BufVal(h_w_ema,0,1); if(e==EMPTY_VALUE) return(0);
   return(iClose(_Symbol,PERIOD_W1,1)>e?1:-1);
}
int DailyBias()
{
   double m=BufVal(h_d_ma,0,1); if(m==EMPTY_VALUE) return(0);
   double p=iClose(_Symbol,PERIOD_D1,1);
   return(p>m?1:p<m?-1:0);
}
int GoldenDeathCross()
{
   double f0=BufVal(h_d_fast,0,1),s0=BufVal(h_d_slow,0,1);
   double f1=BufVal(h_d_fast,0,2),s1=BufVal(h_d_slow,0,2);
   if(f0==EMPTY_VALUE||s0==EMPTY_VALUE||f1==EMPTY_VALUE||s1==EMPTY_VALUE) return(0);
   if(f1<=s1&&f0>s0) return(1);
   if(f1>=s1&&f0<s0) return(-1);
   return(0);
}
int H1EMABias()
{
   double e=BufVal(h_h1_ema,0,1); if(e==EMPTY_VALUE) return(0);
   double p=iClose(_Symbol,PERIOD_H1,1);
   return(p>e?1:p<e?-1:0);
}

// ── NEW 11: DXY Correlation ─────────────────────────────────────────
// Returns true when the signal direction aligns with expected DXY posture.
// Dollar-positive pairs (USD is base: USDXXX): BUY needs DXY bullish.
// Dollar-negative pairs (USD is quote: XXXUSD): BUY needs DXY bearish.
// Returns true (pass) when DXY not enabled or not available.
bool DXYAligned(int trend)
{
   if(!InpDXYEnable || h_dxy_ma==INVALID_HANDLE) return(true);
   double dxyClose=iClose(ResolveDXYSymbol(),PERIOD_D1,1); // v6.13: uses resolver, not raw input
   double dxyMA   =BufVal(h_dxy_ma,0,1);
   if(dxyMA==EMPTY_VALUE||dxyClose<=0) return(true);
   bool dxyBull=(dxyClose>dxyMA);

   // Check if USD is base currency (first 3 chars)
   string sym=_Symbol;
   bool usdBase  =(StringSubstr(sym,0,3)=="USD");
   bool usdQuote =(StringSubstr(sym,3,3)=="USD");

   if(!usdBase && !usdQuote) return(true); // non-USD pair — skip
   if(usdBase)  return(trend==1 ? dxyBull : !dxyBull);
   return(trend==1 ? !dxyBull : dxyBull);  // usdQuote
}

//─────────────────────────── STRUCTURE ─────────────────────────────
bool SwingHL(double &swH,double &swL)
{
   double hi[],lo[];
   ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
   int n1=CopyHigh(_Symbol,PERIOD_H1,1,InpSwingLookback,hi);
   int n2=CopyLow (_Symbol,PERIOD_H1,1,InpSwingLookback,lo);
   if(n1<=0||n2<=0) return(false);
   swH=-DBL_MAX; swL=DBL_MAX;
   for(int i=0;i<n1;i++) if(hi[i]>swH) swH=hi[i];
   for(int i=0;i<n2;i++) if(lo[i]<swL) swL=lo[i];
   return(swH>-DBL_MAX&&swL<DBL_MAX);
}

bool FibZone(double price,double swH,double swL,int trend,double &a,double &b)
{
   double r=swH-swL; if(r<=0) return(false);
   if(trend==1){a=swH-0.618*r; b=swH-0.500*r;}
   else        {a=swL+0.500*r; b=swL+0.618*r;}
   return(price>=a&&price<=b);
}

bool TwoFractals(bool findHighs,int &idx1,double &p1,int &idx2,double &p2)
{
   int wing=InpFractalWing,total=InpSwingLookback+2*wing+2,found=0;
   int ia[2]; double va[2];
   for(int i=wing;i<total-wing&&found<2;i++)
   {
      double c=findHighs?iHigh(_Symbol,PERIOD_H1,i):iLow(_Symbol,PERIOD_H1,i);
      bool ok=true;
      for(int k=1;k<=wing;k++)
      {
         double prev=findHighs?iHigh(_Symbol,PERIOD_H1,i+k):iLow(_Symbol,PERIOD_H1,i+k);
         double next=findHighs?iHigh(_Symbol,PERIOD_H1,i-k):iLow(_Symbol,PERIOD_H1,i-k);
         if(findHighs){if(c<prev||c<next){ok=false;break;}}
         else         {if(c>prev||c>next){ok=false;break;}}
      }
      if(ok){ia[found]=i;va[found]=c;found++;}
   }
   if(found<2) return(false);
   idx1=ia[0];p1=va[0];idx2=ia[1];p2=va[1];
   return(true);
}
int TrendlineOK(int trend)
{
   int i1,i2; double p1,p2;
   if(trend==1)
   {
      if(!TwoFractals(false,i1,p1,i2,p2)||i2==i1) return(0);
      double s=(p1-p2)/(double)(i2-i1);
      return(iLow(_Symbol,PERIOD_H1,1)>=(p1+s*(i1-1))*0.999?1:0);
   }
   if(trend==-1)
   {
      if(!TwoFractals(true,i1,p1,i2,p2)||i2==i1) return(0);
      double s=(p1-p2)/(double)(i2-i1);
      return(iHigh(_Symbol,PERIOD_H1,1)<=(p1+s*(i1-1))*1.001?-1:0);
   }
   return(0);
}

// ── NEW 4: CHoCH / BOS ─────────────────────────────────────────────
// Scans H1 for the last two fractal swing highs and lows.
// BOS (bullish):  recent close breaks above the last swing high  → +1
// BOS (bearish):  recent close breaks below the last swing low   → -1
// CHoCH detected: opposite break — sets flag but does not score
// Returns: +1 BOS bull, -1 BOS bear, 0 = no confirmed break
int DetectCHoCH_BOS(int trend, bool &chaoch)
{
   chaoch=false;
   if(!InpCHoCHEnable) return(0);

   // Find two most recent swing highs and lows
   int wing=InpFractalWing;
   double lastSwingH=-DBL_MAX, prevSwingH=-DBL_MAX;
   double lastSwingL=DBL_MAX,  prevSwingL=DBL_MAX;
   int hFound=0, lFound=0;

   for(int i=wing; i<InpCHoCHLookback+wing && (hFound<2||lFound<2); i++)
   {
      if(hFound<2)
      {
         double c=iHigh(_Symbol,PERIOD_H1,i);
         bool ok=true;
         for(int k=1;k<=wing;k++)
            if(iHigh(_Symbol,PERIOD_H1,i+k)>=c||iHigh(_Symbol,PERIOD_H1,i-k)>=c){ok=false;break;}
         if(ok){ if(hFound==0) lastSwingH=c; else prevSwingH=c; hFound++; }
      }
      if(lFound<2)
      {
         double c=iLow(_Symbol,PERIOD_H1,i);
         bool ok=true;
         for(int k=1;k<=wing;k++)
            if(iLow(_Symbol,PERIOD_H1,i+k)<=c||iLow(_Symbol,PERIOD_H1,i-k)<=c){ok=false;break;}
         if(ok){ if(lFound==0) lastSwingL=c; else prevSwingL=c; lFound++; }
      }
   }

   double close=iClose(_Symbol,PERIOD_H1,1);

   if(trend==1)
   {
      if(lastSwingH>-DBL_MAX && close>lastSwingH) return(1);  // BOS bullish
      if(lastSwingL<DBL_MAX  && close<lastSwingL){ chaoch=true; return(0); } // CHoCH warning
   }
   else
   {
      if(lastSwingL<DBL_MAX  && close<lastSwingL) return(-1); // BOS bearish
      if(lastSwingH>-DBL_MAX && close>lastSwingH){ chaoch=true; return(0); } // CHoCH warning
   }
   return(0);
}

// ── NEW 5: Premium / Discount Zone ─────────────────────────────────
// Uses HTF (H4 by default) swing range. BUY only in lower 50% (Discount).
// SELL only in upper 50% (Premium).
bool InPremiumDiscount(int trend)
{
   if(!InpPDEnable) return(true);
   double hi[],lo[];
   ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
   if(CopyHigh(_Symbol,InpPDTimeframe,1,InpPDLookback,hi)<=0) return(true);
   if(CopyLow (_Symbol,InpPDTimeframe,1,InpPDLookback,lo)<=0) return(true);
   double rangeH=-DBL_MAX, rangeL=DBL_MAX;
   for(int i=0;i<InpPDLookback;i++){ if(hi[i]>rangeH) rangeH=hi[i]; if(lo[i]<rangeL) rangeL=lo[i]; }
   double mid=(rangeH+rangeL)/2.0;
   double price=iClose(_Symbol,PERIOD_H1,1);
   if(trend==1)  return(price<=mid); // Discount — buy below equilibrium
   return(price>=mid);               // Premium  — sell above equilibrium
}

// ── NEW 3: Fair Value Gap (FVG) ─────────────────────────────────────
// A bullish FVG: candle[i+1].high < candle[i-1].low — gap between wicks
// A bearish FVG: candle[i+1].low  > candle[i-1].high
// v6.1 FIX: now checks the gap hasn't already been fully filled (price
// closed all the way through it) since it formed — a gap that's already
// been filled is no longer a valid magnet for price.
bool InFVG(int trend, double &fvgHigh, double &fvgLow)
{
   fvgHigh=0; fvgLow=0;
   if(!InpFVGEnable) return(false);
   double price=iClose(_Symbol,PERIOD_H1,1);
   for(int i=2;i<=InpFVGLookback;i++)
   {
      double h_prev=iHigh(_Symbol,PERIOD_H1,i+1);
      double l_prev=iLow (_Symbol,PERIOD_H1,i+1);
      double h_next=iHigh(_Symbol,PERIOD_H1,i-1);
      double l_next=iLow (_Symbol,PERIOD_H1,i-1);
      if(trend==1)
      {
         if(h_prev < l_next)
         {
            double zLow=h_prev, zHigh=l_next;
            // NEW: mitigation check — has price already closed BELOW
            // the bottom of this gap since it formed?
            bool filled=false;
            for(int j=1;j<i-1;j++)
               if(iClose(_Symbol,PERIOD_H1,j)<zLow){ filled=true; break; }
            if(filled) continue;
            if(price>=zLow && price<=zHigh){ fvgLow=zLow; fvgHigh=zHigh; return(true); }
         }
      }
      else
      {
         if(l_prev > h_next)
         {
            double zHigh=l_prev, zLow=h_next;
            bool filled=false;
            for(int j=1;j<i-1;j++)
               if(iClose(_Symbol,PERIOD_H1,j)>zHigh){ filled=true; break; }
            if(filled) continue;
            if(price>=zLow && price<=zHigh){ fvgLow=zLow; fvgHigh=zHigh; return(true); }
         }
      }
   }
   return(false);
}

// ── NEW 7: Order Block ──────────────────────────────────────────────
// Bullish OB: last bearish H1 candle before a strong bullish impulse,
// and current price is pulling back into it.
// Bearish OB: last bullish H1 candle before a strong bearish impulse.
// v6.1 FIX: now checks the zone hasn't already been mitigated (price
// already closed through it since it formed) — a zone that's already
// been broken once is a much weaker signal than a fresh, untouched one.
bool InOrderBlock(int trend, double &obHigh, double &obLow)
{
   obHigh=0; obLow=0;
   if(!InpOBEnable) return(false);
   double atr=BufVal(h_atr,0,1); if(atr==EMPTY_VALUE) return(false);
   double price=iClose(_Symbol,PERIOD_H1,1);

   for(int i=3;i<=InpOBLookback;i++)
   {
      double o_imp=iOpen (_Symbol,PERIOD_H1,i-1);
      double c_imp=iClose(_Symbol,PERIOD_H1,i-1);
      double impulse=MathAbs(c_imp-o_imp);
      if(impulse < atr*InpOBImpulseATR) continue;

      if(trend==1 && c_imp>o_imp)
      {
         double ob_o=iOpen (_Symbol,PERIOD_H1,i);
         double ob_c=iClose(_Symbol,PERIOD_H1,i);
         if(ob_c<=ob_o)
         {
            double zLow =MathMin(ob_o,ob_c);
            double zHigh=MathMax(ob_o,ob_c);
            // NEW: mitigation check — has price closed BELOW this zone
            // at any point between formation (bar i) and now (bar 1)?
            bool mitigated=false;
            for(int j=1;j<i;j++)
               if(iClose(_Symbol,PERIOD_H1,j)<zLow){ mitigated=true; break; }
            if(mitigated) continue; // stale zone — keep scanning for a fresher one
            if(price>=zLow && price<=zHigh){ obLow=zLow; obHigh=zHigh; return(true); }
         }
      }
      else if(trend==-1 && c_imp<o_imp)
      {
         double ob_o=iOpen (_Symbol,PERIOD_H1,i);
         double ob_c=iClose(_Symbol,PERIOD_H1,i);
         if(ob_c>=ob_o)
         {
            double zLow =MathMin(ob_o,ob_c);
            double zHigh=MathMax(ob_o,ob_c);
            bool mitigated=false;
            for(int j=1;j<i;j++)
               if(iClose(_Symbol,PERIOD_H1,j)>zHigh){ mitigated=true; break; }
            if(mitigated) continue;
            if(price>=zLow && price<=zHigh){ obLow=zLow; obHigh=zHigh; return(true); }
         }
      }
   }
   return(false);
}

// ── NEW 2: Liquidity Sweep ──────────────────────────────────────────
// BUY: last M15 candle swept below a recent swing low (wick below)
//      then closed back above it — rejection confirmed.
// SELL: last M15 candle swept above a recent swing high, closed below.
bool LiquiditySweep(int trend)
{
   if(!InpLiqSweepEnable) return(false);

   // Find the reference swing level from bars 2..lookback
   double swingL=DBL_MAX, swingH=-DBL_MAX;
   for(int i=2;i<=InpLiqSweepLookback;i++)
   {
      double l=iLow (_Symbol,PERIOD_M15,i);
      double h=iHigh(_Symbol,PERIOD_M15,i);
      if(l<swingL) swingL=l;
      if(h>swingH) swingH=h;
   }

   double o=iOpen (_Symbol,PERIOD_M15,1);
   double h=iHigh (_Symbol,PERIOD_M15,1);
   double l=iLow  (_Symbol,PERIOD_M15,1);
   double c=iClose(_Symbol,PERIOD_M15,1);
   double rng=h-l; if(rng<=0) return(false);

   if(trend==1)
   {
      if(l>=swingL) return(false);         // did not sweep below the low
      if(c<=swingL) return(false);         // did not close back above — not rejected
      double wick=swingL-l;
      if(wick/rng < InpLiqSweepWickRatio) return(false); // wick too short
      return(true);
   }
   else
   {
      if(h<=swingH) return(false);
      if(c>=swingH) return(false);
      double wick=h-swingH;
      if(wick/rng < InpLiqSweepWickRatio) return(false);
      return(true);
   }
}

// ── NEW 6: RSI Divergence ───────────────────────────────────────────
// Scans M15 bars for regular and hidden divergence.
// Regular divergence (reversal):
//   Bullish: price LL, RSI HL
//   Bearish: price HH, RSI LH
// Hidden divergence (continuation):
//   Bullish: price HL, RSI LL
//   Bearish: price LH, RSI HH
// Returns: +1 = bullish divergence, -1 = bearish, 0 = none
// Sets divType: "regular" or "hidden"
int DetectDivergence(int trend, string &divType)
{
   divType="";
   if(!InpDivEnable) return(0);
   int n=InpDivLookback+2;

   double rsiArr[]; ArraySetAsSeries(rsiArr,true);
   if(CopyBuffer(h_rsi,0,0,n,rsiArr)<=0) return(0);

   double priceArr[]; ArraySetAsSeries(priceArr,true);
   if(CopyLow (_Symbol,PERIOD_M15,0,n,priceArr)<=0) return(0); // for bullish
   double priceHArr[]; ArraySetAsSeries(priceHArr,true);
   if(CopyHigh(_Symbol,PERIOD_M15,0,n,priceHArr)<=0) return(0); // for bearish

   // Find two most recent swing lows in price and RSI (for bullish div)
   if(trend==1)
   {
      double p1=-DBL_MAX,p2=-DBL_MAX; double r1=-DBL_MAX,r2=-DBL_MAX;
      int found=0;
      for(int i=2;i<n-2&&found<2;i++)
      {
         if(priceArr[i]<priceArr[i+1]&&priceArr[i]<priceArr[i-1])
         {
            if(found==0){p1=priceArr[i];r1=rsiArr[i];}
            else        {p2=priceArr[i];r2=rsiArr[i];}
            found++;
         }
      }
      if(found<2) return(0);
      // Regular bullish: price LL (p1<p2), RSI HL (r1>r2)
      if(p1<p2 && r1>r2){ divType="regular"; return(1); }
      // Hidden bullish:  price HL (p1>p2), RSI LL (r1<r2)
      if(p1>p2 && r1<r2){ divType="hidden";  return(1); }
   }
   else // trend==-1
   {
      double p1=-DBL_MAX,p2=-DBL_MAX; double r1=-DBL_MAX,r2=-DBL_MAX;
      int found=0;
      for(int i=2;i<n-2&&found<2;i++)
      {
         if(priceHArr[i]>priceHArr[i+1]&&priceHArr[i]>priceHArr[i-1])
         {
            if(found==0){p1=priceHArr[i];r1=rsiArr[i];}
            else        {p2=priceHArr[i];r2=rsiArr[i];}
            found++;
         }
      }
      if(found<2) return(0);
      // Regular bearish: price HH (p1>p2), RSI LH (r1<r2)
      if(p1>p2 && r1<r2){ divType="regular"; return(-1); }
      // Hidden bearish:  price LH (p1<p2), RSI HH (r1>r2)
      if(p1<p2 && r1>r2){ divType="hidden";  return(-1); }
   }
   return(0);
}

// ── NEW 9: Candle Pattern Confirmation ─────────────────────────────
// Checks the last closed M15 candle for engulfing, pin bar, or inside bar.
// Returns +1 (bullish pattern), -1 (bearish), 0 (no pattern).
int CandlePattern(int trend)
{
   if(!InpCandleEnable) return(1); // disabled — pass through
   double o1=iOpen (_Symbol,PERIOD_M15,1), c1=iClose(_Symbol,PERIOD_M15,1);
   double h1=iHigh (_Symbol,PERIOD_M15,1), l1=iLow  (_Symbol,PERIOD_M15,1);
   double o2=iOpen (_Symbol,PERIOD_M15,2), c2=iClose(_Symbol,PERIOD_M15,2);
   double h2=iHigh (_Symbol,PERIOD_M15,2), l2=iLow  (_Symbol,PERIOD_M15,2);
   double rng1=h1-l1; if(rng1<=0) return(0);
   double body1=MathAbs(c1-o1);

   // Bullish engulfing
   if(trend==1 && c2<o2 && c1>o1 && c1>o2 && o1<c2) return(1);
   // Bearish engulfing
   if(trend==-1 && c2>o2 && c1<o1 && c1<o2 && o1>c2) return(-1);

   // Bullish pin bar: lower wick >= ratio of range, small body in upper portion
   if(trend==1)
   {
      double lowerWick=MathMin(o1,c1)-l1;
      if(lowerWick/rng1>=InpPinWickRatio && body1/rng1<=0.3) return(1);
   }
   // Bearish pin bar: upper wick >= ratio of range
   if(trend==-1)
   {
      double upperWick=h1-MathMax(o1,c1);
      if(upperWick/rng1>=InpPinWickRatio && body1/rng1<=0.3) return(-1);
   }

   // Inside bar (compression before expansion)
   if(h1<h2 && l1>l2) return(trend); // inside bar in trend direction — valid

   return(0); // no pattern
}

//─────────────────────────── TRIGGERS ──────────────────────────────
int RSI15(double &val)
{
   val=BufVal(h_rsi,0,1); double r1=BufVal(h_rsi,0,2);
   if(val==EMPTY_VALUE||r1==EMPTY_VALUE) return(0);
   if(r1<InpRSIOversold  &&val>=InpRSIOversold)  return(1);
   if(r1>InpRSIOverbought&&val<=InpRSIOverbought) return(-1);
   if(val<InpRSIOversold  +10) return(1);
   if(val>InpRSIOverbought-10) return(-1);
   return(0);
}
int MACD15()
{
   double m0=BufVal(h_macd,0,1),m1=BufVal(h_macd,0,2);
   double s0=BufVal(h_macd,1,1),s1=BufVal(h_macd,1,2);
   if(m0==EMPTY_VALUE||s0==EMPTY_VALUE) return(0);
   if(m1<=s1&&m0>s0) return(1);
   if(m1>=s1&&m0<s0) return(-1);
   double h0=m0-s0,h1=m1-s1;
   if(h0>0&&h0>h1) return(1);
   if(h0<0&&h0<h1) return(-1);
   return(0);
}
int Vol15(int trend)
{
   long vols[]; ArraySetAsSeries(vols,true);
   if(CopyTickVolume(_Symbol,PERIOD_M15,1,21,vols)<=0) return(0);
   double avg=0; for(int i=1;i<=20;i++) avg+=vols[i]; avg/=20.0;
   if(vols[0]<avg*InpVolumeMultiplier) return(0);
   double o=iOpen(_Symbol,PERIOD_M15,1),c=iClose(_Symbol,PERIOD_M15,1);
   if(trend==1 &&c>o) return(1);
   if(trend==-1&&c<o) return(-1);
   return(0);
}
int M5EMA()
{
   double f0=BufVal(h_m5_ef,0,1),s0=BufVal(h_m5_es,0,1);
   double f1=BufVal(h_m5_ef,0,2),s1=BufVal(h_m5_es,0,2);
   if(f0==EMPTY_VALUE||s0==EMPTY_VALUE) return(0);
   if(f1<=s1&&f0>s0) return(1);
   if(f1>=s1&&f0<s0) return(-1);
   return(f0>s0?1:f0<s0?-1:0);
}
int M5RSI(double &val)
{
   val=BufVal(h_m5_rsi,0,1); double r1=BufVal(h_m5_rsi,0,2);
   if(val==EMPTY_VALUE) return(0);
   if(r1<InpM5RSIOversold  &&val>=InpM5RSIOversold)  return(1);
   if(r1>InpM5RSIOverbought&&val<=InpM5RSIOverbought) return(-1);
   if(val<InpM5RSIOversold  +8) return(1);
   if(val>InpM5RSIOverbought-8) return(-1);
   return(0);
}
int M5MACD()
{
   double m0=BufVal(h_m5_macd,0,1),m1=BufVal(h_m5_macd,0,2);
   double s0=BufVal(h_m5_macd,1,1),s1=BufVal(h_m5_macd,1,2);
   if(m0==EMPTY_VALUE||s0==EMPTY_VALUE) return(0);
   if(m1<=s1&&m0>s0) return(1);
   if(m1>=s1&&m0<s0) return(-1);
   double hh0=m0-s0,hh1=m1-s1;
   if(hh0>0&&hh0>hh1) return(1);
   if(hh0<0&&hh0<hh1) return(-1);
   return(0);
}

//─────────────────────────── AMD ───────────────────────────────────
int AMD(int trend,double &amdH,double &amdL)
{
   if(!InpAMDEnable) return(0);
   double atr=BufVal(h_atr,0,1);
   if(atr==EMPTY_VALUE||atr<=0) return(0);
   amdH=-DBL_MAX; amdL=DBL_MAX;
   for(int i=2;i<2+InpAMDAccumBars;i++)
   {
      double h=iHigh(_Symbol,PERIOD_M15,i);
      double l=iLow (_Symbol,PERIOD_M15,i);
      if(h>amdH) amdH=h;
      if(l<amdL) amdL=l;
   }
   if(amdH-amdL>=atr*InpAMDATRRatio) return(0);
   double o=iOpen(_Symbol,PERIOD_M15,1),h=iHigh(_Symbol,PERIOD_M15,1);
   double l=iLow(_Symbol,PERIOD_M15,1), c=iClose(_Symbol,PERIOD_M15,1);
   double rng=h-l; if(rng<=0) return(0);
   if(trend==1 &&l<amdL&&c>=amdL&&(MathMin(o,c)-l)/rng>=InpAMDWickRatio) return(1);
   if(trend==-1&&h>amdH&&c<=amdH&&(h-MathMax(o,c))/rng>=InpAMDWickRatio) return(-1);
   return(0);
}

//─────────────────────────── STRUCTURAL SL ─────────────────────────
// v6.1 FIX: Two bugs from v6.0 corrected here.
//  (1) InpFractalWing raised to 4 by default — a 2-bar wing picks up
//      normal candle noise, not real structure.
//  (2) A hard minimum distance (InpMinSLATRMult × ATR) is now enforced.
//      v6.0 had no floor — SL could land inside normal spread/noise
//      range, causing near-instant stop-outs regardless of direction.
//      The scanner now KEEPS SEARCHING past a too-tight fractal instead
//      of breaking immediately, looking for the nearest one that also
//      clears the minimum distance.
double GetStructuralSL(int trend, double entry)
{
   double atr=BufVal(h_atr,0,1); if(atr==EMPTY_VALUE) atr=0;
   double buffer=atr*0.3;
   double effMinMult=GetEffectiveMinSLATRMult();  // v6.12: Crisis Mode-aware floor
   double minDist=atr*effMinMult;   // NEW floor
   double maxDist=atr*3.0;
   int    wing=InpFractalWing;
   int    total=InpSwingLookback+2*wing+2;

   if(trend==1)
   {
      for(int i=wing;i<total-wing;i++)
      {
         double c=iLow(_Symbol,PERIOD_H1,i);
         bool ok=true;
         for(int k=1;k<=wing;k++)
            if(iLow(_Symbol,PERIOD_H1,i+k)<=c||iLow(_Symbol,PERIOD_H1,i-k)<=c){ok=false;break;}
         if(!ok) continue;
         double sl=c-buffer;
         double dist=entry-sl;
         // NEW: must clear the floor AND stay under the ceiling —
         // if too tight, don't break, keep looking for the next fractal
         if(sl<entry && dist>=minDist && dist<=maxDist) return(sl);
      }
      // No fractal in the valid band — fall back to a fixed-ATR SL,
      // but the fallback itself now respects the same floor.
      return(entry-atr*MathMax(InpSLATRMult,effMinMult));
   }
   else
   {
      for(int i=wing;i<total-wing;i++)
      {
         double c=iHigh(_Symbol,PERIOD_H1,i);
         bool ok=true;
         for(int k=1;k<=wing;k++)
            if(iHigh(_Symbol,PERIOD_H1,i+k)>=c||iHigh(_Symbol,PERIOD_H1,i-k)>=c){ok=false;break;}
         if(!ok) continue;
         double sl=c+buffer;
         double dist=sl-entry;
         if(sl>entry && dist>=minDist && dist<=maxDist) return(sl);
      }
      return(entry+atr*MathMax(InpSLATRMult,effMinMult));
   }
}

//─────────────────────────── ROUND NUMBER FILTER ───────────────────
double RoundNumberAdjust(double price, int trend, bool isSL)
{
   double point   = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double interval= (digits>=4) ? 100.0*point : 10.0*point;
   double zone    = 8.0*point;
   double nearest = MathRound(price/interval)*interval;
   double dist    = MathAbs(price-nearest);
   if(dist>zone) return(price);
   double shift=(zone-dist)+2.0*point;
   // v6.15 NOTE: for a BUY, SL sits below entry (moving it further away
   // means subtracting) and TP sits above entry (moving it closer to
   // entry ALSO means subtracting) — so the same expression is correct
   // for both isSL=true and isSL=false by genuine geometric coincidence,
   // not by accident of copy-paste. Written as one path instead of two
   // identical branches to make that explicit rather than implying
   // divergent logic that doesn't actually exist. The isSL parameter is
   // kept in the signature for call-site clarity and future divergence.
   return(trend==1 ? price-shift : price+shift);
}

//─────────────────────────── TRADE LEVELS ──────────────────────────
void Levels(int trend, double &entry, double &sl, double &tp1, double &tp2, double &tp3)
{
   if(trend==1) entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   else         entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   sl=GetStructuralSL(trend,entry);
   sl=RoundNumberAdjust(sl,trend,true);

   double slDist=MathAbs(entry-sl);

   if(trend==1)
   {
      tp1=entry+slDist*InpTP1Ratio;
      tp2=entry+slDist*InpRRRatio;
      tp3=entry+slDist*InpTP3Ratio;
   }
   else
   {
      tp1=entry-slDist*InpTP1Ratio;
      tp2=entry-slDist*InpRRRatio;
      tp3=entry-slDist*InpTP3Ratio;
   }

   tp1=RoundNumberAdjust(tp1,trend,false);
   tp2=RoundNumberAdjust(tp2,trend,false);
   tp3=RoundNumberAdjust(tp3,trend,false);
}

//─────────────────────────── TELEGRAM ──────────────────────────────
string FormEncode(string text)
{
   uchar bytes[];
   int n=StringToCharArray(text,bytes,0,StringLen(text),CP_UTF8)-1;
   if(n<=0) return("");
   string hex="0123456789ABCDEF", out="";
   for(int i=0;i<n;i++)
   {
      uchar c=bytes[i];
      if((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||
         c=='-'||c=='_'||c=='.'||c=='~')
         out+=CharToString(c);
      else if(c==' ') out+="+";
      else out+="%"+StringSubstr(hex,c/16,1)+StringSubstr(hex,c%16,1);
   }
   return(out);
}
bool PostToTelegram(string text)
{
   string url="https://api.telegram.org/bot"+InpBotToken+"/sendMessage";
   string body="chat_id="+InpChatID+"&parse_mode=HTML&text="+FormEncode(text);
   uchar bodyBytes[];
   int bodyLen=StringLen(body);
   ArrayResize(bodyBytes,bodyLen);
   for(int i=0;i<bodyLen;i++) bodyBytes[i]=(uchar)StringGetCharacter(body,i);
   uchar result[]; string respHeaders;
   ResetLastError();
   int code=WebRequest("POST",url,
                       "Content-Type: application/x-www-form-urlencoded\r\n",
                       5000,bodyBytes,result,respHeaders);
   if(code==-1)
   { Print("Telegram error ",GetLastError()," -- add https://api.telegram.org to allowed URLs"); return(false); }
   if(code!=200) Print("Telegram HTTP ",code,": ",CharArrayToString(result));
   return(code==200);
}

//─────────────────────────── v6.16 CHART IMAGE ATTACHMENT ──────────
// Draws Entry/SL/TP1/TP2/TP3 as horizontal lines on THIS chart, each
// with a colored screen-anchored label positioned at the line's actual
// pixel height, then screenshots the chart and uploads it to Telegram
// via a hand-built multipart/form-data POST to sendPhoto. The existing
// text signal message (PostToTelegram) is completely untouched — this
// runs as a separate, additional step right after it.

void CreateSignalHLine(string name,double price,color col,string label)
{
   ObjectDelete(0,name);
   ObjectDelete(0,name+"_LBL");

   ObjectCreate(0,name,OBJ_HLINE,0,0,price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,col);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DASH);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetString(0,name,OBJPROP_TEXT,label+" "+DoubleToString(price,_Digits));

   // Position a screen-anchored label at the line's actual pixel height
   // so it reads clearly in the screenshot regardless of chart scroll.
   ChartRedraw(0);
   int x=0,y=0;
   if(ChartTimePriceToXY(0,0,TimeCurrent(),price,x,y))
   {
      string lbl=name+"_LBL";
      ObjectCreate(0,lbl,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,lbl,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,lbl,OBJPROP_XDISTANCE,MathMax(x-140,5));
      ObjectSetInteger(0,lbl,OBJPROP_YDISTANCE,MathMax(y-8,0));
      ObjectSetString(0,lbl,OBJPROP_TEXT,label+"  "+DoubleToString(price,_Digits));
      ObjectSetInteger(0,lbl,OBJPROP_COLOR,col);
      ObjectSetInteger(0,lbl,OBJPROP_FONTSIZE,9);
      ObjectSetInteger(0,lbl,OBJPROP_SELECTABLE,false);
   }
}

void DrawSignalChart(int trend,double entry,double sl,double tp1,double tp2,double tp3)
{
   // Clear only THIS bot's own annotation objects (fixed prefix) before
   // redrawing, so old signals' lines don't stack up over time and
   // nothing belonging to the user is ever touched.
   ObjectsDeleteAll(0,"SIGIMG_");

   CreateSignalHLine("SIGIMG_ENTRY",entry,InpChartImgEntryColor,"ENTRY");
   CreateSignalHLine("SIGIMG_SL",   sl,   InpChartImgSLColor,   "SL");
   CreateSignalHLine("SIGIMG_TP1",  tp1,  InpChartImgTP1Color, "TP1");
   CreateSignalHLine("SIGIMG_TP2",  tp2,  InpChartImgTP2Color, "TP2");
   CreateSignalHLine("SIGIMG_TP3",  tp3,  InpChartImgTP3Color, "TP3");

   ChartRedraw(0);
}

bool CaptureChartScreenshot(string filename)
{
   ChartRedraw(0);
   Sleep(200); // brief pause so the redraw fully completes before capture
   bool ok=ChartScreenShot(0,filename,InpChartImageWidth,InpChartImageHeight,ALIGN_RIGHT);
   if(!ok) Print("[v6.16 ChartImage] ChartScreenShot failed, err=",GetLastError());
   return(ok);
}

bool SendTelegramPhoto(string filepath)
{
   int fh=FileOpen(filepath,FILE_READ|FILE_BIN);
   if(fh==INVALID_HANDLE)
   {
      Print("[v6.16 ChartImage] Could not open screenshot file '",filepath,"' err=",GetLastError());
      return(false);
   }
   int fsize=(int)FileSize(fh);
   uchar fileBytes[];
   ArrayResize(fileBytes,fsize);
   FileReadArray(fh,fileBytes,0,fsize);
   FileClose(fh);

   string boundary="----MT5Boundary"+IntegerToString((int)GetTickCount());
   string head="--"+boundary+"\r\n"+
               "Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n"+
               InpChatID+"\r\n"+
               "--"+boundary+"\r\n"+
               "Content-Disposition: form-data; name=\"photo\"; filename=\"chart.png\"\r\n"+
               "Content-Type: image/png\r\n\r\n";
   string tail="\r\n--"+boundary+"--\r\n";

   int headLen=StringLen(head);
   int tailLen=StringLen(tail);
   uchar headBytes[]; StringToCharArray(head,headBytes,0,headLen);
   uchar tailBytes[]; StringToCharArray(tail,tailBytes,0,tailLen);

   // Concatenate head + raw file bytes + tail into one body. Using
   // explicit lengths (not ArraySize) throughout, since StringToCharArray
   // may include a trailing null beyond the requested count depending on
   // build — indexing only 0..len-1 sidesteps that entirely.
   uchar body[];
   int total=headLen+fsize+tailLen;
   ArrayResize(body,total);
   int pos=0;
   for(int i=0;i<headLen;i++) body[pos++]=headBytes[i];
   for(int i=0;i<fsize;i++)   body[pos++]=fileBytes[i];
   for(int i=0;i<tailLen;i++) body[pos++]=tailBytes[i];

   string url="https://api.telegram.org/bot"+InpBotToken+"/sendPhoto";
   string headers="Content-Type: multipart/form-data; boundary="+boundary+"\r\n";
   uchar result[]; string respHeaders;

   ResetLastError();
   int code=WebRequest("POST",url,headers,8000,body,result,respHeaders);
   if(code==-1)
   { Print("[v6.16 ChartImage] sendPhoto error ",GetLastError()," -- api.telegram.org should already be whitelisted"); return(false); }
   if(code!=200)
   { Print("[v6.16 ChartImage] sendPhoto HTTP ",code,": ",CharArrayToString(result)); return(false); }
   return(true);
}

//─────────────────────────── FACEBOOK ──────────────────────────────
bool SendFacebookSignal(string dir,double entry,double sl,double tp1,double tp2)
{
   if(!InpFacebookEnable) return(true);
   string body="symbol="+_Symbol+"&direction="+dir
              +"&entry="+DoubleToString(entry,5)
              +"&sl="+DoubleToString(sl,5)
              +"&tp="+DoubleToString(tp1,5)
              +"&tp2="+DoubleToString(tp2,5)
              +"&basis="+InpFacebookBasis;
   uchar bArr[],res[]; string hdrs;
   StringToCharArray(body,bArr,0,StringLen(body));
   int code=WebRequest("POST",InpFacebookURL,
                       "Content-Type: application/x-www-form-urlencoded\r\n",
                       3000,bArr,res,hdrs);
   return(code==200);
}

//─────────────────────────── MAIN LOGIC ────────────────────────────
void ProcessSignals()
{
   // Golden / Death cross — independent of all filters
   int cross=GoldenDeathCross();
   if(cross!=0&&InpAlertGoldenDeathCross)
   {
      string icon=(cross==1)?E_STAR():E_SKULL();
      string msg=icon+" <b>"+(cross==1?"GOLDEN":"DEATH")+" CROSS - "+_Symbol+"</b>\n"
                 +SEP()+"\n"
                 +"Daily MA"+IntegerToString(InpCrossFastMA)
                 +" crossed "+(cross==1?"above":"below")
                 +" MA"+IntegerToString(InpCrossSlowMA)+"\n"
                 +"Bias : "+(cross==1?"Bullish":"Bearish")+"\n"
                 +E_CLOCK()+" "+TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES);
      PostToTelegram(msg);
   }

   if(!InpAlertFullSignal) return;

   // ── v6.12/13 Hard Gates — macro-risk awareness, checked first ───
   if(SymbolSuspendedByCrisis()) return;   // A. this symbol fully paused during crisis mode
   if(CalendarBlackout())        return;   // C. inside a native-calendar high-impact event window
   if(BreakingNewsCheck())       return;   // v6.13 Fix 9 — breaking-news keyword match still cooling down

   // ── Hard Gate Filters (any fail = no signal) ──────────────────
   if(!InSession())        return;
   if(!SpreadOK())         return;
   if(!MarketIsTrending()) return;
   if(!VolRegimeOK())      return; // NEW 10
   if(NewsBlackout())      return; // NEW 8 (manual calendar — still runs alongside C)

   // ── Kill Zone check — must be inside one ─────────────────────
   string kzLabel;
   if(!InKillZone(kzLabel)) return; // NEW 1

   // ── Bias ──────────────────────────────────────────────────────
   int wb=WeeklyBias(), db=DailyBias();
   if(db==0) return;
   int trend=db;

   // v6.13 Fix 8 — spike cooldown moved here (needs trend to apply the
   // direction-aware logic: same-direction-as-spike signals may pass
   // if the spike was aligned with the D1 trend; everything else blocks).
   if(InSpikeCooldown(trend)) return;

   // v6.13 Fix 5 — portfolio correlation cap (checked before the more
   // expensive structure/confluence work below, same as other gates).
   if(InpCorrelationEnable && CountCorrelatedUSDExposure(trend) >= InpMaxCorrelatedPositions) return;

   // ── DXY Correlation ───────────────────────────────────────────
   if(!DXYAligned(trend)) return; // NEW 11

   // ── Premium / Discount Gate ───────────────────────────────────
   if(!InPremiumDiscount(trend)) return; // NEW 5

   // ── Structure ─────────────────────────────────────────────────
   double swH,swL;
   if(!SwingHL(swH,swL)) return;
   double price=iClose(_Symbol,PERIOD_H1,1);
   double fibA,fibB;
   bool fib=FibZone(price,swH,swL,trend,fibA,fibB);
   int  tl =TrendlineOK(trend);
   int  h1e=H1EMABias();

   // ── CHoCH / BOS ───────────────────────────────────────────────
   bool chaoch=false;
   int  bos=DetectCHoCH_BOS(trend,chaoch); // NEW 4
   if(chaoch) return; // CHoCH against trend direction — skip signal

   // ── FVG ───────────────────────────────────────────────────────
   double fvgH,fvgL;
   bool fvgOK=InFVG(trend,fvgH,fvgL); // NEW 3

   // ── Order Block ───────────────────────────────────────────────
   double obH,obL;
   bool obOK=InOrderBlock(trend,obH,obL); // NEW 7

   // ── Liquidity Sweep ───────────────────────────────────────────
   bool sweep=LiquiditySweep(trend); // NEW 2

   // ── RSI Divergence ────────────────────────────────────────────
   string divType;
   int divDir=DetectDivergence(trend,divType); // NEW 6
   bool divOK=(divDir==trend);

   // ── Triggers ─────────────────────────────────────────────────
   double rsiVal; int rsi15=RSI15(rsiVal);
   int mac15=MACD15();
   int vol15=Vol15(trend);
   int emaCross=M5EMA();
   double m5rsi; int rsi5=M5RSI(m5rsi);
   int mac5=M5MACD();

   // ── Candle Pattern ────────────────────────────────────────────
   int candlePat=CandlePattern(trend); // NEW 9

   // ── AMD ───────────────────────────────────────────────────────
   double amdH,amdL;
   bool amdOK=(AMD(trend,amdH,amdL)==trend);

   // ── v6.13 NEW: Volume Profile / Order Flow / COT ──────────────
   // Preview entry price (same value Levels() will use) — needed here
   // because these confluence checks run before Levels() is called.
   double previewEntry=(trend==1) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                                   : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double vpPOC,vpVAHigh,vpVALow;
   bool vpAligned=GetVolumeProfile(trend,previewEntry,vpPOC,vpVAHigh,vpVALow);
   bool ofAligned=GetOrderFlowImbalance(trend);
   int  cotBias=GetCOTBias();
   bool cotAligned=(InpCOTEnable && cotBias==trend);

   // ── Weighted Confluence Score (max 23) ────────────────────────
   //
   // HTF Alignment           (max 5)
   //   D1 bias                      +3
   //   W1 alignment                 +2
   //
   // Institutional Structure (max 6)
   //   BOS confirmation             +2
   //   Order Block                  +2
   //   FVG (price inside gap)       +2
   //
   // Entry Precision         (max 5)
   //   Liquidity Sweep              +2
   //   Kill Zone bonus              +1
   //   AMD Judas swing              +1
   //   RSI Divergence               +1 (regular +1, hidden +1)
   //
   // Supporting Confluence   (max 4)
   //   H1 EMA                       +1
   //   H1 Trendline                 +1
   //   Fibonacci zone               +1
   //   Candle pattern               +1
   //
   // Advanced Data (v6.13)   (max 3)
   //   Volume Profile (POC/VA)      +1
   //   Order Flow (DOM imbalance)   +1  (0 if broker doesn't expose DOM)
   //   COT bias (manual weekly)     +1  (0 unless InpCOTEnable configured)
   //
   // Momentum triggers (min 1 required, not scored to avoid inflation)

   int score=0;

   // HTF Alignment
   if(db==trend)   score+=3;
   if(wb==trend)   score+=2;

   // Institutional Structure
   if(bos==trend)  score+=2;
   if(obOK)        score+=2;
   if(fvgOK)       score+=2;

   // Entry Precision
   if(sweep)       score+=2;
   if(kzLabel!="") score+=1;
   if(amdOK)       score+=1;
   if(divOK)       score+=1;

   // Supporting Confluence
   if(h1e==trend)  score+=1;
   if(tl==trend)   score+=1;
   if(fib)         score+=1;
   if(candlePat==trend) score+=1;

   // Advanced Data (v6.13)
   if(vpAligned)   score+=1;
   if(ofAligned)   score+=1;
   if(cotAligned)  score+=1;

   // Momentum: at least one trigger required
   bool trigger=(rsi15==trend||mac15==trend||emaCross==trend||rsi5==trend);

   if(InpDebugLog)
   {
      double adxVal=BufVal(h_adx,0,1);
      long   spread=(long)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
      Print(_Symbol," trend=",trend," score=",score,"/23",
            " bos=",bos," ob=",obOK," fvg=",fvgOK,
            " sweep=",sweep," kz=",kzLabel,
            " div=",divOK,"(",divType,")",
            " amd=",amdOK," candle=",candlePat,
            " rsi15=",rsi15," mac15=",mac15,
            " ADX=",DoubleToString(adxVal,1)," spread=",spread);

      // v6.1 NEW — per-factor score breakdown so you can see, trade by
      // trade, which confluences actually fired. After the simulation
      // runs, cross-reference this against win/loss outcomes: if a
      // factor is present on most of the losers and absent on most of
      // the winners, that factor is noise and should be down-weighted
      // or disabled (InpXxxEnable=false) rather than trusted.
      Print("  SCORE BREAKDOWN | D1:",(db==trend?3:0),
            " W1:",(wb==trend?2:0),
            " BOS:",(bos==trend?2:0),
            " OB:",(obOK?2:0),
            " FVG:",(fvgOK?2:0),
            " Sweep:",(sweep?2:0),
            " KZ:",(kzLabel!=""?1:0),
            " AMD:",(amdOK?1:0),
            " Div:",(divOK?1:0),
            " H1e:",(h1e==trend?1:0),
            " TL:",(tl==trend?1:0),
            " Fib:",(fib?1:0),
            " Candle:",(candlePat==trend?1:0),
            " VolProfile:",(vpAligned?1:0),
            " OrderFlow:",(ofAligned?1:0),
            " COT:",(cotAligned?1:0));
   }

   // v6.15 FIX — InpShowWatchSignals was declared but never actually used
   // anywhere (a dead input a user could toggle with zero effect). Now
   // wired to real behavior: if a setup clears every hard gate and has a
   // live momentum trigger, but doesn't reach the full signal threshold,
   // optionally send a lightweight heads-up — NOT a trade signal, no
   // entry/SL/TP, just "this is developing, worth watching." Uses its
   // own cooldown (g_lastWatchTime) so it can't spam every 5 minutes.
   if(!trigger) return;
   if(score<GetEffectiveMinScore())
   {
      int watchCoolSecs=InpCooldownBars*300;
      if(InpShowWatchSignals && score>=8 &&
         (g_lastWatchTime==0 || TimeCurrent()-g_lastWatchTime>=watchCoolSecs))
      {
         g_lastWatchTime=TimeCurrent();
         string wmsg=E_WARN()+" <b>WATCH — "+_Symbol+" "+(trend==1?"BUY":"SELL")+" building</b>\n"
                     +SEP()+"\n"
                     +"Score: "+IntegerToString(score)+"/23  (needs "+
                     IntegerToString(GetEffectiveMinScore())+"+ to fire as a full signal)\n"
                     +"Zone: "+(kzLabel!=""?kzLabel:"outside Kill Zone")+"\n"
                     +E_CLOCK()+" "+TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES);
         PostToTelegram(wmsg);
      }
      return;
   }
   if(candlePat!=trend && InpCandleEnable) return; // require candle confirmation

   // ── Cooldown ──────────────────────────────────────────────────
   int coolSecs=InpCooldownBars*300;
   if(g_lastSignalTime!=0&&TimeCurrent()-g_lastSignalTime<coolSecs) return;

   // ── Levels ────────────────────────────────────────────────────
   double entry,sl,tp1,tp2,tp3;
   Levels(trend,entry,sl,tp1,tp2,tp3);
   double slDist=MathAbs(entry-sl);
   double rr2=InpRRRatio;
   double rr3=InpTP3Ratio;

   // ── Score Label ───────────────────────────────────────────────
   string scoreLabel;
   if(score>=18)      scoreLabel=E_FIRE()+" ELITE    ("+IntegerToString(score)+"/23)";
   else if(score>=14) scoreLabel=E_FIRE()+" STRONG   ("+IntegerToString(score)+"/23)";
   else if(score>=10) scoreLabel=E_CHECK()+" MODERATE ("+IntegerToString(score)+"/23)";
   else               scoreLabel=E_WARN()+" WATCH    ("+IntegerToString(score)+"/23)";

   // ── Confluence Summary for message ────────────────────────────
   string conf="";
   if(bos==trend)      conf+="BOS ";
   if(obOK)            conf+="OB ";
   if(fvgOK)           conf+="FVG ";
   if(sweep)           conf+="LiqSweep ";
   if(divOK)           conf+=StringSubstr(divType,0,3)+"Div ";
   if(amdOK)           conf+="AMD ";
   if(fib)             conf+="Fib ";
   if(tl==trend)       conf+="TL ";
   if(candlePat==trend)conf+="CandlePat ";
   if(vpAligned)        conf+="VolProfile ";
   if(ofAligned)        conf+="OrderFlow ";
   if(cotAligned)        conf+="COT ";
   if(StringLen(conf)>0) conf=StringSubstr(conf,0,StringLen(conf)-1);

   // Breakeven level = entry ± 1R
   double beLevel=(trend==1)?(entry+slDist):(entry-slDist);

   // ── Telegram Message ─────────────────────────────────────────
   string msg;
   if(trend==1)
   {
      msg=E_GREEN()+E_GREEN()+E_GREEN()+"  <b>B U Y  S I G N A L</b>  "+E_GREEN()+E_GREEN()+E_GREEN()+"\n"
          +SEP()+"\n"
          +E_MONEY()+"  <b>"+_Symbol+"</b>   "+E_ZONE()+" "+kzLabel+"\n"
          +E_UP()+   "  <b>BUY</b>     "+scoreLabel+"\n"
          +SEP()+"\n"
          +E_TARGET()+"  Entry  :  <b>"+DoubleToString(entry,5)+"</b>\n"
          +E_STOP()+  "  SL     :  "+DoubleToString(sl,5)+"\n"
          +E_CHECK()+ "  TP1    :  "+DoubleToString(tp1,5)+"  (1:"+DoubleToString(InpTP1Ratio,1)+")\n"
          +E_CHECK()+ "  TP2    :  "+DoubleToString(tp2,5)+"  (1:"+DoubleToString(rr2,1)+")\n"
          +E_CHECK()+ "  TP3    :  "+DoubleToString(tp3,5)+"  (1:"+DoubleToString(rr3,1)+")\n"
          +E_RULER()+ "  R : R  :  1 : "+DoubleToString(rr2,1)+" / 1:"+DoubleToString(rr3,1)+"\n"
          +SEP()+"\n"
          +E_LOCK()+  "  Move SL to BE  :  "+DoubleToString(beLevel,5)+"\n"
          +E_WARN()+  "  Close 50% at TP1, trail to TP2, let 25% run to TP3\n"
          +SEP()+"\n"
          +E_SWEEP()+ "  Confluence : "+conf+"\n"
          +E_CLOCK()+ "  "+TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES);
   }
   else
   {
      msg=E_RED()+E_RED()+E_RED()+"  <b>S E L L  S I G N A L</b>  "+E_RED()+E_RED()+E_RED()+"\n"
          +SEP()+"\n"
          +E_MONEY()+"  <b>"+_Symbol+"</b>   "+E_ZONE()+" "+kzLabel+"\n"
          +E_DOWN()+ "  <b>SELL</b>   "+scoreLabel+"\n"
          +SEP()+"\n"
          +E_TARGET()+"  Entry  :  <b>"+DoubleToString(entry,5)+"</b>\n"
          +E_STOP()+  "  SL     :  "+DoubleToString(sl,5)+"\n"
          +E_CHECK()+ "  TP1    :  "+DoubleToString(tp1,5)+"  (1:"+DoubleToString(InpTP1Ratio,1)+")\n"
          +E_CHECK()+ "  TP2    :  "+DoubleToString(tp2,5)+"  (1:"+DoubleToString(rr2,1)+")\n"
          +E_CHECK()+ "  TP3    :  "+DoubleToString(tp3,5)+"  (1:"+DoubleToString(rr3,1)+")\n"
          +E_RULER()+ "  R : R  :  1 : "+DoubleToString(rr2,1)+" / 1:"+DoubleToString(rr3,1)+"\n"
          +SEP()+"\n"
          +E_LOCK()+  "  Move SL to BE  :  "+DoubleToString(beLevel,5)+"\n"
          +E_WARN()+  "  Close 50% at TP1, trail to TP2, let 25% run to TP3\n"
          +SEP()+"\n"
          +E_SWEEP()+ "  Confluence : "+conf+"\n"
          +E_CLOCK()+ "  "+TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES);
   }

   bool tgOk=PostToTelegram(msg);
   if(tgOk)
   {
      g_lastSignalTime=TimeCurrent();
      Print("[SignalBot v6.16] Signal sent: ",_Symbol," ",(trend==1?"BUY":"SELL"),
            " score=",score,"/23 entry=",DoubleToString(entry,5),
            " kz=",kzLabel);

      // v6.16 NEW — chart image attachment. The text message above is
      // completely unchanged; this is a separate, additional photo post
      // showing Entry/SL/TP1/TP2/TP3 drawn on the actual chart.
      if(InpChartImageEnable)
      {
         DrawSignalChart(trend,entry,sl,tp1,tp2,tp3);
         string imgFile="signal_"+_Symbol+"_"+IntegerToString((int)TimeCurrent())+".png";
         if(CaptureChartScreenshot(imgFile))
         {
            bool imgOk=SendTelegramPhoto(imgFile);
            if(!imgOk) Print("[v6.16 ChartImage] Failed to send chart image for ",_Symbol);
            if(!InpChartImageKeepFiles) FileDelete(imgFile);
         }
         else Print("[v6.16 ChartImage] Screenshot capture failed for ",_Symbol);
      }
   }
   else Print("[SignalBot v6.16] Telegram send failed for ",_Symbol);

   SendFacebookSignal((trend==1?"BUY":"SELL"),entry,sl,tp1,tp2);
}
//+------------------------------------------------------------------+
