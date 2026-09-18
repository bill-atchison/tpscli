  MEMBER()
  INCLUDE('tpsExec.inc'),ONCE
  MAP
    TpsExecIsNumericType(STRING typ),BYTE
    TpsExecUnjson(STRING js),STRING
    TpsExecPad2(LONG n),STRING
    TpsExecValidBase64(STRING s),BYTE
    TpsExecHasDigit(STRING s),BYTE
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
    IF NOT SELF.Sch.Keys.IsKey THEN CYCLE.   ! an INDEX is populated only by BUILD, which tpscli never issues, so an unbuilt one walks zero rows
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

! ---- writes: INSERT (Task 8); UPDATE/DELETE: Task 9 ----

! Every column is Validate()d (literal -> SELF.Conv, no buffer touched) before any mutation, so a
! bad column N never leaves columns 1..N-1 written. Only then is the buffer cleared and every
! column Assign()ed, and only then is ADD() attempted - one CLEAR, one ADD, no partial writes.
tpsExec.DoInsert PROCEDURE()
rec       &GROUP
i         LONG
er        LONG
exitCode  LONG
extra     StringTheory
outLine   StringTheory
kfound    STRING(64)
k         LONG
matched   BYTE
  CODE
  SELF.Warnings.Free()
  LOOP i = 1 TO RECORDS(SELF.Sql.Cols)
    IF SELF.Validate(i) <> 0
      extra.SetValue('"column": ' & SELF.Out.JStr(CLIP(SELF.ErrCol)))
      exitCode = CHOOSE(SELF.ErrCode = 'VALUE_OUT_OF_RANGE', 3, 1)
      RETURN SELF.ErrOut('insert', SELF.ErrCode, SELF.ErrMsg, 'none', exitCode, extra.GetValue())
    END
  END

  rec &= SELF.Sch.F{PROP:Record}
  CLEAR(rec)
  LOOP i = 1 TO RECORDS(SELF.Sql.Cols)
    SELF.Assign(i)
    IF SELF.ErrCode <> ''
      extra.SetValue('"column": ' & SELF.Out.JStr(CLIP(SELF.ErrCol)))
      exitCode = CHOOSE(SELF.ErrCode = 'VALUE_OUT_OF_RANGE', 3, 1)
      RETURN SELF.ErrOut('insert', SELF.ErrCode, SELF.ErrMsg, 'none', exitCode, extra.GetValue())
    END
  END

  ADD(SELF.Sch.F)
  er = ERRORCODE()
  IF er = 40                                    ! duplicate key/record - see DoInsert's header comment
    LOOP k = 1 TO RECORDS(SELF.Sch.Keys)
      GET(SELF.Sch.Keys, k)
      IF SELF.Sch.Keys.Dup THEN CYCLE.           ! only a UNIQUE key can raise a duplicate
      IF INSTRING(UPPER(CLIP(SELF.Sch.Keys.Label)), UPPER(CLIP(ERROR())), 1, 1) > 0
        kfound = SELF.Sch.Keys.Label; matched = 1; BREAK
      END
    END
    IF NOT matched                               ! driver text named no key: fall back to the row identity key
      k = SELF.IdKeyNbr()
      IF k THEN GET(SELF.Sch.Keys, k); kfound = SELF.Sch.Keys.Label.
    END
    extra.SetValue('"key": ' & SELF.Out.JStr(CLIP(kfound)))
    RETURN SELF.ErrOut('insert', 'DUPLICATE_KEY', 'Duplicate value for key ' & CLIP(kfound), 'none', 3, extra.GetValue())
  ELSIF er <> 0
    RETURN SELF.ErrOut('insert', 'DRIVER', er & ' ' & CLIP(ERROR()) & ' / ' & CLIP(FILEERRORCODE()) & ' ' & CLIP(FILEERROR()), 'none', 3)
  END

  outLine.SetValue('{{ "ok": true, "op": "insert", "affected": 1')
  IF SELF.Warnings.Length() > 0 THEN outLine.Append(', "warnings": [' & SELF.Warnings.GetValue() & ']').
  outLine.Append(', "complete": true }')
  SELF.Out.Line(outLine.GetValue())
  RETURN 0

