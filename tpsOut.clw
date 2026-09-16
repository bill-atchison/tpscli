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
  LOOP i = 1 TO st.Length()
    c = VAL(st.valueptr[i])
    IF c < 32
      st.SetSlice(i, i, '\u00' & SUB('0123456789abcdef', BSHIFT(c,-4)+1, 1) & SUB('0123456789abcdef', BAND(c,0Fh)+1, 1))
      i += 5
    END
  END
  RETURN '"' & st.GetValue() & '"'

tpsOut.Fail  PROCEDURE(STRING code, STRING msg, LONG exitCode, <STRING extraJson>)
  CODE
  SELF.Line('{ "ok": false, "op": null, "error": { "code": ' & SELF.JStr(code) & ', "message": ' & SELF.JStr(msg) & ' }' |
            & CHOOSE(OMITTED(extraJson) OR extraJson = '', '', ', ' & extraJson) & ', "complete": true }')
  HALT(exitCode)

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
