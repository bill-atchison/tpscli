  PROGRAM
  INCLUDE('DynFile.inc'),ONCE
  INCLUDE('StringTheory.inc'),ONCE
  MAP
    MODULE('WINAPI')
      GetStdHandle(LONG),ULONG,PASCAL,RAW,PROC,NAME('GetStdHandle')
      WriteFile(ULONG,LONG,ULONG,*ULONG,LONG),SIGNED,PASCAL,RAW,PROC,NAME('WriteFile')
    END
    Dump(FILE f, STRING name)
    MakeAll()
    Check(STRING what)
  END
STD_ERROR_HANDLE  EQUATE(-12)

AllTypes FILE,DRIVER('TOPSPEED'),NAME('testdata\ALLTYPES.TPS'),PRE(AT),CREATE
IdKey      KEY(AT:Id),PRIMARY
Record       RECORD
Id           LONG
B            BYTE
S            SHORT
US           USHORT
UL           ULONG
SR           SREAL
R            REAL
D            DECIMAL(7,2)
Dt           DATE
Tm           TIME
Str          STRING(20)
CStr         CSTRING(21)
PStr         PSTRING(21)
Pic          STRING(@N9.2)
Arr          SHORT,DIM(4)
             END
         END

Keys     FILE,DRIVER('TOPSPEED'),NAME('testdata\KEYS.TPS'),PRE(KY),CREATE
PKey       KEY(KY:Id),PRIMARY
DupKey     KEY(KY:Name),DUP,NOCASE
OptKey     KEY(KY:Code),OPT
DescKey    KEY(-KY:Amount,+KY:Id),DUP
Idx        INDEX(KY:Name)
Record       RECORD
Id           LONG
Name         STRING(30)
Code         STRING(4)
Amount       DECIMAL(9,2)
             END
         END

Groups   FILE,DRIVER('TOPSPEED'),NAME('testdata\GROUPS.TPS'),PRE(GR),CREATE
IdKey      KEY(GR:Id),PRIMARY
Record       RECORD
Id           LONG
Addr           GROUP
Line1            STRING(30)
City             STRING(20)
Geo                GROUP
Lat                  REAL
Lon                  REAL
                   END
               END
Phones         GROUP,DIM(2)
Kind             STRING(1)
Number           STRING(12)
Ext              STRING(2),DIM(2)
               END
Raw            STRING(8)
RawL           LONG,OVER(Raw)
Grid           SHORT,DIM(2,3)
             END
         END

Memos    FILE,DRIVER('TOPSPEED'),NAME('testdata\MEMOS.TPS'),PRE(MM),CREATE
IdKey      KEY(MM:Id),PRIMARY
Notes      MEMO(1000)
Bin        MEMO(500),BINARY
Pic        BLOB
Record       RECORD
Id           LONG
Title        STRING(20)
             END
         END

NoKey    FILE,DRIVER('TOPSPEED'),NAME('testdata\NOKEY.TPS'),PRE(NK),CREATE
Record       RECORD
Code         STRING(4)
Qty          LONG
             END
         END

Secret   FILE,DRIVER('TOPSPEED'),NAME('testdata\SECRET.TPS'),PRE(SC),OWNER('s3cret'),ENCRYPT,CREATE
IdKey      KEY(SC:Id),PRIMARY
Record       RECORD
Id           LONG
Note         STRING(40)
             END
         END

  CODE
  MakeAll()

