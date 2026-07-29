// Minimal MQL4 API shim so an .mq4 source can be type-checked with g++.
// This is a static-analysis aid only - it is NOT an MQL4 runtime.
#pragma once
#include <string>
#include <vector>
#include <cstdlib>
#include <cmath>
#include <iostream>

typedef std::string    string;
typedef long long      datetime;
typedef unsigned int   color;
typedef unsigned short ushort;
typedef unsigned int   uint;
typedef unsigned char  uchar;

// Dynamic string array stand-in for MQL4's "string x[];"
struct MqlStrArray
{
   std::vector<string> v;
   string& operator[](int i){ if((int)v.size()<=i) v.resize(i+1); return v[i]; }
};

struct MqlDateTime
{
   int year, mon, day, hour, min, sec, day_of_week, day_of_year;
};

// ---- predefined variables --------------------------------------------------
extern double Bid, Ask, Point;
extern int    Digits;

// ---- constants -------------------------------------------------------------
enum { INIT_SUCCEEDED = 0, INIT_FAILED = 1, INIT_PARAMETERS_INCORRECT = 2 };
enum { OP_BUY=0, OP_SELL=1, OP_BUYLIMIT=2, OP_SELLLIMIT=3, OP_BUYSTOP=4, OP_SELLSTOP=5 };
enum { SELECT_BY_POS=0, SELECT_BY_TICKET=1 };
enum { MODE_TRADES=0, MODE_HISTORY=1 };
enum { MODE_LOW=1, MODE_HIGH=2, MODE_LOTSIZE=11, MODE_MINLOT=16, MODE_LOTSTEP=17,
       MODE_MAXLOT=18, MODE_STOPLEVEL=14, MODE_FREEZELEVEL=33 };
enum { TIME_DATE=1, TIME_MINUTES=2, TIME_SECONDS=4 };
enum { OBJ_LABEL=23, OBJ_RECTANGLE_LABEL=24, OBJ_BUTTON=25 };
enum { OBJPROP_COLOR=6, OBJPROP_BACK=9, OBJPROP_XDISTANCE=102, OBJPROP_YDISTANCE=103,
       OBJPROP_XSIZE=105, OBJPROP_YSIZE=106, OBJPROP_CORNER=101, OBJPROP_SELECTABLE=114,
       OBJPROP_HIDDEN=208, OBJPROP_FONTSIZE=100, OBJPROP_ANCHOR=115, OBJPROP_STATE=209,
       OBJPROP_BGCOLOR=4098, OBJPROP_BORDER_TYPE=4099, OBJPROP_TEXT=1000, OBJPROP_FONT=1001 };
enum { CORNER_LEFT_UPPER=0, CORNER_LEFT_LOWER=1, CORNER_RIGHT_LOWER=2, CORNER_RIGHT_UPPER=3 };
enum { BORDER_FLAT=0, BORDER_RAISED=1, BORDER_SUNKEN=2 };
enum { ANCHOR_LEFT_UPPER=0, ANCHOR_RIGHT_UPPER=6 };
enum { CHARTEVENT_OBJECT_CLICK=1 };

enum {
   ERR_NO_ERROR=0, ERR_NO_RESULT=1, ERR_COMMON_ERROR=2, ERR_INVALID_TRADE_PARAMETERS=3,
   ERR_SERVER_BUSY=4, ERR_OLD_VERSION=5, ERR_NO_CONNECTION=6, ERR_NOT_ENOUGH_RIGHTS=7,
   ERR_TOO_FREQUENT_REQUESTS=8, ERR_MALFUNCTIONAL_TRADE=9,
   ERR_TRADE_TIMEOUT=128, ERR_INVALID_PRICE=129, ERR_INVALID_STOPS=130,
   ERR_INVALID_TRADE_VOLUME=131, ERR_MARKET_CLOSED=132, ERR_TRADE_DISABLED=133,
   ERR_NOT_ENOUGH_MONEY=134, ERR_PRICE_CHANGED=135, ERR_OFF_QUOTES=136,
   ERR_BROKER_BUSY=137, ERR_REQUOTE=138, ERR_ORDER_LOCKED=139,
   ERR_LONG_POSITIONS_ONLY_ALLOWED=140, ERR_TOO_MANY_REQUESTS=141,
   ERR_TRADE_MODIFY_DENIED=145, ERR_TRADE_CONTEXT_BUSY=146
};