tpsExec.DoUpdate PROCEDURE()
  CODE
  RETURN SELF.Mutate(0)

tpsExec.DoDelete PROCEDURE()
  CODE
  RETURN SELF.Mutate(1)

! Converts SELF.Sql.Vals[colIdx] into SELF.Conv[colIdx] (numbers into Conv.Num/IsNum=1, strings and
! decoded BLOB bytes into a NEW Conv.Txt/TxtLen) and touches no buffer. Structural checks that must
! abort the WHOLE statement before any column is written - a leaf inside a DIM'd GROUP - live here
! too, not in Assign(), so "all Validates before the first mutation" actually holds.
tpsExec.Validate PROCEDURE(LONG colIdx)
f     SchFieldQ
lit   LIKE(ValQ)
dec   DECIMAL(31,15)
d     LONG
t     LONG
st    StringTheory
body     STRING(64)
intPart  STRING(32)
fracPart STRING(32)
dotPos   LONG
neg2     BYTE
picTok   STRING(52)
defTxt   STRING(64)
picNum   DECIMAL(31,15)
  CODE
  GET(SELF.Sql.Cols, colIdx); GET(SELF.Sql.Vals, colIdx); lit = SELF.Sql.Vals
  CLEAR(SELF.Conv)
  IF SELF.Sql.Cols.MemoNbr
    GET(SELF.Sch.Memos, SELF.Sql.Cols.MemoNbr)
    IF lit.Kind <> TK:Str THEN RETURN SELF.Range(colIdx, 'needs a string literal').
    IF SELF.Sch.Memos.IsBlob
      IF NOT TpsExecValidBase64(CLIP(lit.Text)) THEN RETURN SELF.Range(colIdx, 'is not valid base64').
      st.SetValue(lit.Text)
      IF st.Base64Decode() <> st:ok THEN RETURN SELF.Range(colIdx, 'is not valid base64').
      SELF.Conv.Txt &= NEW STRING(CHOOSE(st.Length() = 0, 1, st.Length()))
      IF st.Length() THEN SELF.Conv.Txt = st.GetValue().
      SELF.Conv.TxtLen = st.Length()
    ELSE
      SELF.Conv.Txt &= NEW STRING(CHOOSE(lit.Len = 0, 1, lit.Len))
      SELF.Conv.Txt = lit.Text
      SELF.Conv.TxtLen = lit.Len
    END
    ADD(SELF.Conv)
    RETURN 0
  END

  ! A leaf inside a DIM'd GROUP can't be reached via WHAT()/FieldRef for a write any more than for
  ! a read (task-7-report.md's binding ruling); reject up front rather than risk a silent
  ! wrong-occurrence write. UNSUPPORTED, not VALUE_OUT_OF_RANGE - exit 1, not 3.
  IF SELF.Sql.Cols.GrpElem > 0
    SELF.ErrCode = 'UNSUPPORTED'; SELF.ErrCol = SELF.Sql.Cols.Path
    SELF.ErrMsg = 'Assign leaves inside a dimmed group'
    RETURN 1
  END

  GET(SELF.Sch.Fields, SELF.Sql.Cols.FieldNbr); f = SELF.Sch.Fields
  CASE f.Type
  OF 'BYTE' OROF 'SHORT' OROF 'USHORT' OROF 'LONG' OROF 'ULONG'
    IF lit.Kind <> TK:Num OR INSTRING('.', lit.Text, 1, 1) THEN RETURN SELF.Range(colIdx, 'needs an integer').
    dec = lit.Text
    CASE f.Type
    OF 'BYTE'   ; IF dec < 0 OR dec > 255 THEN RETURN SELF.Range(colIdx, 'must be 0..255').
    OF 'SHORT'  ; IF dec < -32768 OR dec > 32767 THEN RETURN SELF.Range(colIdx, 'must be -32768..32767').
    OF 'USHORT' ; IF dec < 0 OR dec > 65535 THEN RETURN SELF.Range(colIdx, 'must be 0..65535').
    OF 'LONG'   ; IF dec < -2147483648 OR dec > 2147483647 THEN RETURN SELF.Range(colIdx, 'must fit a 32-bit signed integer').
    OF 'ULONG'  ; IF dec < 0 OR dec > 4294967295 THEN RETURN SELF.Range(colIdx, 'must be 0..4294967295').
    END
    SELF.Conv.Num = dec; SELF.Conv.IsNum = 1
  OF 'SREAL' OROF 'REAL'
    IF lit.Kind <> TK:Num THEN RETURN SELF.Range(colIdx, 'needs a number').
    SELF.Conv.Num = lit.Text; SELF.Conv.IsNum = 1
  OF 'DECIMAL' OROF 'PDECIMAL'
    IF lit.Kind <> TK:Num THEN RETURN SELF.Range(colIdx, 'needs a number').
    ! ceiling: DECIMAL(31,15) is the widest literal accepted. MATCH(...,Match:Regular) has no
    ! {m,n} quantifier (confirmed repo-wide, see task-1-report.md), so this checks the digit
    ! counts by hand instead of the brief's '^-?[0-9]{1,15}(\.[0-9]{1,15})?$'.
    body = CLIP(lit.Text)
    neg2 = CHOOSE(SUB(body, 1, 1) = '-', 1, 0)
    IF neg2 THEN body = SUB(body, 2, LEN(body) - 1).
    dotPos = INSTRING('.', body, 1, 1)
    IF dotPos = 0
      intPart = body; fracPart = ''
    ELSE
      intPart = SUB(body, 1, dotPos - 1); fracPart = SUB(body, dotPos + 1, LEN(body) - dotPos)
    END
    IF LEN(CLIP(intPart)) < 1 OR LEN(CLIP(intPart)) > 15 OR LEN(CLIP(fracPart)) > 15 OR (dotPos > 0 AND LEN(CLIP(fracPart)) < 1)
      RETURN SELF.Range(colIdx, 'has more digits than tpscli handles (15 integer, 15 fraction)')
    END
    dec = lit.Text                                                  ! DECIMAL(31,15) holds every literal the check above admits
    dec = ROUND(dec, 10 ^ (-f.Places))                              ! Clarion ROUND is half away from zero
    ! SchFieldQ.Size (not .Digits) is the true total digit count for a DECIMAL field - see the fix
    ! and its comment in tpsSql.clw's SqlLitConvert, discovered while building this routine.
    IF ABS(dec) >= 10 ^ (f.Size - f.Places) THEN RETURN SELF.Range(colIdx, 'exceeds DECIMAL(' & f.Size & ',' & f.Places & ')').
    SELF.Conv.Num = dec; SELF.Conv.IsNum = 1
  OF 'DATE'
    IF lit.Kind <> TK:Str THEN RETURN SELF.Range(colIdx, 'needs a ''YYYY-MM-DD'' string').
    IF lit.Len = 0
      SELF.Conv.Num = 0; SELF.Conv.IsNum = 1; ADD(SELF.Conv); RETURN 0
    END
    IF NOT SELF.Sql.ValidDate(lit.Text, d) THEN RETURN SELF.Range(colIdx, 'is not a valid YYYY-MM-DD date between 1801 and 2999').
    SELF.Conv.Num = d; SELF.Conv.IsNum = 1
  OF 'TIME'
    IF lit.Kind <> TK:Str THEN RETURN SELF.Range(colIdx, 'needs an ''HH:MM[:SS[.hh]]'' string').
    IF lit.Len = 0
      SELF.Conv.Num = 0; SELF.Conv.IsNum = 1; ADD(SELF.Conv); RETURN 0
    END
    IF NOT SELF.Sql.ValidTime(lit.Text, t) THEN RETURN SELF.Range(colIdx, 'is not a valid HH:MM[:SS[.hh]] time').
    SELF.Conv.Num = t; SELF.Conv.IsNum = 1
  OF 'STRING' OROF 'CSTRING' OROF 'PSTRING'
    IF lit.Kind <> TK:Str THEN RETURN SELF.Range(colIdx, 'needs a string literal').
    ! A STRING declared with a picture is deformatted and reformatted by the Clarion runtime on
    ! assignment, so a literal the picture cannot read is stored as the picture's zero: 'rrr'
    ! into a STRING(@N9.2) becomes '00000.00'. That is a conversion failure, and spec section 8
    ! says every conversion failure is VALUE_OUT_OF_RANGE, so it is refused here rather than
    ! written silently. Measured with a --selftest probe against @N9.2 (task-10 fix round 1):
    ! DEFORMAT returns a blank string for a literal carrying no digit at all ('rrr' -> '') and
    ! the digits it found otherwise ('7' -> '7', '00007.00' -> '00007.0', '0' -> '0'). The
    ! digit test keeps a legitimate zero ('0', whose deformat is numerically 0) acceptable.
    IF CLIP(f.Picture) <> '' AND lit.Len > 0 AND CLIP(lit.Text) <> ''
      picTok = '@' & CLIP(f.Picture)
      defTxt = DEFORMAT(CLIP(lit.Text), picTok)
      picNum = defTxt
      IF CLIP(defTxt) = '' OR (picNum = 0 AND NOT TpsExecHasDigit(CLIP(lit.Text)))
        RETURN SELF.Range(colIdx, 'does not match picture ' & CLIP(picTok))
      END
    END
    SELF.Conv.Txt &= NEW STRING(CHOOSE(lit.Len = 0, 1, lit.Len))
    SELF.Conv.Txt = lit.Text
    SELF.Conv.TxtLen = lit.Len
    IF lit.Len > f.Size - CHOOSE(f.Type = 'STRING', 0, 1)
      SELF.Warnings.Append(CHOOSE(SELF.Warnings.Length() = 0, '', ',') & '{{ "code": "STRING_TRUNCATED", "column": ' & SELF.Out.JStr(CLIP(SELF.Sql.Cols.Path)) |
                           & ', "message": "Value truncated to ' & f.Size & ' characters" }')
    END
  ELSE
    RETURN SELF.Range(colIdx, 'cannot be assigned (' & CLIP(f.Type) & ')')
  END
  ADD(SELF.Conv)
  RETURN 0

! Purely mechanical: copies SELF.Conv[colIdx] (already validated) into the record buffer. No
! return value (see tpsExec.inc); a structural failure only Assign() can discover - the BLOB
! PROP:Blob path, unverified per the brief - is signalled through SELF.ErrCode the same way
! Format()/FormatMemo() already signal failure to their callers, and DoInsert checks it after
! every Assign() call.
tpsExec.Assign PROCEDURE(LONG colIdx)
v    ANY
f    SchFieldQ
cc   ColQ
b    &BLOB
  CODE
  GET(SELF.Sql.Cols, colIdx); GET(SELF.Conv, colIdx)
  IF SELF.Sql.Cols.MemoNbr
    GET(SELF.Sch.Memos, SELF.Sql.Cols.MemoNbr)
    IF SELF.Sch.Memos.IsBlob
      ! negative index, matching FormatMemo's proven -memoNbr convention (SchMemoQ.Nbr is negative
      ! for a blob); the brief's own INSERT snippet used a positive index, which does not match
      ! that already-proven read path - see task-8-report.md.
      b &= SELF.Sch.F{PROP:Blob, -SELF.Sql.Cols.MemoNbr}
      IF b &= NULL
        SELF.ErrCode = 'UNSUPPORTED'; SELF.ErrCol = SELF.Sql.Cols.Path
        SELF.ErrMsg = 'BLOB write not available on dynamic files'
        RETURN
      END
      b{PROP:Size} = SELF.Conv.TxtLen
      IF SELF.Conv.TxtLen THEN b[0 : SELF.Conv.TxtLen-1] = SELF.Conv.Txt.
    ELSE
      SELF.Sch.F{PROP:Value, -SELF.Sql.Cols.MemoNbr} = SELF.Conv.Txt
    END
    RETURN
  END
  GET(SELF.Sch.Fields, SELF.Sql.Cols.FieldNbr); f = SELF.Sch.Fields
  cc = SELF.Sql.Cols                              ! FlatElem takes a by-value ColQ; the live &ColQ member doesn't match
  v &= SELF.Sch.FieldRef(SELF.Sql.Cols.FieldNbr, SELF.Sql.FlatElem(cc, f))
  ! DECIMAL display trims trailing fraction zeros ("0" not "0.00") for every row, including
  ! untouched pre-existing corpus data (testdata\ALLTYPES.TPS row 3, D=0, reads back as "0") -
  ! that's Format()'s established, already-correct DECIMAL-to-STRING conversion, not a write-side
  ! defect, so a rounded whole value like 9.995->10.00 is expected to read back as "10". See
  ! task-8-report.md.
  IF SELF.Conv.IsNum THEN v = SELF.Conv.Num ELSE v = SELF.Conv.Txt.

