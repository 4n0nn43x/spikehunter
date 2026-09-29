//+------------------------------------------------------------------+
//|                                                  ExportTicks.mq5 |
//|  Exporte les ticks (time_msc,bid,ask) de plusieurs symboles      |
//|  en CSV dans MQL5/Files, pour analysis/scan_all.py.              |
//+------------------------------------------------------------------+
#property copyright   "spikehunter"
#property version     "1.00"
#property description "Exporte les ticks des symboles choisis en CSV (time_msc,bid,ask)."
#property script_show_inputs

input int    InpDays    = 14;   // Jours d'historique à exporter
input string InpSymbols = "";   // Symboles séparés par ; (vide = tous ceux du Market Watch)
input string InpFolder  = "spikehunter_ticks"; // Sous-dossier de MQL5/Files

//+------------------------------------------------------------------+
void OnStart()
  {
   string list[];
   int n = 0;
   if(StringLen(InpSymbols) > 0)
      n = StringSplit(InpSymbols, ';', list);
   else
     {
      n = SymbolsTotal(true);
      ArrayResize(list, n);
      for(int i = 0; i < n; i++)
         list[i] = SymbolName(i, true);
     }

   ulong fromMsc = (ulong)(TimeCurrent() - (datetime)InpDays * 86400) * 1000;
   for(int s = 0; s < n; s++)
     {
      string sym = list[s];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(sym == "" || !SymbolSelect(sym, true))
         continue;
      ExportSymbol(sym, fromMsc, s + 1, n);
     }
   Print("ExportTicks : terminé. Fichiers dans MQL5/Files/", InpFolder);
  }

//+------------------------------------------------------------------+
void ExportSymbol(const string sym, const ulong fromMsc, const int k, const int n)
  {
   MqlTick ticks[];
   int got = -1;
   //--- l'historique de ticks peut demander une synchronisation avec le serveur
   for(int attempt = 0; attempt < 30 && got <= 0; attempt++)
     {
      got = CopyTicksRange(sym, ticks, COPY_TICKS_INFO, fromMsc, 0);
      if(got <= 0)
         Sleep(1000);
     }
   if(got <= 0)
     {
      PrintFormat("ExportTicks [%d/%d] %s : aucun tick (erreur %d)", k, n, sym, GetLastError());
      return;
     }

   string name = sym;
   StringReplace(name, " ", "_");
   StringReplace(name, "/", "_");
   int h = FileOpen(InpFolder + "\\" + name + ".csv", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("ExportTicks %s : impossible de créer le fichier (erreur %d)", sym, GetLastError());
      return;
     }
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   FileWriteString(h, "time_msc,bid,ask\r\n");
   for(int i = 0; i < got; i++)
     {
      if(ticks[i].bid <= 0.0 || ticks[i].ask <= 0.0)
         continue;
      FileWriteString(h, StringFormat("%I64d,%s,%s\r\n", ticks[i].time_msc,
                                      DoubleToString(ticks[i].bid, digits),
                                      DoubleToString(ticks[i].ask, digits)));
     }
   FileClose(h);
   PrintFormat("ExportTicks [%d/%d] %s : %d ticks", k, n, sym, got);
  }
//+------------------------------------------------------------------+
