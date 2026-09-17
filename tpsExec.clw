  MEMBER()
  INCLUDE('tpsExec.inc'),ONCE
  MAP
    TpsExecIsNumericType(STRING typ),BYTE
    TpsExecUnjson(STRING js),STRING
    TpsExecPad2(LONG n),STRING
  END

! ---- construction ----

tpsExec.Construct PROCEDURE()
  CODE
  SELF.Cols &= NEW OutColQ
  SELF.Conv &= NEW ConvQ
  SELF.Rows &= NEW StringTheory
  SELF.Warnings &= NEW StringTheory

tpsExec.Destruct PROCEDURE()
i  LONG
  CODE
  LOOP i = 1 TO RECORDS(SELF.Conv)
    GET(SELF.Conv, i)
    IF NOT SELF.Conv.Txt &= NULL THEN DISPOSE(SELF.Conv.Txt).
  END
  DISPOSE(SELF.Cols); DISPOSE(SELF.Conv)
  DISPOSE(SELF.Rows); DISPOSE(SELF.Warnings)

tpsExec.Run PROCEDURE()
  CODE
  CASE SELF.Sql.Op
  OF OP:Select ; RETURN SELF.DoSelect()
  OF OP:Insert ; RETURN SELF.DoInsert()
  OF OP:Update ; RETURN SELF.DoUpdate()
  OF OP:Delete ; RETURN SELF.DoDelete()
  END
  RETURN SELF.ErrOut('', 'UNSUPPORTED', 'Not implemented', 'none', 1)

! ---- column expansion ----

! Explicit columns: tpsSql already resolved each entry to a specific field/memo (Path is the
! exact display name, e.g. "PHONES[2].EXT[2]"); only a bare GROUP or a bare (unsubscripted)
! DIM'd field needs to expand to its scalar leaves via AddLeaf, same as * does.
tpsExec.ExpandCols PROCEDURE()
i    LONG
f    SchFieldQ
c    ColQ
pfx  STRING(128)
  CODE
  FREE(SELF.Cols)
  IF SELF.Sql.Star
    LOOP i = 1 TO RECORDS(SELF.Sch.Fields)
      GET(SELF.Sch.Fields, i)
      IF SELF.Sch.Fields.Parent = 0 THEN SELF.AddLeaf(i, '', 0).
    END
    LOOP i = 1 TO RECORDS(SELF.Sch.Memos)
      GET(SELF.Sch.Memos, i)
      CLEAR(SELF.Cols); SELF.Cols.Name = SELF.Sch.Memos.Label; SELF.Cols.MemoNbr = i
      SELF.Cols.Type = CHOOSE(SELF.Sch.Memos.IsBlob, 'BLOB', 'MEMO'); ADD(SELF.Cols)
    END
  ELSE
    LOOP i = 1 TO RECORDS(SELF.Sql.Cols)
      GET(SELF.Sql.Cols, i)
      IF SELF.Sql.Cols.MemoNbr
        GET(SELF.Sch.Memos, SELF.Sql.Cols.MemoNbr)
        CLEAR(SELF.Cols); SELF.Cols.Name = SELF.Sql.Cols.Path; SELF.Cols.MemoNbr = SELF.Sql.Cols.MemoNbr
        SELF.Cols.Type = CHOOSE(SELF.Sch.Memos.IsBlob, 'BLOB', 'MEMO'); ADD(SELF.Cols)
      ELSE
        c = SELF.Sql.Cols                             ! FlatElem takes a by-value ColQ; the live &ColQ member doesn't match
        GET(SELF.Sch.Fields, c.FieldNbr); f = SELF.Sch.Fields
        pfx = CHOOSE(CLIP(c.Prefix) = '', '', CLIP(c.Prefix) & '.')
        IF f.Type = 'GROUP' OR (f.Elements > 1 AND c.Elem = 0)
          SELF.AddLeaf(c.FieldNbr, pfx, c.GrpElem)
        ELSE
          CLEAR(SELF.Cols)
          SELF.Cols.Name = c.Path
          SELF.Cols.FieldNbr = c.FieldNbr
          SELF.Cols.GrpElem = c.GrpElem; SELF.Cols.Elem = c.Elem
          SELF.Cols.Type = f.Type
          ADD(SELF.Cols)
        END
      END
    END
  END