Dump  PROCEDURE(FILE f, STRING name)
dyn   DynFile
st    StringTheory
i     LONG
j     LONG
  CODE
  dyn.CreateFromFile(f)
  st.SetValue('{{ "file": "' & name & '", "fields": [')
  LOOP i = 1 TO RECORDS(dyn.FieldQ)
    GET(dyn.FieldQ, i)
    st.Append(CHOOSE(i = 1, '', ',') & '{{"nbr":' & dyn.FieldQ.FieldNbr & ',"label":"' & CLIP(dyn.FieldQ.Label) |
              & '","type":"' & CLIP(dyn.FieldQ.Type) |
              & '","size":' & dyn.FieldQ.Size & ',"places":' & dyn.FieldQ.Places |
              & ',"dim":' & dyn.FieldQ.Dim & ',"over":' & dyn.FieldQ.Over |
              & ',"fields":' & dyn.FieldQ.Fields & ',"picture":"' & CLIP(dyn.FieldQ.Picture) & '"}')
  END
  st.Append('], "memos": [')
  LOOP i = 1 TO RECORDS(dyn.MemoQ)
    GET(dyn.MemoQ, i)
    st.Append(CHOOSE(i = 1, '', ',') & '{{"nbr":' & dyn.MemoQ.MemoNbr & ',"label":"' & CLIP(dyn.MemoQ.Label) |
              & '","type":"' & dyn.MemoQ.Type |
              & '","binary":' & dyn.MemoQ.Binary & ',"size":' & dyn.MemoQ.size & '}')
  END
  st.Append('], "keys": [')
  LOOP i = 1 TO RECORDS(dyn.KeyQ)
    GET(dyn.KeyQ, i)
    st.Append(CHOOSE(i = 1, '', ',') & '{{"nbr":' & dyn.KeyQ.KeyNbr & ',"label":"' & CLIP(dyn.KeyQ.Label) & '","type":"' & dyn.KeyQ.Type |
              & '","dup":' & dyn.KeyQ.Dup & ',"primary":' & dyn.KeyQ.Primary |
              & ',"nocase":' & dyn.KeyQ.NoCase & ',"opt":' & dyn.KeyQ.Opt & ',"components":[')
    LOOP j = 1 TO RECORDS(dyn.KeyQ.FieldQ)
      GET(dyn.KeyQ.FieldQ, j)
      st.Append(CHOOSE(j = 1, '', ',') & '{{"label":"' & CLIP(dyn.KeyQ.FieldQ.FieldLabel) & '","nbr":' & dyn.KeyQ.FieldQ.FieldNbr |
                & ',"asc":' & dyn.KeyQ.FieldQ.Ascending & ',"rank":' & dyn.KeyQ.FieldQ.Rank & '}')
    END
    st.Append(']}')
  END
  st.Append('] }')
  st.SaveFile('testdata\expected\' & name & '.json')

Check  PROCEDURE(STRING what)
outMsg   STRING(500)
written  ULONG
  CODE
  IF ERRORCODE()
    outMsg = what & ': ' & ERRORCODE() & ' ' & CLIP(ERROR()) & '<13,10>'
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), ADDRESS(outMsg), LEN(CLIP(outMsg)), written, 0)
    HALT(1)
  END

