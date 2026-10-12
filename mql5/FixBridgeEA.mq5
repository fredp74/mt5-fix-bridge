//+------------------------------------------------------------------+
//| FixBridgeEA.mq5 - demo client for the MT5 <-> FIX bridge         |
//| MIT License - AlgoTradingResearch                                |
//|                                                                  |
//| Keys on the chart:  B = market buy, S = market sell (InpDemoLots)|
//|                     P = request positions                        |
//| Optional mirror mode: copies every MT5 deal as a market order.   |
//+------------------------------------------------------------------+
#property copyright "AlgoTradingResearch - MIT"
#property version   "1.00"
#property description "MT5 -> FIX bridge client (local TCP to the Python engine)"

#include "FixBridge.mqh"

input string InpHost        = "127.0.0.1";  // Engine host
input int    InpPort        = 9100;         // Engine port (listen_port)
input string InpToken       = "";           // Shared secret (auth_token), if set
input string InpSymbols     = "EURUSD,GBPUSD"; // MT5 symbols to subscribe / mirror
input double InpDemoLots    = 0.01;         // Lots for B / S keys
input bool   InpMirror      = false;        // Mirror MT5 deals to the FIX venue
input long   InpMirrorMagic = 0;            // 0 = mirror all deals, else this magic only

CFixBridge g_fix;
string     g_syms[];
double     g_bid[];
double     g_ask[];
string     g_log[8];

//+------------------------------------------------------------------+
void Log(const string s)
  {
   Print("[FixBridge] ",s);
   for(int i=7;i>0;i--)
      g_log[i]=g_log[i-1];
   g_log[0]=TimeToString(TimeLocal(),TIME_SECONDS)+" "+s;
  }

int Idx(const string sym)
  {
   for(int i=0;i<ArraySize(g_syms);i++)
      if(g_syms[i]==sym)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   string parts[];
   int n=StringSplit(InpSymbols,(ushort)',',parts);
   ArrayResize(g_syms,0);
   ArrayResize(g_bid,0);
   ArrayResize(g_ask,0);
   for(int i=0;i<n;i++)
     {
      string s=parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(s=="")
         continue;
      int k=ArraySize(g_syms);
      ArrayResize(g_syms,k+1);
      ArrayResize(g_bid,k+1);
      ArrayResize(g_ask,k+1);
      g_syms[k]=s;
      g_bid[k]=0.0;
      g_ask[k]=0.0;
     }
   EventSetMillisecondTimer(100);
   if(!g_fix.Connect(InpHost,InpPort,InpToken))
      Log("engine not reachable yet, will retry every 5 s");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_fix.Close();
   Comment("");
  }

//+------------------------------------------------------------------+
void Handle(CFixMsg &m)
  {
   string c=m.cmd;
   if(c=="HELLO")
     {
      Log("engine connected, fix="+m.Get("fix")+" dry-run="+m.Get("dry"));
      for(int i=0;i<ArraySize(g_syms);i++)
         g_fix.Subscribe(g_syms[i]);
      g_fix.RequestPositions();
     }
   else
      if(c=="QUOTE")
        {
         int i=Idx(m.Get("sym"));
         if(i>=0)
           {
            g_bid[i]=m.GetD("bid");
            g_ask[i]=m.GetD("ask");
           }
        }
      else
         if(c=="EXEC")
            Log("EXEC "+m.Get("id")+" "+m.Get("sym")+" "+m.Get("side")+" status="+m.Get("status")+
                " last="+m.Get("lastqty")+"@"+m.Get("lastpx")+" "+m.Get("text"));
         else
            if(c=="POSITION")
               Log("POS "+m.Get("sym")+" long="+m.Get("long")+" short="+m.Get("short"));
            else
               if(c=="REJECT")
                  Log("REJECT "+m.Get("id")+" "+m.Get("reason"));
               else
                  if(c=="STATE")
                     Log("FIX session "+m.Get("fix"));
                  else
                     if(c=="POSACK")
                        Log("POSACK result="+m.Get("result")+" status="+m.Get("status"));
  }

void Render()
  {
   static ulong last=0;
   ulong now=GetTickCount64();
   if(now-last<500)
      return;
   last=now;
   string s="FixBridge  engine="+(g_fix.Connected()?"UP":"DOWN")+
            "  FIX="+(g_fix.FixUp()?"up":"down")+
            "  dry-run="+(g_fix.DryRun()?"yes":"no")+"\n";
   for(int i=0;i<ArraySize(g_syms);i++)
      s+=g_syms[i]+"  bid="+DoubleToString(g_bid[i],5)+"  ask="+DoubleToString(g_ask[i],5)+"\n";
   s+="--\n";
   for(int j=0;j<8;j++)
      if(g_log[j]!="")
         s+=g_log[j]+"\n";
   Comment(s);
  }

void OnTimer()
  {
   if(!g_fix.Reconnect(5))
     {
      Render();
      return;
     }
   CFixMsg m;
   int guard=0;
   while(guard<200 && g_fix.Next(m))
     {
      Handle(m);
      guard++;
     }
   Render();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id!=CHARTEVENT_KEYDOWN)
      return;
   if(lparam!=66 && lparam!=83 && lparam!=80)
      return;
   if(!g_fix.Connected())
     {
      Log("not connected to the engine");
      return;
     }
   if(lparam==80)
     {
      g_fix.RequestPositions();
      return;
     }
   double units=FixLotsToUnits(_Symbol,InpDemoLots);
   bool buy=(lparam==66);
   string oid=g_fix.NewOrder(_Symbol,buy,units);
   if(oid=="")
      Log("send failed");
   else
      Log((buy?"BUY ":"SELL ")+_Symbol+" units="+DoubleToString(units,2)+" id="+oid);
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(!InpMirror)
      return;
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   long dtype=HistoryDealGetInteger(trans.deal,DEAL_TYPE);
   if(dtype!=DEAL_TYPE_BUY && dtype!=DEAL_TYPE_SELL)
      return;
   string sym=HistoryDealGetString(trans.deal,DEAL_SYMBOL);
   if(Idx(sym)<0)
      return;
   if(InpMirrorMagic!=0 && HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMirrorMagic)
      return;
   double vol=HistoryDealGetDouble(trans.deal,DEAL_VOLUME);
   string id="mirror-"+IntegerToString((long)trans.deal);
   string oid=g_fix.NewOrder(sym,(dtype==DEAL_TYPE_BUY),FixLotsToUnits(sym,vol),"M",0.0,0.0,"0",id);
   if(oid=="")
      Log("mirror send failed for deal "+IntegerToString((long)trans.deal));
   else
      Log("mirror "+sym+" "+(dtype==DEAL_TYPE_BUY?"BUY":"SELL")+" vol="+DoubleToString(vol,2)+" id="+oid);
  }
