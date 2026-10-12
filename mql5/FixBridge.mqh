//+------------------------------------------------------------------+
//| FixBridge.mqh - MT5 side of the MT5 <-> FIX bridge               |
//| MIT License - AlgoTradingResearch                                |
//| Talks to the Python engine over a local TCP socket (no DLL).     |
//+------------------------------------------------------------------+
#ifndef FIXBRIDGE_MQH
#define FIXBRIDGE_MQH

//--- one parsed line: CMD|key=value|key=value
class CFixMsg
  {
public:
   string cmd;
   string keys[];
   string vals[];

   void   Parse(const string line)
     {
      ArrayResize(keys,0);
      ArrayResize(vals,0);
      cmd="";
      string parts[];
      int n=StringSplit(line,(ushort)'|',parts);
      if(n<=0)
         return;
      cmd=parts[0];
      for(int i=1;i<n;i++)
        {
         int p=StringFind(parts[i],"=");
         if(p<=0)
            continue;
         int k=ArraySize(keys);
         ArrayResize(keys,k+1);
         ArrayResize(vals,k+1);
         keys[k]=StringSubstr(parts[i],0,p);
         vals[k]=StringSubstr(parts[i],p+1);
        }
     }

   string Get(const string key,const string def="") const
     {
      for(int i=0;i<ArraySize(keys);i++)
         if(keys[i]==key)
            return vals[i];
      return def;
     }

   double GetD(const string key,const double def=0.0) const
     {
      string s=Get(key,"");
      if(s=="")
         return def;
      return StringToDouble(s);
     }
  };