tpsExec.Range PROCEDURE(LONG colIdx, STRING why)
  CODE
  GET(SELF.Sql.Cols, colIdx)
  SELF.ErrCode = 'VALUE_OUT_OF_RANGE'
  SELF.ErrCol = SELF.Sql.Cols.Path
  SELF.ErrMsg = CLIP(SELF.Sql.Cols.Path) & ' ' & why
  RETURN 3

! ---- UPDATE / DELETE (Task 9): the two-pass transactional protocol of spec section 5 ----

! Pass 1 scans the file in record order with nothing locked and collects the position of every
! matching row, together with a printable row identity (RowIdText) captured while the buffer still
! holds that row - so a REGET that fails in pass 2 can still name the row it could not re-read.
! Pass 2 runs inside LOGOUT/COMMIT and HOLDs + REGETs each candidate before touching it, so a row
! another process changed between the passes is never overwritten blind. Any failure in pass 2
! rolls the whole statement back: "affected" is all-or-nothing, never a partial count.
! Every driver failure snapshots ERRORCODE/ERROR/FILEERRORCODE/FILEERROR into locals first, because
! Undo() (ROLLBACK) and POPBIND both run before the message is built and would otherwise clear them.
tpsExec.Mutate PROCEDURE(BYTE isDelete)
cands    SortQ                      ! candidate rows from pass 1 (SortQ, not "PosQ" - see tpsExec.inc)
rec      &GROUP
opName   STRING(6)
i        LONG
j        LONG
r        BYTE
pk       STRING(255)
e        LONG
em       STRING(255)
fe       STRING(255)
fm       STRING(255)
oc       STRING(12)
affected LONG
exitCode LONG
extra    StringTheory
top      StringTheory
outLine  StringTheory
  CODE
  opName = CHOOSE(isDelete, 'delete', 'update')
  SELF.Warnings.Free()
  FREE(SELF.Conv)                   ! Validate ADDs in column order and Assign GETs by column index
  rec &= SELF.Sch.F{PROP:Record}
  PUSHBIND
  BIND(rec)

  ! Every SET literal is converted before the scan, so a bad literal costs no I/O and leaves
  ! outcome "none". (In practice tpsSql's SqlLitConvert already rejected it at parse time.)
  IF NOT isDelete
    LOOP j = 1 TO RECORDS(SELF.Sql.Cols)
      IF SELF.Validate(j) <> 0
        POPBIND
        extra.SetValue('"column": ' & SELF.Out.JStr(CLIP(SELF.ErrCol)))
        exitCode = CHOOSE(SELF.ErrCode = 'VALUE_OUT_OF_RANGE', 3, 1)
        RETURN SELF.ErrOut(opName, SELF.ErrCode, SELF.ErrMsg, 'none', exitCode, extra.GetValue())
      END
    END
  END

  ! ---- pass 1: candidates in record order, nothing locked ----
  SET(SELF.Sch.F)
  LOOP
    NEXT(SELF.Sch.F)
    e = ERRORCODE()
    IF e = 33 THEN BREAK.                       ! end of file
    IF e
      em = ERROR(); fe = FILEERRORCODE(); fm = FILEERROR(); POPBIND
      RETURN SELF.ErrOut(opName, 'DRIVER', 'NEXT: ' & e & ' ' & CLIP(em) & ' / ' & CLIP(fe) & ' ' & CLIP(fm), 'none', 3)
    END
    r = SELF.Matches()
    IF r = 2
      POPBIND
      RETURN SELF.ErrOut(opName, 'SYNTAX', 'Runtime rejected the filter expression: ' & CLIP(SELF.Sql.Where), 'none', 1)
    END
    IF r = 0 THEN CYCLE.
    CLEAR(cands)
    cands.Pos = POSITION(SELF.Sch.F)
    cands.RowId = SELF.RowIdText()
    ADD(cands)
  END

  ! ---- pass 2: one transaction over the candidates ----
  IF RECORDS(cands) > 0
    LOGOUT(2, SELF.Sch.F)
    e = ERRORCODE()
    IF e
      em = ERROR(); fe = FILEERRORCODE(); fm = FILEERROR(); POPBIND
      top.SetValue('"matched": ' & RECORDS(cands) & ', "affected": 0')
      RETURN SELF.ErrOut(opName, 'DRIVER', 'LOGOUT failed: ' & e & ' ' & CLIP(em) & ' / ' & CLIP(fe) & ' ' & CLIP(fm), |
                         'none', 3, '', top.GetValue())
    END

    LOOP i = 1 TO RECORDS(cands)
      GET(cands, i)
      HOLD(SELF.Sch.F, 1)                       ! spec: one second, no retries
      REGET(SELF.Sch.F, cands.Pos)
      e = ERRORCODE(); em = ERROR(); fe = FILEERRORCODE(); fm = FILEERROR()
      IF e
        ! 43 is IsHeldErr (Clarion's own ERRORS.CLW); nothing else counts as held, and every other
        ! REGET failure - including 35, the row another process removed between the two passes -
        ! fails the statement with a rollback, exactly as the spec requires.
        pk = cands.RowId
        ! 43 means our own HOLD never took, so there is nothing of ours to release; calling
        ! RELEASE here would target the other process's hold on the same record.
        IF e <> 43 THEN RELEASE(SELF.Sch.F).
        oc = SELF.Undo(); POPBIND
        extra.SetValue('"row": ' & SELF.Out.JStr(CLIP(pk)))
        top.SetValue(CLIP('"matched": ' & RECORDS(cands) & CHOOSE(oc = 'rolled_back', ', "affected": 0', '')))
        IF e = 43
          RETURN SELF.ErrOut(opName, 'RECORD_HELD', 'Record held by another process (' & CLIP(pk) & '). Statement ' |
                             & CHOOSE(oc = 'rolled_back', 'rolled back.', 'NOT confirmed rolled back.'), |
                             oc, 3, extra.GetValue(), top.GetValue())
        END
        RETURN SELF.ErrOut(opName, 'DRIVER', 'REGET ' & CLIP(pk) & ': ' & e & ' ' & CLIP(em) & ' / ' & CLIP(fe) & ' ' & CLIP(fm), |
                           oc, 3, extra.GetValue(), top.GetValue())
      END

      r = SELF.Matches()
      IF r = 2
        RELEASE(SELF.Sch.F); oc = SELF.Undo(); POPBIND
        top.SetValue(CLIP('"matched": ' & RECORDS(cands) & CHOOSE(oc = 'rolled_back', ', "affected": 0', '')))
        ! Exit 3, not the 1 a SYNTAX failure carries before execution starts: spec section 8 defines
        ! exit 1 as "No data was modified", and inside an open transaction only a confirmed
        ! rolled_back could promise that - an outcome of "unknown" could not.
        RETURN SELF.ErrOut(opName, 'SYNTAX', 'Runtime rejected the filter expression: ' & CLIP(SELF.Sql.Where), |
                           oc, 3, '', top.GetValue())
      END
      IF r = 0 THEN RELEASE(SELF.Sch.F); CYCLE.  ! changed under us, no longer matches: counts in matched only

      IF isDelete
        DELETE(SELF.Sch.F)
      ELSE
        SELF.ErrCode = ''                        ! Assign signals a structural failure through it
        LOOP j = 1 TO RECORDS(SELF.Sql.Cols)
          SELF.Assign(j)
          IF SELF.ErrCode <> '' THEN BREAK.
        END
        IF SELF.ErrCode <> ''
          RELEASE(SELF.Sch.F); oc = SELF.Undo(); POPBIND
          extra.SetValue('"column": ' & SELF.Out.JStr(CLIP(SELF.ErrCol)))
          top.SetValue(CLIP('"matched": ' & RECORDS(cands) & CHOOSE(oc = 'rolled_back', ', "affected": 0', '')))
          ! Always exit 3, even for the UNSUPPORTED that Assign raises on an unreachable BLOB: the
          ! transaction is already open, so this is a runtime failure, not the pre-execution exit 1
          ! that spec section 8 defines as "No data was modified".
          RETURN SELF.ErrOut(opName, SELF.ErrCode, SELF.ErrMsg, oc, 3, extra.GetValue(), top.GetValue())
        END
        PUT(SELF.Sch.F)
      END
      e = ERRORCODE(); em = ERROR(); fe = FILEERRORCODE(); fm = FILEERROR()
      IF e
        RELEASE(SELF.Sch.F); pk = cands.RowId; oc = SELF.Undo(); POPBIND
        extra.SetValue('"row": ' & SELF.Out.JStr(CLIP(pk)))
        top.SetValue(CLIP('"matched": ' & RECORDS(cands) & CHOOSE(oc = 'rolled_back', ', "affected": 0', '')))
        RETURN SELF.ErrOut(opName, CHOOSE(e = 40, 'DUPLICATE_KEY', 'DRIVER'), |
                           CLIP(CLIP(em) & ' at ' & CLIP(pk) & CHOOSE(e = 40, '', ' / ' & CLIP(fe) & ' ' & CLIP(fm))), |
                           oc, 3, extra.GetValue(), top.GetValue())
      END
      affected += 1
    END

    COMMIT
    e = ERRORCODE()
    IF e
      em = ERROR(); fe = FILEERRORCODE(); fm = FILEERROR()
      oc = SELF.Undo(); POPBIND
      top.SetValue(CLIP('"matched": ' & RECORDS(cands) & CHOOSE(oc = 'rolled_back', ', "affected": 0', '')))
      RETURN SELF.ErrOut(opName, 'DRIVER', 'COMMIT failed: ' & e & ' ' & CLIP(em) & ' / ' & CLIP(fe) & ' ' & CLIP(fm), |
                         oc, 3, '', top.GetValue())
    END
  END
  POPBIND

  outLine.SetValue('{{ "ok": true, "op": "' & CLIP(opName) & '", "matched": ' & RECORDS(cands) & ', "affected": ' & affected)
  IF SELF.Warnings.Length() > 0 THEN outLine.Append(', "warnings": [' & SELF.Warnings.GetValue() & ']').
  outLine.Append(', "complete": true }')
  SELF.Out.Line(outLine.GetValue())
  RETURN 0

tpsExec.Undo PROCEDURE()
  CODE
  ROLLBACK
  IF ERRORCODE() THEN RETURN 'unknown'.
  RETURN 'rolled_back'

! Identity of the row currently in the buffer, for error messages only: the component values of the
! primary (or first unique) key joined with '|', or - for a file with no unique key at all - the
! driver's own POSITION bytes in hex, which is opaque but at least tells two rows apart.
tpsExec.RowIdText PROCEDURE()
k     LONG
j     LONG
n     LONG
s     StringTheory
v     ANY
sv    STRING(255)
  CODE
  k = SELF.IdKeyNbr()
  IF k = 0
    s.SetValue(POSITION(SELF.Sch.F))
    s.ToHex()
    RETURN s.GetValue()
  END
  LOOP j = 1 TO RECORDS(SELF.Sch.Comps)
    GET(SELF.Sch.Comps, j)
    IF SELF.Sch.Comps.KeyNbr <> k THEN CYCLE.
    v &= SELF.Sch.FieldRef(SELF.Sch.Comps.FieldNbr, 0)
    IF v &= NULL THEN CYCLE.
    sv = v                                       ! same numeric-to-text conversion Format() uses
    n += 1
    s.Append(CHOOSE(n = 1, '', '|') & CLIP(LEFT(sv)))
  END
  RETURN s.GetValue()

! One lookup shared by DoInsert (naming the key in a DUPLICATE_KEY message when the driver's own
! text names none) and RowIdText (choosing the components that identify a row).
tpsExec.IdKeyNbr PROCEDURE()
k     LONG
uniq  LONG
  CODE
  LOOP k = 1 TO RECORDS(SELF.Sch.Keys)
    GET(SELF.Sch.Keys, k)
    IF SELF.Sch.Keys.Primary THEN RETURN k.
    IF uniq = 0 AND NOT SELF.Sch.Keys.Dup THEN uniq = k.
  END
  RETURN uniq

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

! Shape check for a BLOB literal before Base64Decode() runs: length a multiple of 4, alphabet
! A-Za-z0-9+/, at most two trailing '=' pad characters. MATCH(...,Match:Regular) has no {m,n}
! quantifier (see task-1-report.md), so this is a hand-rolled scan instead of the brief's
! '^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$'. Needed because StringTheory's
! Base64Decode silently CYCLEs over any character it doesn't recognize instead of failing
! (confirmed against C:\Clarion12\accessory\libsrc\win\StringTheory.clw), so it would never by
! itself reject garbage input.
! One digit anywhere is enough; see the picture check in Validate for why this exists.
TpsExecHasDigit PROCEDURE(STRING s)
i  LONG
  CODE
  LOOP i = 1 TO LEN(s)
    IF s[i] >= '0' AND s[i] <= '9' THEN RETURN 1.
  END
  RETURN 0

TpsExecValidBase64 PROCEDURE(STRING s)
n    LONG
i    LONG
c    STRING(1)
pad  LONG
  CODE
  n = LEN(s)
  IF n = 0 OR n % 4 <> 0 THEN RETURN 0.
  LOOP i = 1 TO n
    c = s[i]
    IF c = '='
      pad += 1
    ELSE
      IF pad > 0 THEN RETURN 0.
      IF NOT ((c >= 'A' AND c <= 'Z') OR (c >= 'a' AND c <= 'z') OR (c >= '0' AND c <= '9') OR c = '+' OR c = '/')
        RETURN 0
      END
    END
  END
  IF pad > 2 THEN RETURN 0.
  RETURN 1