MakeAll  PROCEDURE()
  CODE
  REMOVE(AllTypes)
  CREATE(AllTypes); Check('CREATE AllTypes')
  OPEN(AllTypes); Check('OPEN AllTypes')
  CLEAR(AT:Record); AT:Id = 1; AT:B = 200; AT:S = -12345; AT:US = 65000; AT:UL = 4000000000
  AT:SR = 1.5; AT:R = -2.25; AT:D = 12345.67; AT:Dt = DATE(9,15,2026)
  AT:Tm = DEFORMAT('13:45:30',@T4); AT:Str = 'alpha'; AT:CStr = 'beta'; AT:PStr = 'gamma'
  AT:Pic = 42.5; AT:Arr[1] = 10; AT:Arr[2] = 20; AT:Arr[3] = 30; AT:Arr[4] = 40
  ADD(AllTypes); Check('ADD AllTypes 1')
  CLEAR(AT:Record); AT:Id = 2; AT:Str = 'MINI MARSHMALLOWS'; AT:D = 1.25
  ADD(AllTypes); Check('ADD AllTypes 2')
  CLEAR(AT:Record); AT:Id = 3; AT:Str = 'zed'; AT:Dt = 0
  ADD(AllTypes); Check('ADD AllTypes 3')
  Dump(AllTypes, 'ALLTYPES'); CLOSE(AllTypes)

  REMOVE(Keys)
  CREATE(Keys); Check('CREATE Keys')
  OPEN(Keys); Check('OPEN Keys')
  CLEAR(KY:Record); KY:Id = 1; KY:Name = 'Able';   KY:Code = 'A'; KY:Amount = 5
  ADD(Keys); Check('ADD Keys 1')
  CLEAR(KY:Record); KY:Id = 2; KY:Name = 'baker';  KY:Code = '';  KY:Amount = 4
  ADD(Keys); Check('ADD Keys 2')
  CLEAR(KY:Record); KY:Id = 3; KY:Name = 'Charlie';KY:Code = 'C'; KY:Amount = 3
  ADD(Keys); Check('ADD Keys 3')
  CLEAR(KY:Record); KY:Id = 4; KY:Name = 'delta';  KY:Code = '';  KY:Amount = 2
  ADD(Keys); Check('ADD Keys 4')
  CLEAR(KY:Record); KY:Id = 5; KY:Name = 'Echo';   KY:Code = 'E'; KY:Amount = 1
  ADD(Keys); Check('ADD Keys 5')
  Dump(Keys, 'KEYS'); CLOSE(Keys)

  REMOVE(Groups)
  CREATE(Groups); Check('CREATE Groups')
  OPEN(Groups); Check('OPEN Groups')
  CLEAR(GR:Record); GR:Id = 1
  GR:Line1 = 'One Main St'; GR:City = 'Springfield'; GR:Lat = 39.78; GR:Lon = -89.65
  GR:Kind[1] = 'H'; GR:Number[1] = '555-1000'; GR:Phones[1].Ext[1] = 'a1'; GR:Phones[1].Ext[2] = 'a2'
  GR:Kind[2] = 'M'; GR:Number[2] = '555-2000'; GR:Phones[2].Ext[1] = 'b1'; GR:Phones[2].Ext[2] = 'b2'
  GR:RawL = 305419896
  GR:Grid[1,1] = 1; GR:Grid[1,2] = 2; GR:Grid[1,3] = 3
  GR:Grid[2,1] = 4; GR:Grid[2,2] = 5; GR:Grid[2,3] = 6
  ADD(Groups); Check('ADD Groups 1')
  CLEAR(GR:Record); GR:Id = 2
  GR:Line1 = 'Two Elm Ave'; GR:City = 'Shelbyville'; GR:Lat = 40.12; GR:Lon = -88.99
  GR:Kind[1] = 'H'; GR:Number[1] = '555-3000'; GR:Phones[1].Ext[1] = 'c1'; GR:Phones[1].Ext[2] = 'c2'
  GR:Kind[2] = 'M'; GR:Number[2] = '555-4000'; GR:Phones[2].Ext[1] = 'd1'; GR:Phones[2].Ext[2] = 'd2'
  GR:RawL = 305419896
  GR:Grid[1,1] = 7; GR:Grid[1,2] = 8; GR:Grid[1,3] = 9
  GR:Grid[2,1] = 10; GR:Grid[2,2] = 11; GR:Grid[2,3] = 12
  ADD(Groups); Check('ADD Groups 2')
  Dump(Groups, 'GROUPS'); CLOSE(Groups)

  REMOVE(Memos)
  CREATE(Memos); Check('CREATE Memos')
  OPEN(Memos); Check('OPEN Memos')
  CLEAR(MM:Record); MM:Id = 1; MM:Title = 'First'
  MM:Notes = 'line one' & CHR(13) & CHR(10) & 'line two'
  MM:Bin = 'x' & CHR(0) & 'y' & CHR(255)
  MM:Pic{PROP:Size} = 4; MM:Pic[0 : 3] = 'PNG?'
  ADD(Memos); Check('ADD Memos 1')
  CLEAR(MM:Record); MM:Id = 2; MM:Title = 'Second'
  MM:Notes = 'alpha' & CHR(13) & CHR(10) & 'beta'
  MM:Bin = 'p' & CHR(1) & 'q' & CHR(254)
  MM:Pic{PROP:Size} = 3; MM:Pic[0 : 2] = 'ABC'
  ADD(Memos); Check('ADD Memos 2')
  Dump(Memos, 'MEMOS'); CLOSE(Memos)

  REMOVE(NoKey)
  CREATE(NoKey); Check('CREATE NoKey')
  OPEN(NoKey); Check('OPEN NoKey')
  CLEAR(NK:Record); NK:Code = 'AA'; NK:Qty = 1
  ADD(NoKey); Check('ADD NoKey 1')
  CLEAR(NK:Record); NK:Code = 'BB'; NK:Qty = 2
  ADD(NoKey); Check('ADD NoKey 2')
  CLEAR(NK:Record); NK:Code = 'AA'; NK:Qty = 3
  ADD(NoKey); Check('ADD NoKey 3')
  Dump(NoKey, 'NOKEY'); CLOSE(NoKey)

  REMOVE(Secret)
  CREATE(Secret); Check('CREATE Secret')
  OPEN(Secret); Check('OPEN Secret')
  CLEAR(SC:Record); SC:Id = 1; SC:Note = 'Alpha secret'
  ADD(Secret); Check('ADD Secret 1')
  CLEAR(SC:Record); SC:Id = 2; SC:Note = 'Beta secret'
  ADD(Secret); Check('ADD Secret 2')
  Dump(Secret, 'SECRET'); CLOSE(Secret)