! elem, when > 0 and this call is not recursing into a GROUP, is the element of an ENCLOSING
! dimmed GROUP this leaf sits inside - never this leaf's own subscript. WHAT()'s dimension
! parameter cannot select an enclosing group's occurrence (confirmed empirically: it only ever
! selects among the FIELD'S OWN elements, so WHAT(kindFieldNbr,2) is invalid/blank and
! WHAT(extFieldNbr,2) returns PHONES[1].EXT[2], never PHONES[2].EXT[anything] - see
! task-7-report.md), so GrpElem and the leaf's own Elem are kept SEPARATE on the column and
! Format() does the group-relative byte slice itself; nothing here combines them into one index.
tpsExec.AddLeaf PROCEDURE(LONG fieldNbr, STRING namePrefix, LONG elem)
f     SchFieldQ
e     LONG
j     LONG
nm    STRING(128)
  CODE
  GET(SELF.Sch.Fields, fieldNbr); f = SELF.Sch.Fields
  nm = CLIP(namePrefix) & CLIP(f.Label)
  IF f.Type = 'GROUP'
    LOOP e = 1 TO CHOOSE(f.Elements > 1, f.Elements, 1)
      LOOP j = fieldNbr+1 TO RECORDS(SELF.Sch.Fields)
        GET(SELF.Sch.Fields, j)
        IF SELF.Sch.Fields.Parent = fieldNbr
          SELF.AddLeaf(j, CLIP(nm) & CHOOSE(f.Elements > 1, '[' & e & ']', '') & '.', CHOOSE(f.Elements > 1, e, 0))
        END
      END
    END
    RETURN
  END
  IF elem > 0 AND f.Elements > 1
    LOOP e = 1 TO f.Elements
      CLEAR(SELF.Cols)
      SELF.Cols.Name = CLIP(nm) & '[' & e & ']'
      SELF.Cols.FieldNbr = fieldNbr; SELF.Cols.GrpElem = elem; SELF.Cols.Elem = e; SELF.Cols.Type = f.Type
      ADD(SELF.Cols)
    END
    RETURN
  END
  IF elem > 0
    CLEAR(SELF.Cols)
    SELF.Cols.Name = nm; SELF.Cols.FieldNbr = fieldNbr; SELF.Cols.GrpElem = elem; SELF.Cols.Type = f.Type
    ADD(SELF.Cols)
    RETURN
  END
  IF f.Elements > 1
    LOOP e = 1 TO f.Elements
      CLEAR(SELF.Cols)
      SELF.Cols.Name = CLIP(nm) & '[' & e & ']'
      SELF.Cols.FieldNbr = fieldNbr; SELF.Cols.Elem = e; SELF.Cols.Type = f.Type
      ADD(SELF.Cols)
    END
    RETURN
  END
  CLEAR(SELF.Cols)
  SELF.Cols.Name = nm; SELF.Cols.FieldNbr = fieldNbr; SELF.Cols.Elem = 0; SELF.Cols.Type = f.Type
  ADD(SELF.Cols)

! ---- formatting ----

