//+------------------------------------------------------------------+
//|                                                  SpikeHunter.mq5 |
//|  Détecteur de spikes Boom/Crash au tick près + statistiques      |
//+------------------------------------------------------------------+
//| Principe                                                          |
//|  - Chaque tick (bid) est comparé à l'amplitude moyenne des ticks  |
//|    "normaux" récents (moyenne exponentielle hors spikes).         |
//|  - Un tick dont le mouvement dans le sens du spike dépasse        |
//|    InpThresholdMult fois cette amplitude est un spike.            |
//|  - Les ticks consécutifs d'un même spike sont fusionnés.          |
//|                                                                   |
//| Le panneau affiche les statistiques qui disent si le timing       |
//| "ticks depuis le dernier spike" a une valeur prédictive :         |
//|  - CV des écarts : ~1 => processus sans mémoire (pas d'edge).     |
//|  - Taux de risque (hazard) par tranche d'âge : plat => sans       |
//|    mémoire ; croissant => un spike devient plus probable avec     |
//|    le temps.                                                      |
//+------------------------------------------------------------------+
#property copyright   "spikehunter"
#property version     "1.00"
#property description "Détecteur de spikes Boom/Crash au tick près, avec statistiques d'intervalle."
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2
#property indicator_label1  "Spike haussier"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_width1  2
#property indicator_label2  "Spike baissier"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  2

enum ENUM_SPIKE_DIR
  {
   SPIKE_AUTO = 0,   // Auto (Boom/GainX = haut, Crash/PainX = bas)
   SPIKE_UP   = 1,   // Haussier
   SPIKE_DOWN = 2,   // Baissier
   SPIKE_BOTH = 3    // Les deux
  };

input ENUM_SPIKE_DIR InpDirection      = SPIKE_AUTO; // Sens des spikes
input double         InpThresholdMult  = 15.0;       // Seuil = N x amplitude moyenne d'un tick normal
input double         InpMinSpikePoints = 0.0;        // Taille minimale d'un spike en points (0 = aucune)
input int            InpNoiseWindow    = 200;        // Fenêtre (ticks) de l'amplitude moyenne
input int            InpMergeTicks     = 3;          // Fusionner les spikes distants de <= N ticks
input int            InpHistoryDays    = 3;          // Jours d'historique tick analysés au démarrage
input int            InpNominalPeriod  = 0;          // Période nominale en ticks (0 = lue dans le nom)
input bool           InpShowPanel      = true;       // Afficher le panneau de statistiques
input bool           InpAlert          = true;       // Alerte sonore sur spike en direct
input bool           InpPush           = false;      // Notification push sur spike en direct
input bool           InpExportCsv      = false;      // Exporter les spikes en CSV (MQL5/Files)

#define HAZARD_BINS 6

struct SpikeEvent
  {
   datetime time;
   long     msc;
   double   price;   // prix après le spike
   double   size;    // amplitude signée (en prix)
   long     gap;     // ticks depuis le spike précédent (0 = premier)
  };

//--- buffers
double BufUp[];
double BufDown[];

//--- configuration résolue
int    g_dir        = SPIKE_BOTH;
int    g_nominal    = 1000;
double g_alpha      = 0.01;

//--- état du flux de ticks
bool   g_loaded      = false;
int    g_loadTries   = 0;
ulong  g_lastMsc     = 0;
int    g_sameMsc     = 0;     // ticks déjà traités ayant g_lastMsc
double g_prevBid     = 0.0;
double g_noise       = 0.0;   // amplitude moyenne d'un tick normal
long   g_noiseCount  = 0;
long   g_ticks       = 0;
long   g_age         = 0;     // ticks depuis le dernier spike
long   g_lastSpikeTick = -1000000;

//--- statistiques
SpikeEvent g_events[];
int    g_nEvents     = 0;
int    g_placed      = 0;     // événements déjà dessinés
long   g_nGaps       = 0;
double g_gapSum      = 0.0;
double g_gapSumSq    = 0.0;
double g_sizeSum     = 0.0;
double g_driftSum    = 0.0;
long   g_driftCount  = 0;
double g_hazEvents[HAZARD_BINS];
double g_hazExposure[HAZARD_BINS];

