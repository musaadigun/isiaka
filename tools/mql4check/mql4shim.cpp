// Simulated MT4 terminal backing the shim declarations, so the EA's real
// code can be executed against a controllable clock, order book and history.
#include "mql4shim.h"
#include <map>
#include <ctime>
#include <cstdio>
#include <algorithm>

double Bid = 2400.00, Ask = 2400.30, Point = 0.01;
int    Digits = 2;

// ---- clock -----------------------------------------------------------------
datetime SIM_now = 0;          // GMT
int      SIM_brokerOffset = 7200;   // broker runs GMT+2
static uint SIM_ticks = 100000;

datetime TimeGMT()     { return SIM_now; }
datetime TimeCurrent() { return SIM_now + SIM_brokerOffset; }
datetime TimeLocal()   { return SIM_now; }
uint     GetTickCount(){ SIM_ticks += 5000; return SIM_ticks; }
void     Sleep(int)    { }

string TimeToString(datetime t, int mode)
{
   time_t tt = (time_t)t;
   struct tm g; gmtime_r(&tt, &g);
   char buf[64];
   bool date = (mode & TIME_DATE) != 0;
   bool secs = (mode & TIME_SECONDS) != 0;
   if(date && secs) snprintf(buf,sizeof buf,"%04d.%02d.%02d %02d:%02d:%02d",
                             g.tm_year+1900,g.tm_mon+1,g.tm_mday,g.tm_hour,g.tm_min,g.tm_sec);
   else if(date)    snprintf(buf,sizeof buf,"%04d.%02d.%02d %02d:%02d",
                             g.tm_year+1900,g.tm_mon+1,g.tm_mday,g.tm_hour,g.tm_min);
   else if(secs)    snprintf(buf,sizeof buf,"%02d:%02d:%02d",g.tm_hour,g.tm_min,g.tm_sec);
   else             snprintf(buf,sizeof buf,"%02d:%02d",g.tm_hour,g.tm_min);
   return string(buf);
}

datetime StringToTime(const string& s)
{
   int Y=0,M=0,D=0,h=0,m=0,sec=0;
   if(sscanf(s.c_str(),"%d.%d.%d %d:%d:%d",&Y,&M,&D,&h,&m,&sec) >= 3)
   {
      struct tm g{}; g.tm_year=Y-1900; g.tm_mon=M-1; g.tm_mday=D;
      g.tm_hour=h; g.tm_min=m; g.tm_sec=sec;
      return (datetime)timegm(&g);
   }
   return 0;
}

bool TimeToStruct(datetime t, MqlDateTime& st)
{
   time_t tt=(time_t)t; struct tm g; gmtime_r(&tt,&g);
   st.year=g.tm_year+1900; st.mon=g.tm_mon+1; st.day=g.tm_mday;
   st.hour=g.tm_hour; st.min=g.tm_min; st.sec=g.tm_sec;
   st.day_of_week=g.tm_wday; st.day_of_year=g.tm_yday;
   return true;
}

// ---- strings ---------------------------------------------------------------
int StringLen(const string& s){ return (int)s.size(); }
int StringFind(const string& s, const string& sub, int start)
{
   if(start<0) start=0;
   if(start>(int)s.size()) return -1;
   size_t p=s.find(sub,(size_t)start);
   return p==string::npos ? -1 : (int)p;
}
string StringSubstr(const string& s, int start, int count)
{
   if(start<0 || start>(int)s.size()) return "";
   return count<0 ? s.substr(start) : s.substr(start,(size_t)count);
}
int StringSplit(const string& s, ushort sep, MqlStrArray& out)
{
   out.v.clear();
   string cur;
   for(char c : s){ if((ushort)(unsigned char)c==sep){ out.v.push_back(cur); cur.clear(); } else cur+=c; }
   out.v.push_back(cur);
   return (int)out.v.size();
}
ushort StringGetCharacter(const string& s, int pos)
{
   if(pos<0 || pos>=(int)s.size()) return 0;
   return (ushort)(unsigned char)s[pos];
}
int StringTrimLeft(string& s)
{
   size_t i=0; while(i<s.size() && isspace((unsigned char)s[i])) i++;
   int n=(int)i; s.erase(0,i); return n;
}
int StringTrimRight(string& s)
{
   size_t i=s.size(); while(i>0 && isspace((unsigned char)s[i-1])) i--;
   int n=(int)(s.size()-i); s.erase(i); return n;
}
int StringReplace(string& s, const string& find, const string& rep)
{
   if(find.empty()) return 0;
   int n=0; size_t p=0;
   while((p=s.find(find,p))!=string::npos){ s.replace(p,find.size(),rep); p+=rep.size(); n++; }
   return n;
}
bool StringToUpper(string& s)
{
   for(auto& c : s) c=(char)toupper((unsigned char)c);
   return true;
}
long   StringToInteger(const string& s){ return atoll(s.c_str()); }
string IntegerToString(long v, int, ushort){ char b[32]; snprintf(b,sizeof b,"%lld",(long long)v); return string(b); }
string DoubleToString(double v, int digits)
{
   if(digits<0) digits=8;
   char b[64]; snprintf(b,sizeof b,"%.*f",digits,v); return string(b);
}
double NormalizeDouble(double v, int digits)
{
   double p=std::pow(10.0,digits);
   return std::floor(v*p + (v<0?-0.5:0.5))/p;
}