! grpElem = 0: ordinary WHAT(fieldNbr,elem) read (tpsSchema.FieldRef).
! grpElem > 0: fieldNbr is a leaf inside a DIM'd GROUP's grpElem'th occurrence. WHAT cannot
! address that occurrence via the leaf's own field number (see AddLeaf's comment and
! task-7-report.md for the empirical proof), so this reads the ENCLOSING group's occurrence as
! raw bytes - WHAT(rec,groupWhoIdx,grpElem) - and slices the leaf out at its offset relative to
! the group's own offset. Ponytail ceiling: only STRING-typed leaves are sliced this way (the
! only shape this corpus nests inside a DIM'd group); a numeric/date/time leaf nested the same
! way would need its raw bytes reinterpreted by type, which nothing in this corpus exercises.
tpsExec.Format PROCEDURE(LONG fieldNbr, LONG grpElem, LONG elem)
v    ANY
d    LONG
t    LONG
s    STRING(4096)
hs   LONG
sec  LONG
mi   LONG
hh   LONG
g    SchFieldQ
grp  ANY
raw  STRING(512)
relOfs LONG
elemSize LONG
rec  &GROUP
parentNbr LONG
  CODE
  GET(SELF.Sch.Fields, fieldNbr)
  IF grpElem > 0
    IF SELF.Sch.Fields.Type <> 'STRING' AND SELF.Sch.Fields.Type <> 'CSTRING' AND SELF.Sch.Fields.Type <> 'PSTRING'
      SELF.ErrCode = 'UNSUPPORTED'; SELF.ErrMsg = 'Cannot read ' & CLIP(SELF.Sch.Fields.Label) & ' past the first element of its enclosing GROUP'
      RETURN ''
    END
    parentNbr = SELF.Sch.Fields.Parent
    GET(SELF.Sch.Fields, parentNbr); g = SELF.Sch.Fields
    GET(SELF.Sch.Who, g.Nbr)
    rec &= SELF.Sch.F{PROP:Record}
    grp &= WHAT(rec, SELF.Sch.Who.Idx, grpElem)
    IF grp &= NULL
      SELF.ErrCode = 'DRIVER'; SELF.ErrMsg = 'WHAT could not read ' & CLIP(g.Label) & '[' & grpElem & ']'
      RETURN ''
    END
    raw = grp
    GET(SELF.Sch.Fields, fieldNbr)
    elemSize = CHOOSE(SELF.Sch.Fields.Elements > 1, SELF.Sch.Fields.Bytes / SELF.Sch.Fields.Elements, SELF.Sch.Fields.Size)
    relOfs = SELF.Sch.Fields.Offset - g.Offset + (CHOOSE(elem > 0, elem - 1, 0)) * elemSize
    RETURN SELF.Out.JStr(CLIP(SUB(raw, relOfs + 1, elemSize)))
  END
  v &= SELF.Sch.FieldRef(fieldNbr, elem)
  CASE SELF.Sch.Fields.Type
  OF 'DATE'
    d = v
    IF d = 0 THEN RETURN '""'.
    RETURN '"' & YEAR(d) & '-' & TpsExecPad2(MONTH(d)) & '-' & TpsExecPad2(DAY(d)) & '"'
  OF 'TIME'
    t = v
    IF t = 0 THEN RETURN '""'.
    t -= 1; hs = t % 100; t = t / 100; sec = t % 60; t = t / 60; mi = t % 60; hh = t / 60
    RETURN '"' & TpsExecPad2(hh) & ':' & TpsExecPad2(mi) & ':' & TpsExecPad2(sec) & '.' & TpsExecPad2(hs) & '"'
  OF 'DECIMAL'
    s = v                                   ! DECIMAL to STRING keeps the declared places
    RETURN '"' & CLIP(LEFT(s)) & '"'
  OF 'STRING' OROF 'CSTRING' OROF 'PSTRING' OROF 'GROUP'
    s = v
    RETURN SELF.Out.JStr(CLIP(s))
  ELSE                                       ! BYTE SHORT USHORT LONG ULONG SREAL REAL
    s = v
    RETURN CLIP(LEFT(s))
  END