//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BufUp, INDICATOR_DATA);
   SetIndexBuffer(1, BufDown, INDICATOR_DATA);
   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetInteger(0, PLOT_ARROW_SHIFT, -15);
   PlotIndexSetInteger(1, PLOT_ARROW_SHIFT, 15);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   string upper = _Symbol;
   StringToUpper(upper);
   g_dir = (int)InpDirection;
   if(g_dir == SPIKE_AUTO)
     {
      if(StringFind(upper, "BOOM") >= 0 || StringFind(upper, "GAINX") >= 0)
         g_dir = SPIKE_UP;
      else if(StringFind(upper, "CRASH") >= 0 || StringFind(upper, "PAINX") >= 0)
         g_dir = SPIKE_DOWN;
      else
         g_dir = SPIKE_BOTH;
     }

   g_nominal = InpNominalPeriod > 0 ? InpNominalPeriod : ParseNominal(_Symbol);
   g_alpha   = 2.0 / (MathMax(InpNoiseWindow, 2) + 1.0);

   ArrayInitialize(g_hazEvents, 0.0);
   ArrayInitialize(g_hazExposure, 0.0);
   IndicatorSetString(INDICATOR_SHORTNAME, "SpikeHunter");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Comment("");
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(prev_calculated == 0)
     {
      ArrayInitialize(BufUp, EMPTY_VALUE);
      ArrayInitialize(BufDown, EMPTY_VALUE);
      g_placed = 0;
     }
   else if(rates_total > prev_calculated)
     {
      for(int i = prev_calculated; i < rates_total; i++)
        {
         BufUp[i]   = EMPTY_VALUE;
         BufDown[i] = EMPTY_VALUE;
        }
     }

   if(!g_loaded)
     {
      //--- historique pas encore synchronisé : on réessaie, puis on passe en direct
      if(!LoadHistory() && ++g_loadTries < 20)
         return(0);
      g_loaded = true;
      if(InpExportCsv)
         ExportAll();
     }
   else
      PollTicks();

   PlaceArrows(rates_total, high, low);
   if(InpShowPanel)
      ShowPanel();
   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Lit le premier nombre du nom de symbole ("Boom 1000 Index" ->1000)|
//+------------------------------------------------------------------+
int ParseNominal(const string sym)
  {
   int value = 0;
   bool inNumber = false;
   for(int i = 0; i < StringLen(sym); i++)
     {
      ushort c = StringGetCharacter(sym, i);
      if(c >= '0' && c <= '9')
        {
         value = value * 10 + (c - '0');
         inNumber = true;
        }
      else if(inNumber)
         break;
     }
   return(value > 0 ? value : 1000);
  }

//+------------------------------------------------------------------+
bool LoadHistory()
  {
   MqlTick ticks[];
   ulong fromMsc = (ulong)(TimeCurrent() - (datetime)InpHistoryDays * 86400) * 1000;
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_INFO, fromMsc, 0);
   if(n <= 0)
      return(false);
   for(int i = 0; i < n; i++)
      ProcessTick(ticks[i], false);
   return(true);
  }

//+------------------------------------------------------------------+
void PollTicks()
  {
   MqlTick ticks[];
   int n = CopyTicks(_Symbol, ticks, COPY_TICKS_INFO, g_lastMsc, 100000);
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
      ProcessTick(ticks[i], true);
     }
  }

//+------------------------------------------------------------------+
void ProcessTick(const MqlTick &t, const bool live)
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
   g_age++;

   int bin = HazardBin(g_age);
   g_hazExposure[bin] += 1.0;

   double signedMove = delta;
   if(g_dir == SPIKE_DOWN)
      signedMove = -delta;
   else if(g_dir == SPIKE_BOTH)
      signedMove = MathAbs(delta);

   bool warm = g_noiseCount >= InpNoiseWindow / 4 && g_noise > 0.0;
   bool isSpike = warm
                  && signedMove > InpThresholdMult * g_noise
                  && signedMove >= InpMinSpikePoints * _Point;

   if(isSpike)
     {
      g_hazEvents[bin] += 1.0;
      RegisterSpike(t, delta, live);
      return;
     }

   //--- tick normal : met à jour l'amplitude moyenne et la dérive
   double a = MathAbs(delta);
   g_noise = g_noiseCount == 0 ? a : g_noise + g_alpha * (a - g_noise);
   g_noiseCount++;
   g_driftSum += delta;
   g_driftCount++;
  }

//+------------------------------------------------------------------+
int HazardBin(const long age)
  {
   double width = 0.5 * g_nominal;
   int bin = (int)((age - 1) / width);
   return(MathMin(MathMax(bin, 0), HAZARD_BINS - 1));
  }

//+------------------------------------------------------------------+
void RegisterSpike(const MqlTick &t, const double delta, const bool live)
  {
   //--- tick suivant d'un spike déjà enregistré : on le fusionne
   if(g_nEvents > 0 && g_ticks - g_lastSpikeTick <= InpMergeTicks)
     {
      g_events[g_nEvents - 1].size  += delta;
      g_events[g_nEvents - 1].price  = t.bid;
      g_sizeSum += MathAbs(delta);
      g_lastSpikeTick = g_ticks;
      g_age = 0;
      return;
     }

   long gap = g_nEvents > 0 ? g_age : 0;
   if(g_nEvents > 0)
     {
      g_nGaps++;
      g_gapSum   += (double)gap;
      g_gapSumSq += (double)gap * (double)gap;
     }

   if(g_nEvents >= ArraySize(g_events))
      ArrayResize(g_events, g_nEvents + 1, 1024);
   g_events[g_nEvents].time  = t.time;
   g_events[g_nEvents].msc   = t.time_msc;
   g_events[g_nEvents].price = t.bid;
   g_events[g_nEvents].size  = delta;
   g_events[g_nEvents].gap   = gap;
   g_nEvents++;

   g_sizeSum += MathAbs(delta);
   g_lastSpikeTick = g_ticks;
   g_age = 0;

   if(live)
     {
      string msg = StringFormat("SpikeHunter %s : spike %s de %s points (écart %I64d ticks)",
                                _Symbol, delta > 0 ? "haussier" : "baissier",
                                DoubleToString(MathAbs(delta) / _Point, 0), gap);
      if(InpAlert)
         Alert(msg);
      if(InpPush)
         SendNotification(msg);
      if(InpExportCsv)
         AppendCsv(g_events[g_nEvents - 1]);
     }
  }

