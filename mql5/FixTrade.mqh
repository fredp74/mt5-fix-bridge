//+------------------------------------------------------------------+
//| FixTrade.mqh - CTrade-like wrapper that routes orders to FIX     |
//| MIT License - AlgoTradingResearch                                |
//| Needs FixBridge.mqh. Call Process() from OnTimer (every 100 ms). |
//+------------------------------------------------------------------+
#ifndef FIXTRADE_MQH
#define FIXTRADE_MQH

#include "FixBridge.mqh"

struct SFixOrd
  {
   ulong    ticket;
   string   clid;
   string   n_clid;     // pending replace id
   string   sym;
   bool     buy;
   double   units;
   double   cs;         // contract size at send time
   string   type;       // M, L, S
   double   px;
   double   stop;
   double   n_px;
   double   n_stop;
   double   sl;
   double   tp;
   int      state;      // 0 sent, 1 working, 2 filled, 3 rejected, 4 canceled
   double   filled;
   double   avg;
   string   text;
   bool     closing;
  };

struct SFixSym
  {
   string   sym;
   double   net;        // net position in FIX units, own fills only
   double   sl;
   double   tp;
   double   bid;
   double   ask;
   bool     sub;
   bool     loaded;
   datetime close_sent;
  };

class CFixTrade
  {
private:
   CFixBridge m_fix;
   SFixOrd    m_ord[];
   SFixSym    m_s[];
   long       m_magic;
   string     m_tag;
   long       m_seq;
   ulong      m_tkt;
   bool       m_hello;
   bool       m_emulate;
   int        m_wait_ms;
   ENUM_ORDER_TYPE_FILLING m_filling;
   uint       m_retcode;
   ulong      m_res_order;
   double     m_res_vol;
   double     m_res_price;
   string     m_res_comment;

   bool Fail(const uint code,const string why)
     {
      m_retcode=code;
      m_res_comment=why;
      Print("[FixTrade] ",why);
      return false;
     }

   void Reset()
     {
      m_retcode=0;
      m_res_order=0;
      m_res_vol=0.0;
      m_res_price=0.0;
      m_res_comment="";
     }

   string NewId()
     {
      m_seq++;
      return "F"+m_tag+"-"+IntegerToString((long)TimeGMT())+"-"+IntegerToString(m_seq);
     }

   //--- symbol table
   int Sym(const string sym,const bool create=true)
     {
      for(int i=0;i<ArraySize(m_s);i++)
         if(m_s[i].sym==sym)
            return i;
      if(!create)
         return -1;
      int n=ArraySize(m_s);
      ArrayResize(m_s,n+1);
      m_s[n].sym=sym;
      m_s[n].net=0.0;
      m_s[n].sl=0.0;
      m_s[n].tp=0.0;
      m_s[n].bid=0.0;
      m_s[n].ask=0.0;
      m_s[n].sub=false;
      m_s[n].loaded=false;
      m_s[n].close_sent=0;
      return n;
     }

   string Key(const string sym,const string f)
     {
      return "FIXB_"+IntegerToString(m_magic)+(m_fix.DryRun()?"_D_":"_L_")+sym+"_"+f;
     }

   void LoadSym(const int i)
     {
      if(m_s[i].loaded || !m_hello)
         return;
      m_s[i].loaded=true;
      string sym=m_s[i].sym;
      string kn=Key(sym,"net");
      string ks=Key(sym,"sl");
      string kt=Key(sym,"tp");
      m_s[i].net=GlobalVariableCheck(kn)?GlobalVariableGet(kn):0.0;
      m_s[i].sl=GlobalVariableCheck(ks)?GlobalVariableGet(ks):0.0;
      m_s[i].tp=GlobalVariableCheck(kt)?GlobalVariableGet(kt):0.0;
     }

   void SaveSym(const int i)
     {
      if(!m_hello)
         return;
      string sym=m_s[i].sym;
      GlobalVariableSet(Key(sym,"net"),m_s[i].net);
      GlobalVariableSet(Key(sym,"sl"),m_s[i].sl);
      GlobalVariableSet(Key(sym,"tp"),m_s[i].tp);
     }

   void Subscribe(const string sym)
     {
      int i=Sym(sym);
      m_s[i].sub=true;
      if(m_hello)
         m_fix.Subscribe(sym);
     }

   bool ToUnits(const string sym,const double lots,double &units,double &cs)
     {
      cs=0.0;
      if(!SymbolInfoDouble(sym,SYMBOL_TRADE_CONTRACT_SIZE,cs) || cs<=0.0)
         return false;
      units=lots*cs;
      return true;
     }

   //--- order table
   int FindOrd(const string id)
     {
      if(id=="")
         return -1;
      for(int i=0;i<ArraySize(m_ord);i++)
         if(m_ord[i].clid==id || m_ord[i].n_clid==id)
            return i;
      return -1;
     }

   int FindTkt(const ulong tkt)
     {
      for(int i=0;i<ArraySize(m_ord);i++)
         if(m_ord[i].ticket==tkt)
            return i;
      return -1;
     }

   void Compact()
     {
      int n=ArraySize(m_ord);
      if(n<64)
         return;
      int w=0;
      for(int r=0;r<n;r++)
        {
         if(m_ord[r].state>=2)
            continue;
         if(w!=r)
            m_ord[w]=m_ord[r];
         w++;
        }
      ArrayResize(m_ord,w);
     }

   string MarketTif()
     {
      if(m_filling==ORDER_FILLING_IOC)
         return "3";
      if(m_filling==ORDER_FILLING_FOK)
         return "4";
      return "0";
     }

   bool PendTif(const ENUM_ORDER_TYPE_TIME tt,string &tif)
     {
      if(tt==ORDER_TIME_GTC)
        {
         tif="1";
         return true;
        }
      if(tt==ORDER_TIME_DAY || tt==ORDER_TIME_SPECIFIED_DAY)
        {
         tif="0";
         return true;
        }
      return false;   // GTD not supported
     }

   //--- engine messages
   void ApplyFill(const int k,const double lq)
     {
      int s=Sym(m_ord[k].sym);
      LoadSym(s);
      m_s[s].net+=(m_ord[k].buy?lq:-lq);
      if(MathAbs(m_s[s].net)<0.000001)
        {
         m_s[s].net=0.0;
         m_s[s].sl=0.0;
         m_s[s].tp=0.0;
        }
      else
         if(!m_ord[k].closing && (m_ord[k].sl>0.0 || m_ord[k].tp>0.0))
           {
            m_s[s].sl=m_ord[k].sl;
            m_s[s].tp=m_ord[k].tp;
           }
      SaveSym(s);
     }

   void OnExec(CFixMsg &m)
     {
      string id=m.Get("id");
      string orig=m.Get("orig");
      string et=m.Get("etype");
      int k=FindOrd(id);
      if(k<0 && orig!="")
         k=FindOrd(orig);
      if(k<0)
         return;                       // not one of our orders
      double lq=m.GetD("lastqty");
      if(et=="0")
        {
         if(m_ord[k].state==0)
            m_ord[k].state=1;
        }
      else
         if(et=="5")
           {
            if(m_ord[k].n_clid!="")
              {
               m_ord[k].clid=m_ord[k].n_clid;
               m_ord[k].px=m_ord[k].n_px;
               m_ord[k].stop=m_ord[k].n_stop;
               m_ord[k].n_clid="";
              }
            else
               m_ord[k].clid=id;
            m_ord[k].state=1;
           }
         else
            if(et=="4" || et=="C")
              {
               m_ord[k].state=4;
               m_ord[k].text=m.Get("text");
              }
            else
               if(et=="8")
                 {
                  m_ord[k].state=3;
                  m_ord[k].text=(m.Get("text")=="")?"rejected by venue":m.Get("text");
                 }
               else
                  if(lq>0.0 && (et=="F" || et=="1" || et=="2"))
                    {
                     ApplyFill(k,lq);
                     m_ord[k].filled=m.GetD("cum");
                     m_ord[k].avg=m.GetD("avgpx");
                     m_ord[k].state=(m.Get("status")=="2")?2:1;
                    }
     }

   void OnReject(CFixMsg &m)
     {
      string id=m.Get("id");
      string why=m.Get("reason");
      int k=FindOrd(id);
      if(k>=0)
        {
         if(m_ord[k].n_clid==id)
           {
            m_ord[k].n_clid="";
            Print("[FixTrade] replace rejected: ",why);
           }
         else
            if(m_ord[k].state==0)
              {
               m_ord[k].state=3;
               m_ord[k].text=why;
              }
         return;
        }
      Print("[FixTrade] REJECT ",id," ",why);
     }

   void Handle(CFixMsg &m)
     {
      string c=m.cmd;
      if(c=="HELLO")
        {
         m_hello=true;
         for(int i=0;i<ArraySize(m_s);i++)
           {
            m_s[i].loaded=false;
            LoadSym(i);
            if(m_s[i].sub)
               m_fix.Subscribe(m_s[i].sym);
           }
         Print("[FixTrade] engine ready, fix=",m.Get("fix")," dry=",m.Get("dry"));
        }
      else
         if(c=="QUOTE")
           {
            int i=Sym(m.Get("sym"),false);
            if(i>=0)
              {
               m_s[i].bid=m.GetD("bid");
               m_s[i].ask=m.GetD("ask");
              }
           }
         else
            if(c=="EXEC")
               OnExec(m);
            else
               if(c=="REJECT")
                  OnReject(m);
     }

   void Pump()
     {
      CFixMsg m;
      int guard=0;
      while(guard<200 && m_fix.Next(m))
        {
         Handle(m);
         guard++;
        }
     }

   //--- emulated SL/TP
   void CheckStops()
     {
      if(!m_emulate || !m_hello)
         return;
      datetime now=TimeLocal();
      for(int i=0;i<ArraySize(m_s);i++)
        {
         if(MathAbs(m_s[i].net)<0.000001)
            continue;
         if(m_s[i].sl<=0.0 && m_s[i].tp<=0.0)
            continue;
         if(m_s[i].bid<=0.0 || m_s[i].ask<=0.0)
            continue;
         if(now-m_s[i].close_sent<10)
            continue;
         bool hit=false;
         string why="";
         if(m_s[i].net>0.0)
           {
            if(m_s[i].sl>0.0 && m_s[i].bid<=m_s[i].sl)
              {
               hit=true;
               why="SL";
              }
            else
               if(m_s[i].tp>0.0 && m_s[i].bid>=m_s[i].tp)
                 {
                  hit=true;
                  why="TP";
                 }
           }
         else
           {
            if(m_s[i].sl>0.0 && m_s[i].ask>=m_s[i].sl)
              {
               hit=true;
               why="SL";
              }
            else
               if(m_s[i].tp>0.0 && m_s[i].ask<=m_s[i].tp)
                 {
                  hit=true;
                  why="TP";
                 }
           }
         if(hit)
           {
            m_s[i].close_sent=now;
            string sym=m_s[i].sym;
            Print("[FixTrade] emulated ",why," hit on ",sym," -> closing");
            PositionClose(sym);
           }
        }
     }

   //--- core send
   bool WaitFill(const ulong tkt,const bool market)
     {
      uint t0=GetTickCount();
      while(m_wait_ms>0)
        {
         Pump();
         int k=FindTkt(tkt);
         if(k>=0)
           {
            int st=m_ord[k].state;
            if(st==2)
              {
               m_retcode=TRADE_RETCODE_DONE;
               m_res_price=m_ord[k].avg;
               m_res_vol=m_ord[k].filled/m_ord[k].cs;
               return true;
              }
            if(st==3)
               return Fail(TRADE_RETCODE_REJECT,(m_ord[k].text=="")?"rejected":m_ord[k].text);
            if(st==4)
               return Fail(TRADE_RETCODE_REJECT,"canceled: "+m_ord[k].text);
            if(st==1 && !market)
               return true;
           }
         if((int)(GetTickCount()-t0)>=m_wait_ms)
            break;
         Sleep(5);
        }
      return true;   // accepted, fill still pending (retcode PLACED)
     }

   bool Send(const string sym,const bool buy,const double units,const double cs,const string type,
             const double px,const double stop,const double sl,const double tp,
             const string tif,const bool closing)
     {
      Reset();
      if(!m_hello || !m_fix.Connected())
         return Fail(TRADE_RETCODE_CONNECTION,"engine not connected (is Process() called from OnTimer?)");
      if(!m_fix.FixUp())
         return Fail(TRADE_RETCODE_CONNECTION,"FIX session is down");
      if(units<=0.0)
         return Fail(TRADE_RETCODE_INVALID_VOLUME,"bad volume");
      if(!closing && (sl>0.0 || tp>0.0) && !m_emulate)
         return Fail(TRADE_RETCODE_INVALID_STOPS,"FIX orders carry no SL/TP: call EmulateStops(true) or pass 0");
      string id=NewId();
      string r=m_fix.NewOrder(sym,buy,units,type,px,stop,tif,id);
      if(r=="")
         return Fail(TRADE_RETCODE_CONNECTION,"send failed");
      Compact();
      SFixOrd o;
      m_tkt++;
      o.ticket=m_tkt;
      o.clid=id;
      o.n_clid="";
      o.sym=sym;
      o.buy=buy;
      o.units=units;
      o.cs=cs;
      o.type=type;
      o.px=px;
      o.stop=stop;
      o.n_px=0.0;
      o.n_stop=0.0;
      o.sl=sl;
      o.tp=tp;
      o.state=0;
      o.filled=0.0;
      o.avg=0.0;
      o.text="";
      o.closing=closing;
      int n=ArraySize(m_ord);
      ArrayResize(m_ord,n+1);
      m_ord[n]=o;
      m_retcode=TRADE_RETCODE_PLACED;
      m_res_order=m_tkt;
      if(m_emulate && !closing && (sl>0.0 || tp>0.0))
         Subscribe(sym);
      return WaitFill(m_tkt,(type=="M"));
     }

   bool SendLots(const string symbol,const bool buy,const double lots,const string type,const double px,
                 const double stop,const double sl,const double tp,const string tif)
     {
      string sym=(symbol==NULL || symbol=="")?_Symbol:symbol;
      double units=0.0,cs=0.0;
      if(!ToUnits(sym,lots,units,cs))
        {
         Reset();
         return Fail(TRADE_RETCODE_INVALID_VOLUME,"unknown contract size for "+sym+" (add it to Market Watch)");
        }
      return Send(sym,buy,units,cs,type,px,stop,sl,tp,tif,false);
     }

public:
                     CFixTrade():m_magic(0),m_tag(""),m_seq(0),m_tkt(0),m_hello(false),m_emulate(false),
                                 m_wait_ms(2000),m_filling(ORDER_FILLING_RETURN),m_retcode(0),
                                 m_res_order(0),m_res_vol(0.0),m_res_price(0.0),m_res_comment("") {}
                    ~CFixTrade() { m_fix.Close(); }

   //--- setup (CTrade-like)
   void              SetExpertMagicNumber(const long magic) { m_magic=magic; }
   void              SetDeviationInPoints(const ulong dev)  { }           // ignored on FIX
   void              SetTypeFilling(const ENUM_ORDER_TYPE_FILLING f) { m_filling=f; }
   void              SetAsyncMode(const bool async) { m_wait_ms=async?0:2000; }
   void              SetSyncWaitMs(const int ms)    { m_wait_ms=(ms<0)?0:ms; }
   void              EmulateStops(const bool on)    { m_emulate=on; }

   //--- connection
   void              Init(const string host,const int port,const string token="",const long magic=-1,
                          const string tag="")
     {
      if(magic>=0)
         m_magic=magic;
      m_tag=(tag=="")?IntegerToString((long)(ChartID()%10000)):tag;
      m_fix.Connect(host,port,token);
     }

   //--- symbols whose quotes / persisted position you want loaded at start
   void              Track(const string sym)
     {
      Subscribe(sym);
      int i=Sym(sym);
      LoadSym(i);
     }

   //--- call from OnTimer (100 ms)
   void              Process()
     {
      if(!m_fix.Reconnect(5))
        {
         m_hello=false;
         return;
        }
      Pump();
      if(!m_fix.Connected())
        {
         m_hello=false;
         return;
        }
      CheckStops();
     }

   bool              Ready() { return (m_hello && m_fix.Connected() && m_fix.FixUp()); }
   bool              DryRun() { return m_fix.DryRun(); }

   //--- market orders
   bool              Buy(const double volume,const string symbol=NULL,const double price=0.0,
                         const double sl=0.0,const double tp=0.0,const string comment="")
     {
      return SendLots(symbol,true,volume,"M",0.0,0.0,sl,tp,MarketTif());
     }

   bool              Sell(const double volume,const string symbol=NULL,const double price=0.0,
                          const double sl=0.0,const double tp=0.0,const string comment="")
     {
      return SendLots(symbol,false,volume,"M",0.0,0.0,sl,tp,MarketTif());
     }

   //--- pending orders
   bool              BuyLimit(const double volume,const double price,const string symbol=NULL,
                              const double sl=0.0,const double tp=0.0,
                              const ENUM_ORDER_TYPE_TIME type_time=ORDER_TIME_GTC,
                              const datetime expiration=0,const string comment="")
     {
      string tif;
      if(!PendTif(type_time,tif))
        {
         Reset();
         return Fail(TRADE_RETCODE_INVALID_EXPIRATION,"GTD expiration not supported");
        }
      return SendLots(symbol,true,volume,"L",price,0.0,sl,tp,tif);
     }

   bool              SellLimit(const double volume,const double price,const string symbol=NULL,
                               const double sl=0.0,const double tp=0.0,
                               const ENUM_ORDER_TYPE_TIME type_time=ORDER_TIME_GTC,
                               const datetime expiration=0,const string comment="")
     {
      string tif;
      if(!PendTif(type_time,tif))
        {
         Reset();
         return Fail(TRADE_RETCODE_INVALID_EXPIRATION,"GTD expiration not supported");
        }
      return SendLots(symbol,false,volume,"L",price,0.0,sl,tp,tif);
     }

   bool              BuyStop(const double volume,const double price,const string symbol=NULL,
                             const double sl=0.0,const double tp=0.0,
                             const ENUM_ORDER_TYPE_TIME type_time=ORDER_TIME_GTC,
                             const datetime expiration=0,const string comment="")
     {
      string tif;
      if(!PendTif(type_time,tif))
        {
         Reset();
         return Fail(TRADE_RETCODE_INVALID_EXPIRATION,"GTD expiration not supported");
        }
      return SendLots(symbol,true,volume,"S",0.0,price,sl,tp,tif);
     }

   bool              SellStop(const double volume,const double price,const string symbol=NULL,
                              const double sl=0.0,const double tp=0.0,
                              const ENUM_ORDER_TYPE_TIME type_time=ORDER_TIME_GTC,
                              const datetime expiration=0,const string comment="")
     {
      string tif;
      if(!PendTif(type_time,tif))
        {
         Reset();
         return Fail(TRADE_RETCODE_INVALID_EXPIRATION,"GTD expiration not supported");
        }
      return SendLots(symbol,false,volume,"S",0.0,price,sl,tp,tif);
     }

   //--- close the net position this instance holds on a symbol
   bool              PositionClose(const string symbol,const ulong deviation=ULONG_MAX)
     {
      Reset();
      int i=Sym(symbol);
      LoadSym(i);
      double net=m_s[i].net;
      if(MathAbs(net)<0.000001)
         return Fail(TRADE_RETCODE_REJECT,"no tracked position on "+symbol);
      double cs=0.0,dummy=0.0;
      if(!ToUnits(symbol,1.0,dummy,cs))
         return Fail(TRADE_RETCODE_INVALID_VOLUME,"unknown contract size for "+symbol);
      return Send(symbol,(net<0.0),MathAbs(net),cs,"M",0.0,0.0,0.0,0.0,MarketTif(),true);
     }

   bool              PositionClosePartial(const string symbol,const double volume,const ulong deviation=ULONG_MAX)
     {
      Reset();
      int i=Sym(symbol);
      LoadSym(i);
      double net=m_s[i].net;
      if(MathAbs(net)<0.000001)
         return Fail(TRADE_RETCODE_REJECT,"no tracked position on "+symbol);
      double units=0.0,cs=0.0;
      if(!ToUnits(symbol,volume,units,cs))
         return Fail(TRADE_RETCODE_INVALID_VOLUME,"unknown contract size for "+symbol);
      if(units>MathAbs(net))
         units=MathAbs(net);
      return Send(symbol,(net<0.0),units,cs,"M",0.0,0.0,0.0,0.0,MarketTif(),true);
     }

   bool              PositionModify(const string symbol,const double sl,const double tp)
     {
      Reset();
      if(!m_emulate)
         return Fail(TRADE_RETCODE_INVALID_STOPS,"FIX has no SL/TP: call EmulateStops(true)");
      int i=Sym(symbol);
      LoadSym(i);
      if(MathAbs(m_s[i].net)<0.000001)
         return Fail(TRADE_RETCODE_REJECT,"no tracked position on "+symbol);
      m_s[i].sl=sl;
      m_s[i].tp=tp;
      SaveSym(i);
      Subscribe(symbol);
      m_retcode=TRADE_RETCODE_DONE;
      return true;
     }

   //--- manage working orders (ticket = value of ResultOrder() after sending)
   bool              OrderDelete(const ulong ticket)
     {
      Reset();
      int k=FindTkt(ticket);
      if(k<0)
         return Fail(TRADE_RETCODE_INVALID,"unknown ticket (FixTrade tickets are not MT5 tickets)");
      if(m_ord[k].state!=1)
         return Fail(TRADE_RETCODE_REJECT,"order is not working");
      if(!m_hello || !m_fix.FixUp())
         return Fail(TRADE_RETCODE_CONNECTION,"not connected");
      string r=m_fix.Cancel(m_ord[k].clid,m_ord[k].sym,m_ord[k].buy,m_ord[k].units,NewId());
      if(r=="")
         return Fail(TRADE_RETCODE_CONNECTION,"send failed");
      m_retcode=TRADE_RETCODE_PLACED;
      m_res_order=ticket;
      uint t0=GetTickCount();
      while(m_wait_ms>0)
        {
         Pump();
         k=FindTkt(ticket);
         if(k<0 || m_ord[k].state>=2)
           {
            if(k>=0 && m_ord[k].state==4)
               m_retcode=TRADE_RETCODE_DONE;
            break;
           }
         if((int)(GetTickCount()-t0)>=m_wait_ms)
            break;
         Sleep(5);
        }
      return true;
     }

   //--- limit: price = new limit price. stop: price = new trigger price. TIF is not changed.
   bool              OrderModify(const ulong ticket,const double price,const double sl,const double tp,
                                 const ENUM_ORDER_TYPE_TIME type_time=ORDER_TIME_GTC,
                                 const datetime expiration=0,const double stoplimit=0.0)
     {
      Reset();
      int k=FindTkt(ticket);
      if(k<0)
         return Fail(TRADE_RETCODE_INVALID,"unknown ticket");
      if(m_ord[k].state!=1 || m_ord[k].n_clid!="")
         return Fail(TRADE_RETCODE_REJECT,"order is not modifiable now");
      if((sl>0.0 || tp>0.0) && !m_emulate)
         return Fail(TRADE_RETCODE_INVALID_STOPS,"FIX has no SL/TP: call EmulateStops(true)");
      if(!m_hello || !m_fix.FixUp())
         return Fail(TRADE_RETCODE_CONNECTION,"not connected");
      double px=m_ord[k].px;
      double stop=m_ord[k].stop;
      if(m_ord[k].type=="L")
         px=price;
      else
         stop=price;
      string nid=NewId();
      string r=m_fix.Replace(m_ord[k].clid,m_ord[k].sym,m_ord[k].buy,m_ord[k].units,m_ord[k].type,px,stop,nid);
      if(r=="")
         return Fail(TRADE_RETCODE_CONNECTION,"send failed");
      m_ord[k].n_clid=nid;
      m_ord[k].n_px=px;
      m_ord[k].n_stop=stop;
      m_ord[k].sl=sl;
      m_ord[k].tp=tp;
      m_retcode=TRADE_RETCODE_PLACED;
      m_res_order=ticket;
      return true;
     }

   //--- state (replaces PositionSelect / PositionGetDouble in adapted EAs)
   double            NetUnits(const string sym)
     {
      int i=Sym(sym);
      LoadSym(i);
      return m_s[i].net;
     }

   double            NetLots(const string sym)
     {
      double units=0.0,cs=0.0;
      if(!ToUnits(sym,1.0,units,cs))
         return 0.0;
      return NetUnits(sym)/cs;
     }

   bool              HasPosition(const string sym) { return (MathAbs(NetUnits(sym))>0.000001); }
   bool              IsLong(const string sym)      { return (NetUnits(sym)>0.000001); }
   double            Bid(const string sym) { int i=Sym(sym,false); return (i<0)?0.0:m_s[i].bid; }
   double            Ask(const string sym) { int i=Sym(sym,false); return (i<0)?0.0:m_s[i].ask; }

   int               WorkingOrders(const string sym)
     {
      int c=0;
      for(int i=0;i<ArraySize(m_ord);i++)
         if(m_ord[i].sym==sym && m_ord[i].state==1)
            c++;
      return c;
     }

   //--- results (CTrade-like)
   uint              ResultRetcode()  { return m_retcode; }
   ulong             ResultOrder()    { return m_res_order; }
   ulong             ResultDeal()     { return m_res_order; }
   double            ResultVolume()   { return m_res_vol; }
   double            ResultPrice()    { return m_res_price; }
   string            ResultComment()  { return m_res_comment; }

   string            ResultRetcodeDescription()
     {
      switch(m_retcode)
        {
         case TRADE_RETCODE_PLACED:             return "order placed, fill pending";
         case TRADE_RETCODE_DONE:               return "done";
         case TRADE_RETCODE_REJECT:             return "rejected";
         case TRADE_RETCODE_CONNECTION:         return "not connected";
         case TRADE_RETCODE_INVALID_VOLUME:     return "invalid volume";
         case TRADE_RETCODE_INVALID_STOPS:      return "SL/TP not available";
         case TRADE_RETCODE_INVALID_EXPIRATION: return "expiration not supported";
         case TRADE_RETCODE_INVALID:            return "invalid request";
        }
      return "retcode "+IntegerToString((int)m_retcode);
     }
  };

#endif