! Format/FormatMemo return '' with SELF.ErrCode/ErrMsg set on failure; DoSelect checks
! ErrCode after every cell and aborts the statement with that code.
! MemoRef (tpsSchema, Task 5) already resolves the memo by value with no null case, so the
! MEMO branch is exactly the controller's one-liner; only BLOB needs a reachability check.
! PROP:Blob's index is the memo/blob ordinal among ALL memos+blobs combined (SchMemoQ.Nbr),
! negative, matching MemoRef's own -memoNbr convention (confirmed against the shipped
! jFiles.clw BlobsToJSON/FillBlobs pattern: BlobRef &= pFile{prop:Blob,-m} for m counted
! across memos-then-blobs together, not blobs alone).
tpsExec.FormatMemo PROCEDURE(LONG memoNbr)
st   StringTheory
b    &BLOB
  CODE
  GET(SELF.Sch.Memos, memoNbr)
  IF SELF.Sch.Memos.IsBlob
    b &= SELF.Sch.F{PROP:Blob, -memoNbr}
    IF b &= NULL THEN SELF.ErrCode = 'UNSUPPORTED'; SELF.ErrMsg = 'BLOB access not available on dynamic files'; RETURN ''.
    IF b{PROP:Size} = 0 THEN RETURN '""'.
    st.SetValue(b[0 : b{PROP:Size}-1])
    IF st.Base64Encode(st:NoWrap) <> st:ok THEN SELF.ErrCode = 'DRIVER'; SELF.ErrMsg = 'base64 encode failed'; RETURN ''.
    RETURN SELF.Out.JStr(st.GetValue())
  END
  RETURN SELF.Out.JStr(CLIP(SELF.Sch.MemoRef(memoNbr)))

! ---- WHERE / ORDER BY plumbing ----

tpsExec.Matches PROCEDURE()
r  STRING(20)
  CODE
  IF NOT SELF.Sql.HasWhere THEN RETURN 1.
  r = EVALUATE(SELF.Sql.Where)
  IF ERRORCODE() THEN RETURN 2.                       ! caller reports SYNTAX with the expression
  RETURN CHOOSE(r = '1' OR (NUMERIC(r) AND r <> 0), 1, 0)

! Optional keys omit rows whose components are blank or zero, so they are never used for
! ORDER BY (a key can silently skip qualifying rows there); the sort fallback handles that
! ORDER BY instead. NoCase keys (DupKey) ARE eligible - see task-7-report.md for what that
! does to case-sensitive expectations.
tpsExec.ChooseKey PROCEDURE(*BYTE reverse)
k     LONG
n     LONG
j     LONG
fwd   BYTE
bwd   BYTE
  CODE
  reverse = 0
  IF RECORDS(SELF.Sql.Order) = 0 THEN RETURN 0.
  LOOP k = 1 TO RECORDS(SELF.Sch.Keys)
    GET(SELF.Sch.Keys, k)
    IF SELF.Sch.Keys.Opt THEN CYCLE.
    fwd = 1; bwd = 1; n = 0
    LOOP j = 1 TO RECORDS(SELF.Sch.Comps)
      GET(SELF.Sch.Comps, j)
      IF SELF.Sch.Comps.KeyNbr <> k THEN CYCLE.
      n += 1
      IF n > RECORDS(SELF.Sql.Order) THEN BREAK.
      GET(SELF.Sql.Order, n)
      IF SELF.Sql.Order.FieldNbr <> SELF.Sch.Comps.FieldNbr OR SELF.Sql.Order.Elem <> 0 THEN fwd = 0; bwd = 0; BREAK.
      IF SELF.Sql.Order.Desc = SELF.Sch.Comps.Descending THEN bwd = 0 ELSE fwd = 0.
    END
    IF n < RECORDS(SELF.Sql.Order) THEN CYCLE.       ! key shorter than ORDER BY
    IF fwd THEN RETURN k.
    IF bwd THEN reverse = 1; RETURN k.
  END
  RETURN 0

! ---- SELECT ----