// ---- terminal --------------------------------------------------------------
static int SIM_lastError = 0;
bool SIM_tradeAllowed = true;

int  AccountNumber(){ return 555001; }
bool IsTradeAllowed(){ return SIM_tradeAllowed; }
bool IsTradeContextBusy(){ return false; }
bool IsStopped(){ return false; }
bool RefreshRates(){ return true; }
int  GetLastError(){ return SIM_lastError; }
void ResetLastError(){ SIM_lastError=0; }
string Symbol(){ return "XAUUSD"; }
bool EventSetTimer(int){ return true; }
void EventKillTimer(){}
void ChartRedraw(long){}

double SIM_stopLevel = 0.0;
double MarketInfo(const string&, int type)
{
   switch(type)
   {
      case MODE_MINLOT:      return 0.01;
      case MODE_MAXLOT:      return 100.0;
      case MODE_LOTSTEP:     return 0.01;
      case MODE_STOPLEVEL:   return SIM_stopLevel;
      case MODE_FREEZELEVEL: return 0.0;
      default:               return 0.0;
   }
}

// ---- global variables ------------------------------------------------------
static std::map<string,double> SIM_gv;
bool     GlobalVariableCheck(const string& n){ return SIM_gv.count(n)>0; }
double   GlobalVariableGet(const string& n){ auto i=SIM_gv.find(n); return i==SIM_gv.end()?0.0:i->second; }
datetime GlobalVariableSet(const string& n, double v){ SIM_gv[n]=v; return SIM_now; }
bool     GlobalVariableDel(const string& n){ return SIM_gv.erase(n)>0; }
int      GlobalVariablesTotal(){ return (int)SIM_gv.size(); }
string   GlobalVariableName(int i)
{
   if(i<0 || i>=(int)SIM_gv.size()) return "";
   auto it=SIM_gv.begin(); std::advance(it,i); return it->first;
}
void SIM_clearGlobals(){ SIM_gv.clear(); }

// ---- orders ----------------------------------------------------------------
struct Ord
{
   int ticket=0, type=0, magic=0;
   double lots=0, price=0, sl=0, tp=0;
   string sym, comment;
   datetime openTime=0;
};

std::vector<Ord> SIM_live, SIM_hist;
static Ord* SIM_sel = nullptr;
static int  SIM_nextTicket = 1000;

void SIM_reset()
{
   SIM_live.clear(); SIM_hist.clear(); SIM_sel=nullptr;
   SIM_nextTicket=1000; SIM_lastError=0; SIM_tradeAllowed=true;
   SIM_stopLevel=0.0;
}

int OrdersTotal(){ return (int)SIM_live.size(); }
int OrdersHistoryTotal(){ return (int)SIM_hist.size(); }

bool OrderSelect(int index, int select, int pool)
{
   if(select==SELECT_BY_POS)
   {
      std::vector<Ord>& p = (pool==MODE_HISTORY) ? SIM_hist : SIM_live;
      if(index<0 || index>=(int)p.size()) return false;
      SIM_sel=&p[index];
      return true;
   }
   for(auto& o : SIM_live) if(o.ticket==index){ SIM_sel=&o; return true; }
   for(auto& o : SIM_hist) if(o.ticket==index){ SIM_sel=&o; return true; }
   return false;
}

int OrderSend(const string& sym,int cmd,double volume,double price,int,
              double sl,double tp,const string& comment,int magic,datetime,color)
{
   Ord o;
   o.ticket=SIM_nextTicket++; o.type=cmd; o.magic=magic; o.lots=volume;
   o.price=price; o.sl=sl; o.tp=tp; o.sym=sym; o.comment=comment;
   o.openTime=TimeCurrent();
   SIM_live.push_back(o);
   return o.ticket;
}