const color clrNONE       = 0xFFFFFFFF;
const color clrWhite      = 0xFFFFFF;
const color clrRed        = 0x0000FF;
const color clrLime       = 0x00FF00;
const color clrLimeGreen  = 0x32CD32;
const color clrAqua       = 0xFFFF00;
const color clrMagenta    = 0xFF00FF;
const color clrOrange     = 0x00A5FF;
const color clrGold       = 0x00D7FF;
const color clrGainsboro  = 0xDCDCDC;
const color clrFireBrick  = 0x2222B2;
const color clrChocolate  = 0x1E69D2;

// ---- output ----------------------------------------------------------------
inline void PrintOne(){}
template<class T, class... R> void PrintOne(const T& t, const R&... r){ (void)t; PrintOne(r...); }
template<class... A> void Print(const A&... a){ PrintOne(a...); }
template<class... A> void Alert(const A&... a){ PrintOne(a...); }
inline bool SendNotification(const string& s){ (void)s; return true; }

// ---- strings ---------------------------------------------------------------
int    StringLen(const string& s);
int    StringFind(const string& s, const string& sub, int start=0);
string StringSubstr(const string& s, int start, int count=-1);
int    StringSplit(const string& s, ushort sep, MqlStrArray& out);
ushort StringGetCharacter(const string& s, int pos);
int    StringTrimLeft(string& s);
int    StringTrimRight(string& s);
int    StringReplace(string& s, const string& find, const string& rep);
bool   StringToUpper(string& s);
long   StringToInteger(const string& s);
string IntegerToString(long v, int width=0, ushort fill=' ');
string DoubleToString(double v, int digits=8);
double NormalizeDouble(double v, int digits);

// ---- time ------------------------------------------------------------------
datetime TimeGMT();
datetime TimeCurrent();
datetime TimeLocal();
string   TimeToString(datetime t, int mode=TIME_DATE|TIME_MINUTES);
datetime StringToTime(const string& s);
bool     TimeToStruct(datetime t, MqlDateTime& st);
uint     GetTickCount();
void     Sleep(int ms);

// ---- math ------------------------------------------------------------------
inline double MathMax(double a, double b){ return a>b?a:b; }
inline double MathMin(double a, double b){ return a<b?a:b; }
inline int    MathMax(int a, int b){ return a>b?a:b; }
inline int    MathMin(int a, int b){ return a<b?a:b; }
inline double MathFloor(double a){ return std::floor(a); }
inline double MathAbs(double a){ return std::fabs(a); }
inline int    MathAbs(int a){ return a<0?-a:a; }

// ---- terminal / account ----------------------------------------------------
int  AccountNumber();
bool IsTradeAllowed();
bool IsTradeContextBusy();
bool IsStopped();
bool RefreshRates();
int  GetLastError();
void ResetLastError();
string Symbol();
double MarketInfo(const string& sym, int type);
bool EventSetTimer(int seconds);
void EventKillTimer();
void ChartRedraw(long chart=0);

// ---- globals ---------------------------------------------------------------
bool     GlobalVariableCheck(const string& name);
double   GlobalVariableGet(const string& name);
datetime GlobalVariableSet(const string& name, double value);
bool     GlobalVariableDel(const string& name);
int      GlobalVariablesTotal();
string   GlobalVariableName(int index);

// ---- orders ----------------------------------------------------------------
int    OrdersTotal();
int    OrdersHistoryTotal();
bool   OrderSelect(int index, int select, int pool=MODE_TRADES);
int    OrderSend(const string& sym, int cmd, double volume, double price, int slippage,
                 double sl, double tp, const string& comment="", int magic=0,
                 datetime expiration=0, color arrow=clrNONE);
bool   OrderModify(int ticket, double price, double sl, double tp,
                   datetime expiration, color arrow=clrNONE);
bool   OrderClose(int ticket, double lots, double price, int slippage, color arrow=clrNONE);
bool   OrderDelete(int ticket, color arrow=clrNONE);
int    OrderTicket();
int    OrderType();
int    OrderMagicNumber();
double OrderLots();
double OrderOpenPrice();
double OrderStopLoss();
double OrderTakeProfit();
datetime OrderOpenTime();
string OrderSymbol();
string OrderComment();

// ---- objects ---------------------------------------------------------------
bool   ObjectCreate(long chart, const string& name, int type, int sub,
                    datetime t1=0, double p1=0, datetime t2=0, double p2=0);
int    ObjectFind(long chart, const string& name);
bool   ObjectDelete(long chart, const string& name);
int    ObjectsTotal(long chart=0, int sub=-1, int type=-1);
string ObjectName(long chart, int pos, int sub=-1, int type=-1);
bool   ObjectSetInteger(long chart, const string& name, int prop, long value);
bool   ObjectSetString(long chart, const string& name, int prop, const string& value);
