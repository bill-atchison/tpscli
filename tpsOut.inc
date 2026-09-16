  OMIT('_EndTpsOut_',_TpsOutPresent_)
_TpsOutPresent_  EQUATE(1)
  INCLUDE('StringTheory.inc'),ONCE

tpsOut  CLASS,TYPE,MODULE('tpsOut.clw'),LINK('tpsOut.clw')
hOut      ULONG
hIn       ULONG
StdinBuf  &StringTheory
StdinRead BYTE
Init      PROCEDURE()
Write     PROCEDURE(STRING s)                 ! raw bytes to stdout
Line      PROCEDURE(STRING s)                 ! s + CRLF
JStr      PROCEDURE(STRING s),STRING          ! JSON string literal with quotes
Fail      PROCEDURE(STRING code, STRING msg, LONG exitCode, <STRING extraJson>)
ReadStdin PROCEDURE(),STRING
        END
  _EndTpsOut_