tpsExec.DoSelect PROCEDURE()
rec       &GROUP
key       &KEY
posq      &SortQ
k         LONG
reverse   BYTE
limit     LONG
skipped   LONG
kept      LONG
truncated BYTE
failRc    LONG
mrc       BYTE
er        LONG
i         LONG
j         LONG                    ! EmitRow's own loop counter - never share `i` with any loop that DOes EmitRow (EmitRow is a ROUTINE, not its own stack frame, so it clobbers a shared counter)
useSort   BYTE
sortSpec  StringTheory
sign      STRING(1)
fld       STRING(2)
v         ANY
outp      StringTheory
first     BYTE
cellJson  STRING(4096)
tcells    &TblCellQ
tcols     &TblColQ
  CODE
  SELF.Rows.Free()
  tcells &= NEW TblCellQ
  rec &= SELF.Sch.F{PROP:Record}
  PUSHBIND
  BIND(rec)
  SELF.ExpandCols()

  limit = CHOOSE(SELF.Sql.HasLimit, SELF.Sql.Limit, SELF.LimitDefault)
  k = SELF.ChooseKey(reverse)
  useSort = CHOOSE(RECORDS(SELF.Sql.Order) > 0 AND k = 0, 1, 0)

  IF useSort
    ! ponytail ceiling, documented in the spec's own fallback design: at most four ORDER BY
    ! columns, each a STRING(255) or DECIMAL(31,15) component - ample for this corpus; a
    ! wider column or a fifth ORDER BY needs a real key instead of raising these limits.
    IF RECORDS(SELF.Sql.Order) > 4
      failRc = SELF.ErrOut('select', 'UNSUPPORTED', 'ORDER BY needs a key for this column', 'none', 1)
    ELSE
      posq &= NEW SortQ
      LOOP i = 1 TO RECORDS(SELF.Sql.Order)
        GET(SELF.Sql.Order, i)
        sign = CHOOSE(SELF.Sql.Order.Desc, '-', '+')
        GET(SELF.Sch.Fields, SELF.Sql.Order.FieldNbr)
        fld = CHOOSE(TpsExecIsNumericType(SELF.Sch.Fields.Type), 'K' & i, 'S' & i)
        sortSpec.Append(CHOOSE(i = 1, '', ',') & sign & fld)
      END
      SET(SELF.Sch.F)
      LOOP
        NEXT(SELF.Sch.F)
        er = ERRORCODE()
        IF er
          IF er <> 33 THEN failRc = SELF.ErrOut('select', 'DRIVER', er & ' ' & CLIP(ERROR()), 'none', 3).
          BREAK
        END
        mrc = SELF.Matches()
        IF mrc = 2
          failRc = SELF.ErrOut('select', 'SYNTAX', 'Runtime rejected the expression: ' & CLIP(SELF.Sql.Where), 'none', 1)
          BREAK
        END
        IF mrc = 0 THEN CYCLE.
        CLEAR(posq)
        LOOP i = 1 TO RECORDS(SELF.Sql.Order)
          GET(SELF.Sql.Order, i)
          v &= SELF.Sch.FieldRef(SELF.Sql.Order.FieldNbr, SELF.Sql.Order.Elem)
          GET(SELF.Sch.Fields, SELF.Sql.Order.FieldNbr)
          CASE i
          OF 1 ; IF TpsExecIsNumericType(SELF.Sch.Fields.Type) THEN posq.K1 = v ELSE posq.S1 = v.
          OF 2 ; IF TpsExecIsNumericType(SELF.Sch.Fields.Type) THEN posq.K2 = v ELSE posq.S2 = v.
          OF 3 ; IF TpsExecIsNumericType(SELF.Sch.Fields.Type) THEN posq.K3 = v ELSE posq.S3 = v.
          OF 4 ; IF TpsExecIsNumericType(SELF.Sch.Fields.Type) THEN posq.K4 = v ELSE posq.S4 = v.
          END
        END
        posq.Pos = POSITION(SELF.Sch.F)
        ADD(posq)
      END
      IF failRc = 0
        SORT(posq, sortSpec.GetValue())
        LOOP i = 1 TO RECORDS(posq)
          GET(posq, i)
          REGET(SELF.Sch.F, posq.Pos)
          IF ERRORCODE()
            failRc = SELF.ErrOut('select', 'DRIVER', ERRORCODE() & ' ' & CLIP(ERROR()), 'none', 3)
            BREAK
          END
          DO EmitRow
          IF failRc OR truncated THEN BREAK.
        END
      END
      DISPOSE(posq)
    END
  ELSIF k > 0
    key &= SELF.Sch.KeyRef(k)
    SET(key)
    LOOP
      IF reverse THEN PREVIOUS(SELF.Sch.F) ELSE NEXT(SELF.Sch.F).
      er = ERRORCODE()
      IF er
        IF er <> 33 THEN failRc = SELF.ErrOut('select', 'DRIVER', er & ' ' & CLIP(ERROR()), 'none', 3).
        BREAK
      END
      mrc = SELF.Matches()
      IF mrc = 2
        failRc = SELF.ErrOut('select', 'SYNTAX', 'Runtime rejected the expression: ' & CLIP(SELF.Sql.Where), 'none', 1)
        BREAK
      END
      IF mrc = 0 THEN CYCLE.
      DO EmitRow
      IF failRc OR truncated THEN BREAK.
    END
  ELSE
    SET(SELF.Sch.F)
    LOOP
      NEXT(SELF.Sch.F)
      er = ERRORCODE()
      IF er
        IF er <> 33 THEN failRc = SELF.ErrOut('select', 'DRIVER', er & ' ' & CLIP(ERROR()), 'none', 3).
        BREAK
      END
      mrc = SELF.Matches()
      IF mrc = 2
        failRc = SELF.ErrOut('select', 'SYNTAX', 'Runtime rejected the expression: ' & CLIP(SELF.Sql.Where), 'none', 1)
        BREAK
      END
      IF mrc = 0 THEN CYCLE.
      DO EmitRow
      IF failRc OR truncated THEN BREAK.
    END
  END

  POPBIND
  IF failRc <> 0 THEN DISPOSE(tcells); RETURN failRc.

  IF SELF.WantTable
    tcols &= NEW TblColQ
    LOOP i = 1 TO RECORDS(SELF.Cols)
      GET(SELF.Cols, i)
      CLEAR(tcols); tcols.Name = SELF.Cols.Name; tcols.RightAlign = TpsExecIsNumericType(SELF.Cols.Type)
      ADD(tcols)
    END
    SELF.Out.Table(tcols, tcells, kept, truncated)
    DISPOSE(tcols); DISPOSE(tcells)
    RETURN 0
  END
  DISPOSE(tcells)

  outp.SetValue('{{ "ok": true, "op": "select", "columns": [')
  LOOP i = 1 TO RECORDS(SELF.Cols)
    GET(SELF.Cols, i)
    outp.Append(CHOOSE(i = 1, '', ',') & '{{"name":' & SELF.Out.JStr(CLIP(SELF.Cols.Name)) & ',"type":' & SELF.Out.JStr(CLIP(SELF.Cols.Type)) & '}')
  END
  outp.Append('], "rows": [' & SELF.Rows.GetValue() & '], "row_count": ' & kept & ', "truncated": ' & CHOOSE(truncated, 'true', 'false') & ', "complete": true }')
  SELF.Out.Line(outp.GetValue())
  RETURN 0

