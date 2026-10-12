//+------------------------------------------------------------------+
//| FixTradeExample.mq5 - CTrade replacement demo                    |
//| MIT License - AlgoTradingResearch                                |
//| Keys: B = buy, S = sell, C = close net position of this chart    |
//+------------------------------------------------------------------+
#property copyright "AlgoTradingResearch - MIT"
#property version   "1.00"

#include "FixTrade.mqh"

input string InpHost     = "127.0.0.1";
input int    InpPort     = 9100;
input string InpToken    = "";
input long   InpMagic    = 20261012;
input string InpSymbols  = "EURUSD";   // symbols to track (quotes + persisted state)
input double InpLots     = 0.10;
input int    InpSLPoints = 200;
input int    InpTPPoints = 400;

CFixTrade trade;   // was: CTrade trade;

int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.EmulateStops(true);
   trade.Init(InpHost,InpPort,InpToken,InpMagic);
   string p[];
   int n=StringSplit(InpSymbols,(ushort)',',p);
   for(int i=0;i<n;i++)
     {
      string s=p[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(s!="")
         trade.Track(s);
     }
   EventSetMillisecondTimer(100);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

void OnTimer()
  {
   trade.Process();
   static ulong last=0;
   ulong now=GetTickCount64();
   if(now-last<500)
      return;
   last=now;
   Comment("FixTradeExample  ready=",(trade.Ready()?"yes":"no"),"  dry-run=",(trade.DryRun()?"yes":"no"),"\n",
           _Symbol,"  net lots=",DoubleToString(trade.NetLots(_Symbol),2),
           "  FIX bid=",DoubleToString(trade.Bid(_Symbol),5)," ask=",DoubleToString(trade.Ask(_Symbol),5),"\n",
           "last: ",trade.ResultRetcodeDescription()," ",trade.ResultComment());
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id!=CHARTEVENT_KEYDOWN)
      return;
   if(lparam!=66 && lparam!=83 && lparam!=67)
      return;
   if(lparam==67)
     {
      if(!trade.PositionClose(_Symbol))
         Print("close failed: ",trade.ResultRetcodeDescription()," ",trade.ResultComment());
      return;
     }
   bool buy=(lparam==66);
   double ref=buy?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl=buy?ref-InpSLPoints*_Point:ref+InpSLPoints*_Point;
   double tp=buy?ref+InpTPPoints*_Point:ref-InpTPPoints*_Point;
   bool ok=buy?trade.Buy(InpLots,_Symbol,0.0,sl,tp):trade.Sell(InpLots,_Symbol,0.0,sl,tp);
   Print((buy?"BUY":"SELL")," ok=",ok," ",trade.ResultRetcodeDescription()," price=",
         DoubleToString(trade.ResultPrice(),5)," ",trade.ResultComment());
  }