//--- connection to the engine
class CFixBridge
  {
private:
   int      m_sock;
   string   m_rx;
   string   m_host;
   string   m_token;
   int      m_port;
   long     m_seq;
   bool     m_fix_up;
   bool     m_dry;
   datetime m_last_try;

   static string Clean(string s)
     {
      StringReplace(s,"|"," ");
      StringReplace(s,"\n"," ");
      StringReplace(s,"\r"," ");
      return s;
     }

   string NewId()
     {
      m_seq++;
      return "mt5-"+IntegerToString((long)TimeGMT())+"-"+IntegerToString(m_seq);
     }

   bool SendLine(const string line)
     {
      if(m_sock==INVALID_HANDLE)
         return false;
      uchar d[];
      int n=StringToCharArray(line+"\n",d,0,WHOLE_ARRAY,CP_UTF8);
      if(n<=1)
         return false;
      int sent=SocketSend(m_sock,d,(uint)(n-1));
      if(sent<0)
        {
         Close();
         return false;
        }
      return true;
     }

   bool Pump()
     {
      if(m_sock==INVALID_HANDLE)
         return false;
      if(!SocketIsConnected(m_sock))
        {
         Close();
         return false;
        }
      uint avail=SocketIsReadable(m_sock);
      if(avail==0)
         return false;
      if(avail>65536)
         avail=65536;
      uchar buf[];
      ArrayResize(buf,(int)avail);
      int got=SocketRead(m_sock,buf,avail,50);
      if(got<=0)
        {
         if(got<0)
            Close();
         return false;
        }
      m_rx+=CharArrayToString(buf,0,got,CP_UTF8);
      return true;
     }

   bool Extract(CFixMsg &msg)
     {
      int p=StringFind(m_rx,"\n");
      if(p<0)
         return false;
      string line=StringSubstr(m_rx,0,p);
      m_rx=StringSubstr(m_rx,p+1);
      StringReplace(line,"\r","");
      msg.Parse(line);
      return (msg.cmd!="");
     }

public:
                     CFixBridge():m_sock(INVALID_HANDLE),m_rx(""),m_host(""),m_token(""),m_port(0),
                                  m_seq(0),m_fix_up(false),m_dry(true),m_last_try(0) {}
                    ~CFixBridge() { Close(); }

   bool              Connect(const string host,const int port,const string token="")
     {
      Close();
      m_host=host;
      m_port=port;
      m_token=token;
      m_rx="";
      m_sock=SocketCreate();
      if(m_sock==INVALID_HANDLE)
        {
         Print("FixBridge: SocketCreate failed, err=",GetLastError());
         return false;
        }
      if(!SocketConnect(m_sock,host,port,1000))
        {
         Print("FixBridge: connect to ",host,":",port," failed, err=",GetLastError());
         SocketClose(m_sock);
         m_sock=INVALID_HANDLE;
         return false;
        }
      if(token!="")
         SendLine("AUTH|token="+Clean(token));
      return true;
     }

   void              Close()
     {
      if(m_sock!=INVALID_HANDLE)
        {
         SocketClose(m_sock);
         m_sock=INVALID_HANDLE;
        }
      m_fix_up=false;
     }

   bool              Connected()
     {
      return (m_sock!=INVALID_HANDLE && SocketIsConnected(m_sock));
     }

   //--- call from OnTimer: returns true when connected
   bool              Reconnect(const int every_sec=5)
     {
      if(Connected())
         return true;
      if(m_host=="")
         return false;
      if(TimeLocal()-m_last_try<every_sec)
         return false;
      m_last_try=TimeLocal();
      return Connect(m_host,m_port,m_token);
     }

   bool              FixUp() { return m_fix_up; }
   bool              DryRun() { return m_dry; }

   //--- next complete message from the engine, false if none
   bool              Next(CFixMsg &msg)
     {
      if(!Extract(msg))
        {
         if(!Pump())
            return false;
         if(!Extract(msg))
            return false;
        }
      if(msg.cmd=="HELLO")
        {
         m_fix_up=(msg.Get("fix")=="up");
         m_dry=(msg.Get("dry")=="1");
        }
      else
         if(msg.cmd=="STATE")
            m_fix_up=(msg.Get("fix")=="up");
      return true;
     }

   //--- units = FIX quantity (not lots). type: M, L, S, SL. tif: 0 day, 1 GTC, 3 IOC, 4 FOK
   string            NewOrder(const string sym,const bool buy,const double units,const string type="M",
                              const double price=0.0,const double stop=0.0,const string tif="0",
                              const string id="")
     {
      string oid=(id=="")?NewId():id;
      string l="NEW|id="+Clean(oid)+"|sym="+Clean(sym)+"|side="+(buy?"B":"S")+
               "|qty="+DoubleToString(units,8)+"|type="+type+"|tif="+tif;
      if(price>0.0)
         l+="|px="+DoubleToString(price,8);
      if(stop>0.0)
         l+="|stop="+DoubleToString(stop,8);
      return SendLine(l)?oid:"";
     }

   string            Cancel(const string orig,const string sym,const bool buy,const double units,
                            const string id="")
     {
      string cid=(id=="")?NewId():id;
      string l="CANCEL|id="+Clean(cid)+"|orig="+Clean(orig)+"|sym="+Clean(sym)+
               "|side="+(buy?"B":"S")+"|qty="+DoubleToString(units,8);
      return SendLine(l)?cid:"";
     }

   string            Replace(const string orig,const string sym,const bool buy,const double units,
                             const string type,const double price,const double stop=0.0,
                             const string id="")
     {
      string cid=(id=="")?NewId():id;
      string l="REPLACE|id="+Clean(cid)+"|orig="+Clean(orig)+"|sym="+Clean(sym)+
               "|side="+(buy?"B":"S")+"|qty="+DoubleToString(units,8)+"|type="+type;
      if(price>0.0)
         l+="|px="+DoubleToString(price,8);
      if(stop>0.0)
         l+="|stop="+DoubleToString(stop,8);
      return SendLine(l)?cid:"";
     }

   bool              Subscribe(const string sym)   { return SendLine("SUB|sym="+Clean(sym)); }
   bool              Unsubscribe(const string sym) { return SendLine("UNSUB|sym="+Clean(sym)); }
   bool              RequestPositions()            { return SendLine("POS"); }
   bool              Ping()                        { return SendLine("PING"); }
  };

//--- MT5 lots -> FIX units (contract size of the symbol)
double FixLotsToUnits(const string sym,const double lots)
  {
   double cs=SymbolInfoDouble(sym,SYMBOL_TRADE_CONTRACT_SIZE);
   if(cs<=0.0)
      cs=1.0;
   return lots*cs;
  }

#endif
