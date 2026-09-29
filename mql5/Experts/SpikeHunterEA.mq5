//+------------------------------------------------------------------+
//|                                                SpikeHunterEA.mq5 |
//|  EA Boom/Crash/GainX/PainX basé sur l'âge du cycle de spikes     |
//+------------------------------------------------------------------+
//| Détection identique à l'indicateur SpikeHunter : un tick dont le |
//| mouvement dépasse InpThresholdMult fois l'amplitude moyenne d'un |
//| tick normal est un spike. L'âge = ticks depuis le dernier spike. |
//|                                                                   |
//| Modes :                                                           |
//|  - Attraper le spike : entre dans le sens du spike à l'âge        |
//|    InpEntryAge, sort juste après le spike (ou après InpMaxHold).  |
//|  - Suivre la dérive : entre contre le spike à l'âge InpEntryAge,  |
//|    sort après InpMaxHold ticks ou dès qu'un spike arrive.         |
//+------------------------------------------------------------------+
#property copyright   "spikehunter"
#property version     "1.00"
#property description "EA à spikes : entrée selon l'âge du cycle (ticks depuis le dernier spike)."

#include <Trade/Trade.mqh>

enum ENUM_EA_MODE
  {
   MODE_CATCH_SPIKE  = 0,  // Attraper le spike
   MODE_FOLLOW_DRIFT = 1   // Suivre la dérive
  };

enum ENUM_SPIKE_DIR
  {
   SPIKE_AUTO = 0,   // Auto (Boom/GainX = haut, Crash/PainX = bas)
   SPIKE_UP   = 1,   // Haussier
   SPIKE_DOWN = 2    // Baissier
  };

input ENUM_EA_MODE   InpMode          = MODE_CATCH_SPIKE; // Stratégie
input ENUM_SPIKE_DIR InpDirection     = SPIKE_AUTO;       // Sens des spikes
input int            InpEntryAge      = 300;              // Âge d'entrée (ticks depuis le dernier spike)
input int            InpMaxHold       = 0;                // Durée max en ticks (0 = jusqu'au spike)
input int            InpExitDelay     = 0;                // Ticks d'attente après le spike avant de sortir
input double         InpLots          = 0.0;              // Lot (0 = lot minimum du symbole)
input double         InpStopPoints    = 0.0;              // Stop loss en points (0 = aucun)
input double         InpTakePoints    = 0.0;              // Take profit en points (0 = aucun)
input double         InpThresholdMult = 15.0;             // Seuil de détection (x amplitude normale)
input int            InpNoiseWindow   = 200;              // Fenêtre de l'amplitude normale (ticks)
input int            InpMergeTicks    = 3;                // Fusionner les spikes distants de <= N ticks
input ulong          InpMagic         = 250929;           // Numéro magique

CTrade g_trade;
int    g_dir        = SPIKE_UP;
double g_alpha      = 0.01;
double g_lots       = 0.0;

//--- état du flux de ticks
ulong  g_lastMsc    = 0;
int    g_sameMsc    = 0;
double g_prevBid    = 0.0;
double g_noise      = 0.0;
long   g_noiseCount = 0;
long   g_ticks      = 0;
long   g_age        = -1;       // -1 tant qu'aucun spike n'a été vu
long   g_lastSpikeTick = -1000000;
long   g_spikes     = 0;

//--- état de la position
bool   g_inTrade      = false;
long   g_entryTick    = 0;
long   g_spikeAtEntry = 0;       // nombre de spikes au moment de l'entrée
long   g_exitAtTick   = -1;      // tick de sortie programmé après un spike
bool   g_enteredThisCycle = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   string upper = _Symbol;
   StringToUpper(upper);
   g_dir = (int)InpDirection;
   if(g_dir == SPIKE_AUTO)
     {
      if(StringFind(upper, "CRASH") >= 0 || StringFind(upper, "PAINX") >= 0)
         g_dir = SPIKE_DOWN;
      else
         g_dir = SPIKE_UP;
     }
   g_alpha = 2.0 / (MathMax(InpNoiseWindow, 2) + 1.0);

   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_lots = InpLots > 0.0 ? InpLots : vmin;
   if(vstep > 0.0)
      g_lots = MathRound(g_lots / vstep) * vstep;
   g_lots = MathMin(MathMax(g_lots, vmin), vmax);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(1000);

   g_inTrade = HasPosition();
   PrintFormat("SpikeHunterEA %s : sens %s, mode %s, âge d'entrée %d, lot %.2f",
               _Symbol, g_dir == SPIKE_UP ? "haussier" : "baissier",
               InpMode == MODE_CATCH_SPIKE ? "attraper le spike" : "suivre la dérive",
               InpEntryAge, g_lots);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- traite tous les ticks arrivés depuis le dernier appel
   MqlTick ticks[];
   int n;
   if(g_lastMsc == 0)
     {
      MqlTick last;
      if(!SymbolInfoTick(_Symbol, last))
         return;
      ArrayResize(ticks, 1);
      ticks[0] = last;
      n = 1;
     }
   else
      n = CopyTicks(_Symbol, ticks, COPY_TICKS_INFO, g_lastMsc, 100000);
   if(n <= 0)
      return;

   int skip = 0;
   for(int i = 0; i < n; i++)
     {
      if((ulong)ticks[i].time_msc < g_lastMsc)
         continue;
      if((ulong)ticks[i].time_msc == g_lastMsc && skip < g_sameMsc)
        {
         skip++;
         continue;
        }
      ProcessTick(ticks[i]);
     }

   g_inTrade = HasPosition();
   ManagePosition();
   if(!g_inTrade)
      TryEnter();

   Comment(StringFormat("SpikeHunterEA  %s\nÂge : %s ticks   Spikes vus : %I64d\nPosition : %s",
                        InpMode == MODE_CATCH_SPIKE ? "attraper le spike" : "suivre la dérive",
                        g_age < 0 ? "en attente du 1er spike" : IntegerToString(g_age),
                        g_spikes, g_inTrade ? "ouverte" : "aucune"));
  }