//+------------------------------------------------------------------+
void PlaceArrows(const int rates_total, const double &high[], const double &low[])
  {
   for(int e = g_placed; e < g_nEvents; e++)
     {
      int shift = iBarShift(_Symbol, _Period, g_events[e].time, false);
      if(shift < 0)
         continue;
      int idx = rates_total - 1 - shift;
      if(idx < 0 || idx >= rates_total)
         continue;
      if(g_events[e].size > 0)
         BufUp[idx] = high[idx];
      else
         BufDown[idx] = low[idx];
     }
   g_placed = g_nEvents;
  }

//+------------------------------------------------------------------+
void ShowPanel()
  {
   double meanGap = g_nGaps > 0 ? g_gapSum / g_nGaps : 0.0;
   double varGap  = g_nGaps > 1 ? (g_gapSumSq - g_nGaps * meanGap * meanGap) / (g_nGaps - 1) : 0.0;
   double cv      = meanGap > 0.0 ? MathSqrt(MathMax(varGap, 0.0)) / meanGap : 0.0;
   double meanSz  = g_nEvents > 0 ? g_sizeSum / g_nEvents : 0.0;
   double drift   = g_driftCount > 0 ? g_driftSum / g_driftCount : 0.0;
   double p60     = 1.0 - MathPow(1.0 - 1.0 / g_nominal, 60);

   string dirTxt = g_dir == SPIKE_UP ? "haussier" : (g_dir == SPIKE_DOWN ? "baissier" : "les deux");
   string s = "SpikeHunter  " + _Symbol + "  (sens : " + dirTxt
              + ", nominal : 1 spike / " + IntegerToString(g_nominal) + " ticks)\n";
   s += StringFormat("Ticks analysés : %I64d   Spikes : %d\n", g_ticks, g_nEvents);
   s += StringFormat("Ticks depuis le dernier spike : %I64d\n", g_age);
   s += StringFormat("Écart moyen : %.0f ticks   CV : %.3f  (1.0 = sans mémoire)\n", meanGap, cv);
   s += StringFormat("Taille moyenne du spike : %.0f pts   Dérive/tick : %.4f pts\n",
                     meanSz / _Point, drift / _Point);
   s += StringFormat("Dérive x écart moyen : %.0f pts  (vs spike moyen %.0f pts)\n",
                     MathAbs(drift) * meanGap / _Point, meanSz / _Point);
   s += StringFormat("P(spike dans les 60 prochains ticks) si sans mémoire : %.1f %%\n", p60 * 100.0);
   s += "Taux observé par âge (ticks par spike ; plat = aucune valeur prédictive) :\n";
   for(int b = 0; b < HAZARD_BINS; b++)
     {
      double lo = b * 0.5 * g_nominal;
      string range = b < HAZARD_BINS - 1
                     ? StringFormat("%.0f-%.0f", lo, lo + 0.5 * g_nominal)
                     : StringFormat("%.0f+", lo);
      string rate = g_hazEvents[b] > 0.0
                    ? StringFormat("1 / %.0f", g_hazExposure[b] / g_hazEvents[b])
                    : "n/d";
      s += StringFormat("   âge %s : %s   (%.0f spikes)\n", range, rate, g_hazEvents[b]);
     }
   Comment(s);
  }

//+------------------------------------------------------------------+
string CsvName()
  {
   string name = "spikehunter_" + _Symbol + ".csv";
   StringReplace(name, " ", "_");
   return(name);
  }

//+------------------------------------------------------------------+
void ExportAll()
  {
   int h = FileOpen(CsvName(), FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE)
      return;
   FileWrite(h, "time", "time_msc", "price", "size_points", "gap_ticks");
   for(int e = 0; e < g_nEvents; e++)
      WriteRow(h, g_events[e]);
   FileClose(h);
  }

//+------------------------------------------------------------------+
void AppendCsv(const SpikeEvent &ev)
  {
   int h = FileOpen(CsvName(), FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   WriteRow(h, ev);
   FileClose(h);
  }

//+------------------------------------------------------------------+
void WriteRow(const int h, const SpikeEvent &ev)
  {
   FileWrite(h, TimeToString(ev.time, TIME_DATE | TIME_SECONDS), IntegerToString(ev.msc),
             DoubleToString(ev.price, _Digits), DoubleToString(ev.size / _Point, 0),
             IntegerToString(ev.gap));
  }
//+------------------------------------------------------------------+