bool OrderModify(int ticket,double price,double sl,double tp,datetime,color)
{
   for(auto& o : SIM_live)
      if(o.ticket==ticket){ o.price=price; o.sl=sl; o.tp=tp; return true; }
   return false;
}

bool OrderClose(int ticket,double,double,int,color)
{
   for(size_t i=0;i<SIM_live.size();i++)
      if(SIM_live[i].ticket==ticket)
      {
         SIM_hist.push_back(SIM_live[i]);
         SIM_live.erase(SIM_live.begin()+i);
         SIM_sel=nullptr;
         return true;
      }
   return false;
}

bool OrderDelete(int ticket,color)
{
   for(size_t i=0;i<SIM_live.size();i++)
      if(SIM_live[i].ticket==ticket)
      {
         // MT4 files deleted pendings into history too.
         SIM_hist.push_back(SIM_live[i]);
         SIM_live.erase(SIM_live.begin()+i);
         SIM_sel=nullptr;
         return true;
      }
   return false;
}

int      OrderTicket(){ return SIM_sel?SIM_sel->ticket:0; }
int      OrderType(){ return SIM_sel?SIM_sel->type:-1; }
int      OrderMagicNumber(){ return SIM_sel?SIM_sel->magic:0; }
double   OrderLots(){ return SIM_sel?SIM_sel->lots:0; }
double   OrderOpenPrice(){ return SIM_sel?SIM_sel->price:0; }
double   OrderStopLoss(){ return SIM_sel?SIM_sel->sl:0; }
double   OrderTakeProfit(){ return SIM_sel?SIM_sel->tp:0; }
datetime OrderOpenTime(){ return SIM_sel?SIM_sel->openTime:0; }
string   OrderSymbol(){ return SIM_sel?SIM_sel->sym:string(""); }
string   OrderComment(){ return SIM_sel?SIM_sel->comment:string(""); }

// Test helper: a resting stop order gets hit and becomes a market position.
bool SIM_trigger(int ticket)
{
   for(auto& o : SIM_live)
      if(o.ticket==ticket)
      {
         if(o.type==OP_BUYSTOP) o.type=OP_BUY;
         else if(o.type==OP_SELLSTOP) o.type=OP_SELL;
         else return false;
         o.openTime=TimeCurrent();
         return true;
      }
   return false;
}

int SIM_countLive(int magic,int type)
{
   int n=0;
   for(auto& o : SIM_live) if(o.magic==magic && o.type==type) n++;
   return n;
}

int SIM_findLive(int magic,int type)
{
   for(auto& o : SIM_live) if(o.magic==magic && o.type==type) return o.ticket;
   return -1;
}

double SIM_slOf(int ticket)
{
   for(auto& o : SIM_live) if(o.ticket==ticket) return o.sl;
   for(auto& o : SIM_hist) if(o.ticket==ticket) return o.sl;
   return 0.0;
}

void SIM_addHistory(int type,int magic,double price,const string& comment,datetime openTime)
{
   Ord o;
   o.ticket=SIM_nextTicket++; o.type=type; o.magic=magic; o.lots=0.01;
   o.price=price; o.sym="XAUUSD"; o.comment=comment; o.openTime=openTime;
   SIM_hist.push_back(o);
}

// ---- chart objects ---------------------------------------------------------
static std::vector<string> SIM_objects;
static std::map<string,string> SIM_objText;

bool ObjectCreate(long,const string& name,int,int,datetime,double,datetime,double)
{
   if(std::find(SIM_objects.begin(),SIM_objects.end(),name)==SIM_objects.end())
      SIM_objects.push_back(name);
   return true;
}
int ObjectFind(long,const string& name)
{
   auto it=std::find(SIM_objects.begin(),SIM_objects.end(),name);
   return it==SIM_objects.end() ? -1 : (int)(it-SIM_objects.begin());
}
bool ObjectDelete(long,const string& name)
{
   auto it=std::find(SIM_objects.begin(),SIM_objects.end(),name);
   if(it==SIM_objects.end()) return false;
   SIM_objects.erase(it); SIM_objText.erase(name); return true;
}
int    ObjectsTotal(long,int,int){ return (int)SIM_objects.size(); }
string ObjectName(long,int pos,int,int)
{
   if(pos<0 || pos>=(int)SIM_objects.size()) return "";
   return SIM_objects[pos];
}
bool ObjectSetInteger(long,const string&,int,long){ return true; }
bool ObjectSetString(long,const string& n,int prop,const string& v)
{
   if(prop==OBJPROP_TEXT) SIM_objText[n]=v;
   return true;
}
string SIM_objectText(const string& n)
{
   auto i=SIM_objText.find(n); return i==SIM_objText.end()?string(""):i->second;
}