EmitRow ROUTINE
  IF skipped < SELF.Sql.Offset
    skipped += 1
  ELSIF limit > 0 AND kept = limit
    truncated = 1
  ELSE
    outp.Free(); first = 1
    LOOP j = 1 TO RECORDS(SELF.Cols)
      GET(SELF.Cols, j)
      IF SELF.Cols.MemoNbr
        cellJson = SELF.FormatMemo(SELF.Cols.MemoNbr)
      ELSE
        cellJson = SELF.Format(SELF.Cols.FieldNbr, SELF.Cols.GrpElem, SELF.Cols.Elem)
      END
      IF SELF.ErrCode <> ''
        failRc = SELF.ErrOut('select', SELF.ErrCode, SELF.ErrMsg, 'none', CHOOSE(SELF.ErrCode = 'DRIVER', 3, 1))
        SELF.ErrCode = ''
        BREAK
      END
      outp.Append(CHOOSE(first, '', ',') & CLIP(cellJson))
      first = 0
      IF SELF.WantTable
        CLEAR(tcells); tcells.Text = TpsExecUnjson(CLIP(cellJson)); ADD(tcells)
      END
    END
    IF failRc = 0
      SELF.Rows.Append(CHOOSE(kept = 0, '', ',') & '[' & outp.GetValue() & ']')
      kept += 1
    END
  END

! ---- writes: Task 8/9 ----

tpsExec.DoInsert PROCEDURE()
  CODE
  RETURN SELF.ErrOut('insert', 'UNSUPPORTED', 'Not implemented', 'none', 1)

