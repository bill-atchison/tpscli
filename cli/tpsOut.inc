  OMIT('_EndTpsOut_',_TpsOutPresent_)
_TpsOutPresent_  EQUATE(1)
  INCLUDE('StringTheory.inc'),ONCE

TblColQ   QUEUE,TYPE              ! one entry per output column, in display order
Name        STRING(128)
RightAlign  BYTE                  ! 1 = right-align data cells (numeric types), 0 = left-align
          END
TblCellQ  QUEUE,TYPE              ! flattened row-major cell text; RECORDS(cells) = rows * RECORDS(cols)
Text        STRING(255)
          END

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
Table     PROCEDURE(*TblColQ cols, *TblCellQ cells, LONG count, BYTE truncated)
        END
  _EndTpsOut_
