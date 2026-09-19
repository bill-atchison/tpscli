  MEMBER()
  INCLUDE('tpsOut.inc'),ONCE
  MAP
    MODULE('WINAPI')
      GetStdHandle(LONG),ULONG,PASCAL,RAW,PROC,NAME('GetStdHandle')
      WriteFile(ULONG,LONG,ULONG,*ULONG,LONG),SIGNED,PASCAL,RAW,PROC,NAME('WriteFile')
      ReadFile(ULONG,LONG,ULONG,*ULONG,LONG),SIGNED,PASCAL,RAW,PROC,NAME('ReadFile')
      GetLastError(),ULONG,PASCAL,RAW,NAME('GetLastError')
    END
  END
STD_INPUT_HANDLE   EQUATE(-10)
STD_OUTPUT_HANDLE  EQUATE(-11)

tpsOut.Init  PROCEDURE()
  CODE
  SELF.hOut = GetStdHandle(STD_OUTPUT_HANDLE)
  SELF.hIn  = GetStdHandle(STD_INPUT_HANDLE)
  SELF.StdinBuf &= NEW StringTheory

tpsOut.Write PROCEDURE(STRING s)
written  ULONG
done     LONG
  CODE
  LOOP WHILE done < LEN(s)
    written = 0
    IF WriteFile(SELF.hOut, ADDRESS(s) + done, LEN(s) - done, written, 0) = 0 OR written = 0 THEN HALT(3).   ! stdout gone: nothing else we can say
    done += written
  END

tpsOut.Line  PROCEDURE(STRING s)
  CODE
  SELF.Write(s & '<13,10>')

tpsOut.JStr  PROCEDURE(STRING s)
st   StringTheory
i    LONG
c    BYTE
  CODE
  st.SetValue(s)
  st.Replace('\', '\\')
  st.Replace('"', '\"')
  st.Replace('<13>', '\r')
  st.Replace('<10>', '\n')
  st.Replace('<9>', '\t')
  i = 1
  LOOP WHILE i <= st.Length()
    c = VAL(st.valueptr[i])
    IF c < 32 OR c >= 128         ! also escape high bytes: TPS text has no defined encoding,
                                   ! and a raw byte >= 128 is not valid UTF-8/JSON on its own
      st.ReplaceSlice(i, i, '\u00' & SUB('0123456789abcdef', BSHIFT(c,-4)+1, 1) & SUB('0123456789abcdef', BAND(c,0Fh)+1, 1))
      i += 6
    ELSE
      i += 1
    END
  END
  RETURN '"' & st.GetValue() & '"'

tpsOut.Fail  PROCEDURE(STRING code, STRING msg, LONG exitCode, <STRING extraJson>)
  CODE
  SELF.Line('{{ "ok": false, "op": null, "error": {{ "code": ' & SELF.JStr(code) & ', "message": ' & SELF.JStr(msg) & ' }' |
            & CHOOSE(OMITTED(extraJson) OR extraJson = '', '', ', ' & extraJson) & ', "complete": true }')
  HALT(exitCode)

! Left-aligned header row; data cells left-aligned for text-like columns, right-aligned for
! numeric ones. Column width = max(header len, widest cell in that column). 2-space separator,
! matching spec 4's worked example exactly (dash-rule width equals the data column width).
tpsOut.Table PROCEDURE(*TblColQ cols, *TblCellQ cells, LONG count, BYTE truncated)
! Column widths live in a queue, not a fixed array: the old LONG,DIM(64) made a result with more
! than 64 columns print NOTHING AT ALL - no header, no rows, no summary - and still exit 0
! (final-review I4). SELECT * on a real file with 70 fields is an ordinary case.
w      QUEUE,PRE(WQ)
Val      LONG
       END
nCols  LONG
i      LONG
r      LONG
c      LONG
idx    LONG
line   StringTheory
dash   StringTheory
txt    STRING(255)
pad    LONG
  CODE
  nCols = RECORDS(cols)
  IF nCols = 0 THEN RETURN.
  LOOP i = 1 TO nCols
    GET(cols, i)
    WQ:Val = LEN(CLIP(cols.Name)); ADD(w)
  END
  LOOP r = 1 TO count
    LOOP c = 1 TO nCols
      idx = (r - 1) * nCols + c
      GET(cells, idx)
      GET(w, c)
      IF LEN(CLIP(cells.Text)) > WQ:Val THEN WQ:Val = LEN(CLIP(cells.Text)); PUT(w).
    END
  END
  LOOP i = 1 TO nCols
    GET(cols, i); GET(w, i)
    line.Append(CHOOSE(i = 1, '', '  ') & CLIP(cols.Name) & ALL(' ', WQ:Val - LEN(CLIP(cols.Name))))
    dash.Append(CHOOSE(i = 1, '', '  ') & ALL('-', WQ:Val))
  END
  SELF.Line(line.GetValue())
  SELF.Line(dash.GetValue())
  LOOP r = 1 TO count
    line.Free()
    LOOP c = 1 TO nCols
      idx = (r - 1) * nCols + c
      GET(cells, idx)
      txt = cells.Text
      GET(cols, c); GET(w, c)
      pad = WQ:Val - LEN(CLIP(txt))
      IF cols.RightAlign
        line.Append(CHOOSE(c = 1, '', '  ') & ALL(' ', pad) & CLIP(txt))
      ELSE
        line.Append(CHOOSE(c = 1, '', '  ') & CLIP(txt) & ALL(' ', pad))
      END
    END
    SELF.Line(line.GetValue())
  END
  SELF.Line('(' & count & ' rows' & CHOOSE(truncated, ', truncated by LIMIT)', ')'))

tpsOut.ReadStdin PROCEDURE()
chunk STRING(4096)
got   ULONG
rc    LONG
  CODE
  IF SELF.StdinRead THEN RETURN SELF.StdinBuf.GetValue().
  SELF.StdinRead = 1
  LOOP
    got = 0
    rc = ReadFile(SELF.hIn, ADDRESS(chunk), SIZE(chunk), got, 0)
    IF rc = 0
      IF GetLastError() = 109 THEN BREAK.                 ! ERROR_BROKEN_PIPE = clean EOF on a pipe
      SELF.Fail('SYNTAX', 'Reading stdin failed (' & GetLastError() & ')', 1)
    END
    IF got = 0 THEN BREAK.
    SELF.StdinBuf.Append(chunk[1 : got])
  END
  RETURN SELF.StdinBuf.GetValue()