tpsExec.DoUpdate PROCEDURE()
  CODE
  RETURN SELF.ErrOut('update', 'UNSUPPORTED', 'Not implemented', 'none', 1)

tpsExec.DoDelete PROCEDURE()
  CODE
  RETURN SELF.ErrOut('delete', 'UNSUPPORTED', 'Not implemented', 'none', 1)

! Stubs for Task 8/9. Not exercised by SELECT; bodies are placeholders only.
tpsExec.Validate PROCEDURE(LONG colIdx)
  CODE
  RETURN 0

tpsExec.Assign PROCEDURE(LONG colIdx)
  CODE
  RETURN

tpsExec.Range PROCEDURE(LONG colIdx, STRING why)
  CODE
  SELF.ErrCode = 'VALUE_OUT_OF_RANGE'; SELF.ErrMsg = why
  RETURN 3

tpsExec.Mutate PROCEDURE(BYTE isDelete)
  CODE
  RETURN 0

tpsExec.Undo PROCEDURE()
  CODE
  RETURN 'unknown'

tpsExec.RowIdText PROCEDURE()
  CODE
  RETURN ''

! ---- error output: prints the failure line, returns the exit code; never HALTs (the
! caller controls when the process actually ends, so nothing is printed twice) ----

tpsExec.ErrOut PROCEDURE(STRING op, STRING code, STRING msg, STRING outcome, LONG exitCode, <STRING errExtra>, <STRING topExtra>)
js  StringTheory
  CODE
  IF SELF.WantTable
    SELF.Out.Line(CLIP(code) & ': ' & CLIP(msg))
    RETURN exitCode
  END
  js.SetValue('{{ "ok": false, "op": ' & CHOOSE(CLIP(op) = '', 'null', SELF.Out.JStr(CLIP(op))) & ', "error": {{ "code": ' & SELF.Out.JStr(CLIP(code)) & ', "message": ' & SELF.Out.JStr(CLIP(msg)))
  IF NOT OMITTED(errExtra) AND CLIP(errExtra) <> '' THEN js.Append(', ' & errExtra).
  js.Append(' }, "outcome": ' & SELF.Out.JStr(CLIP(outcome)))
  IF NOT OMITTED(topExtra) AND CLIP(topExtra) <> '' THEN js.Append(', ' & topExtra).
  js.Append(', "complete": true }')
  SELF.Out.Line(js.GetValue())
  RETURN exitCode

! ---- module-local helpers ----

! Named FORMAT() to avoid the builtin: called from inside the tpsExec.Format METHOD, where an
! unqualified FORMAT(...) call resolves to that method itself (one flat label namespace), not
! the runtime builtin - "No matching prototype available" at compile time. Manual 2-digit
! zero-pad sidesteps the collision entirely.
TpsExecPad2 PROCEDURE(LONG n)
  CODE
  IF n < 10 THEN RETURN '0' & n.
  RETURN n

TpsExecIsNumericType PROCEDURE(STRING typ)
  CODE
  CASE UPPER(CLIP(typ))
  OF 'BYTE' OROF 'SHORT' OROF 'USHORT' OROF 'LONG' OROF 'ULONG' OROF 'SREAL' OROF 'REAL' OROF 'DECIMAL' OROF 'DATE' OROF 'TIME'
    RETURN 1
  END
  RETURN 0

! Strips one layer of JSON string quoting/escaping for the --table grid (Format/FormatMemo
! already built the JSON cell text; the grid wants the plain value). Ponytail: only \" and \\
! are unescaped (sufficient for every corpus value used in the --table test); a memo/blob
! value containing \n \t \u in --table output would need the full unescape this skips.
TpsExecUnjson PROCEDURE(STRING js)
s   StringTheory
n   LONG
  CODE
  n = LEN(CLIP(js))
  IF n < 2 OR js[1] <> '"' OR js[n] <> '"' THEN RETURN CLIP(js).
  s.SetValue(js[2 : n-1])
  s.Replace('\"', '"')
  s.Replace('\\', '\')
  RETURN s.GetValue()