//+------------------------------------------------------------------+
void ProcessTick(const MqlTick &t)
  {
   if((ulong)t.time_msc == g_lastMsc)
      g_sameMsc++;
   else
     {
      g_lastMsc = (ulong)t.time_msc;
      g_sameMsc = 1;
     }
   if(t.bid <= 0.0)
      return;
   if(g_prevBid <= 0.0)
     {
      g_prevBid = t.bid;
      return;
     }

   double delta = t.bid - g_prevBid;
   g_prevBid = t.bid;
   g_ticks++;
   if(g_age >= 0)
      g_age++;

   double move = g_dir == SPIKE_UP ? delta : -delta;
   bool warm = g_noiseCount >= InpNoiseWindow / 4 && g_noise > 0.0;
   if(warm && move > InpThresholdMult * g_noise)
     {
      //--- un tick qui prolonge le spike précédent ne crée pas de nouveau cycle
      if(g_ticks - g_lastSpikeTick > InpMergeTicks)
        {
         g_spikes++;
         g_enteredThisCycle = false;
        }
      g_lastSpikeTick = g_ticks;
      g_age = 0;
      return;
     }

   double a = MathAbs(delta);
   g_noise = g_noiseCount == 0 ? a : g_noise + g_alpha * (a - g_noise);
   g_noiseCount++;
  }

//+------------------------------------------------------------------+
void TryEnter()
  {
   if(g_age < 0 || g_enteredThisCycle || g_age < InpEntryAge)
      return;
   //--- entrée seulement au moment de l'âge visé, pas plus tard dans le cycle
   if(g_age > InpEntryAge + 5)
      return;

   bool buy = (g_dir == SPIKE_UP) == (InpMode == MODE_CATCH_SPIKE);
   double price = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0.0, tp = 0.0;
   if(InpStopPoints > 0.0)
      sl = buy ? price - InpStopPoints * _Point : price + InpStopPoints * _Point;
   if(InpTakePoints > 0.0)
      tp = buy ? price + InpTakePoints * _Point : price - InpTakePoints * _Point;
   sl = sl > 0.0 ? NormalizeDouble(sl, _Digits) : 0.0;
   tp = tp > 0.0 ? NormalizeDouble(tp, _Digits) : 0.0;

   bool ok = buy ? g_trade.Buy(g_lots, _Symbol, 0.0, sl, tp, "SpikeHunterEA")
                 : g_trade.Sell(g_lots, _Symbol, 0.0, sl, tp, "SpikeHunterEA");
   g_enteredThisCycle = true;
   if(!ok)
     {
      PrintFormat("SpikeHunterEA : ordre refusé (%u %s)", g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return;
     }
   g_inTrade      = true;
   g_entryTick    = g_ticks;
   g_spikeAtEntry = g_spikes;
   g_exitAtTick   = -1;
  }

//+------------------------------------------------------------------+
void ManagePosition()
  {
   if(!g_inTrade)
     {
      g_exitAtTick = -1;
      return;
     }

   //--- un spike est arrivé depuis l'entrée : sortie (éventuellement retardée)
   if(g_spikes > g_spikeAtEntry)
     {
      if(g_exitAtTick < 0)
         g_exitAtTick = g_lastSpikeTick + InpExitDelay;
      if(g_ticks >= g_exitAtTick)
        {
         CloseAll();
         return;
        }
     }

   if(InpMaxHold > 0 && g_ticks - g_entryTick >= InpMaxHold)
      CloseAll();
  }

//+------------------------------------------------------------------+
bool HasPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol
         && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
void CloseAll()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol
         && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         g_trade.PositionClose(ticket);
     }
   g_inTrade    = HasPosition();
   g_exitAtTick = -1;
  }
//+------------------------------------------------------------------+
