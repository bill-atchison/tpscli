  MEMBER()
  INCLUDE('tpsSql.inc'),ONCE
  MAP
    SqlAllDigits(STRING s),BYTE
    SqlEscapeStr(STRING s),STRING
    SqlUnsupportedWord(STRING w, STRING nextTok, BYTE atColumnPos),STRING
    SqlLitConvert(tpsSql s, LONG fieldNbr, LONG memoNbr, BYTE kind, STRING rawText, BYTE neg, StringTheory outp),LONG
    SqlCurPos(tpsSql s),LONG
    SqlPeekNext(tpsSql s),STRING
    SqlRequireLeaf(tpsSql s, ColQ c),LONG
    SqlCaptureValue(tpsSql s, LONG fieldNbr, LONG memoNbr),LONG
    SqlTokAdd(tpsSql s, BYTE kind, STRING txt, LONG pos)
    SqlTokFree(tpsSql s)
  END

! ---- construction ----

tpsSql.Construct PROCEDURE()
  CODE
  SELF.Toks  &= NEW TokQ
  SELF.Cols  &= NEW ColQ
  SELF.Vals  &= NEW ValQ
  SELF.Order &= NEW OrdQ

tpsSql.Destruct PROCEDURE()
i  LONG
  CODE
  LOOP i = 1 TO RECORDS(SELF.Vals)
    GET(SELF.Vals, i)
    IF NOT SELF.Vals.Text &= NULL THEN DISPOSE(SELF.Vals.Text).
  END
  SqlTokFree(SELF)
  DISPOSE(SELF.Toks); DISPOSE(SELF.Cols); DISPOSE(SELF.Vals); DISPOSE(SELF.Order)

tpsSql.Fail PROCEDURE(STRING code, STRING msg)
  CODE
  SELF.Err = code; SELF.ErrMsg = msg
  RETURN 1

! ---- tokenizer ----

tpsSql.Tokenize PROCEDURE(STRING sql)
n      LONG
i      LONG
start  LONG
c      BYTE
c2     BYTE
closeAt LONG
lastWasPathKw BYTE
str     StringTheory
  CODE
  SqlTokFree(SELF)
  n = LEN(sql)
  i = 1
  LOOP WHILE i <= n
    c = VAL(sql[i])
    IF c = 32 OR c = 9 OR c = 13 OR c = 10   ! space, tab, CR, LF
      i += 1; CYCLE
    END
    start = i
    IF (c >= 65 AND c <= 90) OR (c >= 97 AND c <= 122) OR c = 95   ! letter or underscore
      LOOP WHILE i <= n
        c = VAL(sql[i])
        IF NOT ((c >= 65 AND c <= 90) OR (c >= 97 AND c <= 122) OR (c >= 48 AND c <= 57) OR c = 95) THEN BREAK.
        i += 1
      END
      SqlTokAdd(SELF, TK:Ident, UPPER(sql[start : i-1]), start)
      CYCLE
    END
    IF c >= 48 AND c <= 57                    ! digit: [0-9]+(\.[0-9]+)?
      LOOP WHILE i <= n AND VAL(sql[i]) >= 48 AND VAL(sql[i]) <= 57; i += 1; END
      IF i <= n AND VAL(sql[i]) = 46 AND i+1 <= n AND VAL(sql[i+1]) >= 48 AND VAL(sql[i+1]) <= 57
        i += 1
        LOOP WHILE i <= n AND VAL(sql[i]) >= 48 AND VAL(sql[i]) <= 57; i += 1; END
      END
      SqlTokAdd(SELF, TK:Num, sql[start : i-1], start)
      CYCLE
    END
    IF c = 39                                  ! ' - string literal, doubled '' escapes
      i += 1
      str.Free()
      LOOP
        IF i > n
          SELF.ErrPos = start; SELF.ErrToken = ''''
          RETURN SELF.Fail('SYNTAX', 'Unterminated string literal')
        END
        c = VAL(sql[i])
        IF c = 39
          IF i+1 <= n AND VAL(sql[i+1]) = 39
            str.Append(''''); i += 2; CYCLE
          END
          i += 1; BREAK
        END
        str.Append(sql[i]); i += 1
      END
      SqlTokAdd(SELF, TK:Str, str.GetValue(), start)
      CYCLE
    END
    IF c = 91                                  ! [ - bracket path or plain op
      lastWasPathKw = 0
      IF RECORDS(SELF.Toks) > 0
        GET(SELF.Toks, RECORDS(SELF.Toks))
        IF SELF.Toks.Kind = TK:Ident AND (SELF.Toks.Text = 'DESCRIBE' OR SELF.Toks.Text = 'FROM' OR SELF.Toks.Text = 'INTO' OR SELF.Toks.Text = 'UPDATE')
          lastWasPathKw = 1
        END
      END
      IF lastWasPathKw
        closeAt = INSTRING(']', sql, 1, i+1)
        IF closeAt = 0
          SELF.ErrPos = start; SELF.ErrToken = '['
          RETURN SELF.Fail('SYNTAX', 'Unterminated bracket path')
        END
        SqlTokAdd(SELF, TK:Path, sql[i+1 : closeAt-1], start)
        i = closeAt + 1
        CYCLE
      END
      SqlTokAdd(SELF, TK:Op, '[', start)
      i += 1
      CYCLE
    END
    IF c = 59                                  ! ; - trailing only
      IF LEN(CLIP(sql[i+1 : n])) > 0
        SELF.ErrPos = start; SELF.ErrToken = ';'
        RETURN SELF.Fail('SYNTAX', 'Only one statement per invocation')
      END
      i += 1; CYCLE
    END
    ! two-char ops
    c2 = CHOOSE(i+1 <= n, VAL(sql[i+1]), 0)
    IF (c = 60 AND c2 = 62) OR (c = 33 AND c2 = 61) OR (c = 60 AND c2 = 61) OR (c = 62 AND c2 = 61)   ! <> != <= >=
      SqlTokAdd(SELF, TK:Op, sql[i : i+1], start)
      i += 2; CYCLE
    END
    IF c = 61 OR c = 60 OR c = 62 OR c = 40 OR c = 41 OR c = 44 OR c = 46 OR c = 93 OR c = 42
      SqlTokAdd(SELF, TK:Op, sql[i], start)
      i += 1; CYCLE
    END
    IF c = 43 OR c = 45 OR c = 47               ! + - /  (unary '-' handled by callers; these are always their own op)
      SqlTokAdd(SELF, TK:Op, sql[i], start)
      i += 1; CYCLE
    END
    SELF.ErrPos = start; SELF.ErrToken = sql[i]
    RETURN SELF.Fail('SYNTAX', 'Unexpected character ' & sql[i] & ' at position ' & start)
  END
  SqlTokAdd(SELF, TK:Eof, '', n+1)
  RETURN 0

! ---- token stream helpers ----

tpsSql.Peek PROCEDURE()
  CODE
  IF SELF.Cur > RECORDS(SELF.Toks) THEN RETURN ''.
  GET(SELF.Toks, SELF.Cur)
  IF SELF.Toks.Len = 0 THEN RETURN ''.
  RETURN SELF.Toks.Text[1 : SELF.Toks.Len]

tpsSql.PeekKind PROCEDURE()
  CODE
  IF SELF.Cur > RECORDS(SELF.Toks) THEN RETURN TK:Eof.
  GET(SELF.Toks, SELF.Cur)
  RETURN SELF.Toks.Kind

! Returns the token's exact bytes - no CLIP. A string literal's trailing spaces are data for a
! MEMO or BLOB column, and SqlTokAdd already stores every token at its true length, so there is
! no padding here to strip (spec section 5: a literal is written as given, or refused).
tpsSql.Take PROCEDURE()
  CODE
  IF SELF.Cur > RECORDS(SELF.Toks) THEN RETURN ''.
  GET(SELF.Toks, SELF.Cur)
  SELF.Cur += 1
  IF SELF.Toks.Len = 0 THEN RETURN ''.
  RETURN SELF.Toks.Text[1 : SELF.Toks.Len]

tpsSql.Expect PROCEDURE(STRING word)
pos  LONG
tok  STRING(64)
  CODE
  pos = CHOOSE(SELF.Cur <= RECORDS(SELF.Toks), 0, 0)
  IF UPPER(SELF.Peek()) = UPPER(word)
    SELF.Take()
    RETURN 0
  END
  tok = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
  IF SELF.Cur <= RECORDS(SELF.Toks)
    GET(SELF.Toks, SELF.Cur); pos = SELF.Toks.Pos
  ELSE
    GET(SELF.Toks, RECORDS(SELF.Toks)); pos = SELF.Toks.Pos
  END
  SELF.ErrPos = pos; SELF.ErrToken = tok
  RETURN SELF.Fail('SYNTAX', 'Expected ' & word & ' but found ' & tok)

! ---- statement head: op + path ----

tpsSql.ParsePath PROCEDURE()
k    BYTE
tok  STRING(1024)
pos  LONG
  CODE
  IF SELF.Cur <= RECORDS(SELF.Toks)
    GET(SELF.Toks, SELF.Cur); pos = SELF.Toks.Pos
  ELSE
    GET(SELF.Toks, RECORDS(SELF.Toks)); pos = SELF.Toks.Pos
  END
  k = SELF.PeekKind()
  tok = CHOOSE(k = TK:Eof, '<eof>', SELF.Peek())
  IF k <> TK:Path AND k <> TK:Ident
    SELF.ErrPos = pos; SELF.ErrToken = tok
    RETURN SELF.Fail('SYNTAX', 'Table path must be in square brackets')
  END
  SELF.Path = SELF.Take()
  RETURN 0

tpsSql.Parse PROCEDURE(STRING sql)
head  STRING(16)
pos   LONG
tok   STRING(64)
found BYTE
  CODE
  SELF.Err = ''; SELF.ErrMsg = ''; SELF.ErrPos = 0; SELF.ErrToken = ''; SELF.ErrColumn = ''
  IF SELF.Tokenize(sql) <> 0 THEN RETURN 1.
  SELF.Cur = 1
  IF SELF.PeekKind() <> TK:Ident
    GET(SELF.Toks, SELF.Cur); SELF.ErrPos = SELF.Toks.Pos
    SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
    RETURN SELF.Fail('SYNTAX', 'Expected DESCRIBE, SELECT, INSERT, UPDATE, or DELETE')
  END
  head = SELF.Take()
  CASE head
  OF 'DESCRIBE' ; SELF.Op = OP:Describe
  OF 'SELECT'   ; SELF.Op = OP:Select
  OF 'INSERT'   ; SELF.Op = OP:Insert
  OF 'UPDATE'   ; SELF.Op = OP:Update
  OF 'DELETE'   ; SELF.Op = OP:Delete
  ELSE
    SELF.ErrPos = 1; SELF.ErrToken = head
    RETURN SELF.Fail('SYNTAX', 'Expected DESCRIBE, SELECT, INSERT, UPDATE, or DELETE')
  END
  CASE SELF.Op
  OF OP:Describe
    IF SELF.ParsePath() <> 0 THEN RETURN 1.
  OF OP:Update
    IF SELF.ParsePath() <> 0 THEN RETURN 1.
  OF OP:Insert
    IF SELF.Expect('INTO') <> 0 THEN RETURN 1.
    IF SELF.ParsePath() <> 0 THEN RETURN 1.
  OF OP:Delete
    IF SELF.Expect('FROM') <> 0 THEN RETURN 1.
    IF SELF.ParsePath() <> 0 THEN RETURN 1.
  OF OP:Select
    found = 0
    LOOP WHILE SELF.Cur <= RECORDS(SELF.Toks)
      GET(SELF.Toks, SELF.Cur)
      IF SELF.Toks.Kind = TK:Ident AND SELF.Toks.Text = 'FROM'
        found = 1; SELF.Cur += 1; BREAK
      END
      SELF.Cur += 1
    END
    IF NOT found
      GET(SELF.Toks, RECORDS(SELF.Toks)); SELF.ErrPos = SELF.Toks.Pos; SELF.ErrToken = '<eof>'
      RETURN SELF.Fail('SYNTAX', 'Expected FROM')
    END
    IF SELF.ParsePath() <> 0 THEN RETURN 1.
  END
  RETURN 0

! ---- column resolution ----

tpsSql.ColumnRef PROCEDURE(*ColQ c)
parts   QUEUE
Label     STRING(64)
Pos       LONG
Sub1      LONG
HasSub1   BYTE
Sub2      LONG
HasSub2   BYTE
          END
n       LONG
i       LONG
pos     LONG
fieldNbr LONG
memoNbr LONG
curNbr  LONG
lbl     STRING(64)
typ     STRING(12)
elems   LONG
dim2    LONG
parentNbr LONG
pathTxt StringTheory
names   StringTheory
cnt     LONG
leafLbl STRING(64)
leafF   SchFieldQ
sv      LONG
  CODE
  CLEAR(c)
  LOOP
    IF SELF.PeekKind() <> TK:Ident
      GET(SELF.Toks, SELF.Cur); pos = SELF.Toks.Pos
      SELF.ErrPos = pos; SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
      RETURN SELF.Fail('SYNTAX', 'Expected a column name')
    END
    CLEAR(parts)
    parts.Pos = SqlCurPos(SELF)
    parts.Label = SELF.Take()
    IF SELF.Peek() = '['
      SELF.Take()
      IF SELF.PeekKind() <> TK:Num
        SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
        RETURN SELF.Fail('SYNTAX', 'Expected a subscript number')
      END
      parts.Sub1 = SELF.Take(); parts.HasSub1 = 1
      IF SELF.Expect(']') <> 0 THEN RETURN 1.
      IF SELF.Peek() = '['
        SELF.Take()
        IF SELF.PeekKind() <> TK:Num
          SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
          RETURN SELF.Fail('SYNTAX', 'Expected a subscript number')
        END
        parts.Sub2 = SELF.Take(); parts.HasSub2 = 1
        IF SELF.Expect(']') <> 0 THEN RETURN 1.
      END
    END
    ADD(parts)
    IF SELF.Peek() = '.'
      SELF.Take(); CYCLE
    END
    BREAK
  END
  n = RECORDS(parts)
  GET(parts, n)
  leafLbl = parts.Label
  fieldNbr = SELF.Sch.FindField(leafLbl)
  IF fieldNbr = 0
    memoNbr = 0
    LOOP i = 1 TO RECORDS(SELF.Sch.Memos)
      GET(SELF.Sch.Memos, i)
      IF UPPER(CLIP(SELF.Sch.Memos.Label)) = UPPER(CLIP(leafLbl)) THEN memoNbr = i; BREAK.
    END
    IF memoNbr = 0
      names.SetValue('')
      cnt = 0
      LOOP i = 1 TO RECORDS(SELF.Sch.Fields)
        GET(SELF.Sch.Fields, i)
        IF cnt >= 40
          names.Append(', ...'); BREAK
        END
        names.Append(CHOOSE(cnt = 0, '', ', ') & CLIP(SELF.Sch.Fields.Label))
        cnt += 1
      END
      LOOP i = 1 TO RECORDS(SELF.Sch.Memos)
        IF cnt >= 40
          names.Append(', ...'); BREAK
        END
        GET(SELF.Sch.Memos, i)
        names.Append(', ' & CLIP(SELF.Sch.Memos.Label))
        cnt += 1
      END
      SELF.ErrColumn = leafLbl; SELF.ErrPos = parts.Pos; SELF.ErrToken = leafLbl
      RETURN SELF.Fail('UNKNOWN_COLUMN', 'Unknown column ' & CLIP(leafLbl) & '; valid columns: ' & names.GetValue())
    END
    c.MemoNbr = memoNbr
    c.FieldNbr = 0
    c.Path = leafLbl
    c.Prefix = ''
    c.Expr = CLIP(SELF.Sch.Prefix) & ':' & leafLbl
    RETURN 0
  END

  curNbr = fieldNbr
  i = n
  LOOP WHILE i >= 1
    GET(parts, i)
    GET(SELF.Sch.Fields, curNbr)
    lbl = SELF.Sch.Fields.Label; typ = SELF.Sch.Fields.Type
    elems = SELF.Sch.Fields.Elements; dim2 = SELF.Sch.Fields.Dim2
    parentNbr = SELF.Sch.Fields.Parent
    IF UPPER(CLIP(lbl)) <> UPPER(CLIP(parts.Label))
      SELF.ErrColumn = parts.Label; SELF.ErrPos = parts.Pos; SELF.ErrToken = parts.Label
      RETURN SELF.Fail('UNKNOWN_COLUMN', CLIP(parts.Label) & ' is not inside ' & CLIP(lbl))
    END
    IF parts.HasSub1
      IF elems <= 1
        SELF.ErrColumn = lbl; SELF.ErrPos = parts.Pos; SELF.ErrToken = lbl
        RETURN SELF.Fail('UNKNOWN_COLUMN', CLIP(lbl) & ' is not an array')
      END
      IF parts.Sub1 < 1 OR parts.Sub1 > elems
        SELF.ErrColumn = lbl; SELF.ErrPos = parts.Pos; SELF.ErrToken = lbl
        RETURN SELF.Fail('UNKNOWN_COLUMN', CLIP(lbl) & '[' & parts.Sub1 & '] is out of range 1..' & elems)
      END
      IF parts.HasSub2
        IF dim2 <= 0
          SELF.ErrColumn = lbl; SELF.ErrPos = parts.Pos; SELF.ErrToken = lbl
          RETURN SELF.Fail('UNKNOWN_COLUMN', CLIP(lbl) & ' does not have a second dimension')
        END
        IF parts.Sub2 < 1 OR parts.Sub2 > dim2
          SELF.ErrColumn = lbl; SELF.ErrPos = parts.Pos; SELF.ErrToken = lbl
          RETURN SELF.Fail('UNKNOWN_COLUMN', CLIP(lbl) & ' second subscript ' & parts.Sub2 & ' is out of range 1..' & dim2)
        END
      END
      IF i = n
        c.Elem = parts.Sub1
        IF parts.HasSub2 THEN c.Elem2 = parts.Sub2.
      ELSE
        IF typ <> 'GROUP'
          SELF.ErrColumn = lbl; SELF.ErrPos = parts.Pos; SELF.ErrToken = lbl
          RETURN SELF.Fail('UNKNOWN_COLUMN', CLIP(lbl) & ' cannot be subscripted')
        END
        c.GrpElem = parts.Sub1
      END
    END
    IF i > 1
      IF parentNbr = 0
        GET(parts, i-1)
        SELF.ErrColumn = parts.Label; SELF.ErrPos = parts.Pos; SELF.ErrToken = parts.Label
        RETURN SELF.Fail('UNKNOWN_COLUMN', CLIP(parts.Label) & ' is not inside ' & CLIP(lbl))
      END
      curNbr = parentNbr
    END
    i -= 1
  END
  c.FieldNbr = fieldNbr

  ! canonical Path/Prefix text
  pathTxt.SetValue('')
  LOOP i = 1 TO n
    GET(parts, i)
    IF i > 1 THEN pathTxt.Append('.').
    pathTxt.Append(CLIP(parts.Label))
    IF parts.HasSub1 THEN pathTxt.Append('[' & parts.Sub1 & ']').
    IF parts.HasSub2 THEN pathTxt.Append('[' & parts.Sub2 & ']').
    IF i = n - 1 THEN c.Prefix = pathTxt.GetValue().
  END
  IF n = 1 THEN c.Prefix = ''.
  c.Path = pathTxt.GetValue()

  GET(SELF.Sch.Fields, fieldNbr)
  leafF.Elements = SELF.Sch.Fields.Elements; leafF.Dim2 = SELF.Sch.Fields.Dim2
  leafLbl = SELF.Sch.Fields.Label
  sv = SELF.FlatElem(c, leafF)
  c.Expr = CLIP(SELF.Sch.Prefix) & ':' & CLIP(leafLbl) & CHOOSE(sv > 0, '[' & sv & ']', '')
  RETURN 0

! single WHAT() element index from GrpElem/Elem/Elem2. A leaf that is itself DIM'd inside a
! DIM'd enclosing GROUP (EXT[j] inside PHONES[i]) flattens across the group's occurrences:
! (GrpElem-1)*f.Elements + Elem. A plain leaf inside a DIM'd group (KIND inside PHONES[i])
! takes just the group's element. A true DIM(a,b) leaf (Dim2>0, never occurs in this corpus)
! flattens the same way using its own second extent. See tpsSchema.FieldRef's comment.
tpsSql.FlatElem PROCEDURE(ColQ c, SchFieldQ f)
  CODE
  IF c.GrpElem > 0 AND c.Elem > 0 AND f.Elements > 1
    RETURN (c.GrpElem - 1) * f.Elements + c.Elem
  ELSIF c.GrpElem > 0
    RETURN c.GrpElem
  ELSIF c.Elem2 > 0
    RETURN (c.Elem - 1) * f.Dim2 + c.Elem2
  END
  RETURN c.Elem

! ---- literal conversion ----

tpsSql.Literal PROCEDURE(LONG fieldNbr, LONG memoNbr)
neg  BYTE
kind BYTE
raw  StringTheory
pos  LONG
conv StringTheory
  CODE
  pos = SqlCurPos(SELF)
  neg = 0
  IF SELF.Peek() = '-'
    neg = 1; SELF.Take()
  END
  IF SELF.PeekKind() <> TK:Num AND SELF.PeekKind() <> TK:Str
    SELF.ErrPos = pos; SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
    SELF.Fail('SYNTAX', 'Expected a literal value')
    RETURN ''
  END
  kind = SELF.PeekKind()
  raw.SetValue(SELF.Take())
  IF SqlLitConvert(SELF, fieldNbr, memoNbr, kind, raw.GetValue(), neg, conv) <> 0
    SELF.ErrPos = pos; SELF.ErrToken = CHOOSE(neg, '-', '') & raw.GetValue()
    RETURN ''
  END
  RETURN conv.GetValue()

! ---- date / time literal validation ----

tpsSql.ValidDate PROCEDURE(STRING s, *LONG clarionDate)
y   LONG
m   LONG
d   LONG
ys  STRING(4)
ms  STRING(2)
ds  STRING(2)
  CODE
  IF LEN(CLIP(s)) <> 10 THEN RETURN 0.
  IF SUB(s, 5, 1) <> '-' OR SUB(s, 8, 1) <> '-' THEN RETURN 0.
  ys = SUB(s, 1, 4); ms = SUB(s, 6, 2); ds = SUB(s, 9, 2)
  IF NOT SqlAllDigits(ys) OR NOT SqlAllDigits(ms) OR NOT SqlAllDigits(ds) THEN RETURN 0.
  y = ys; m = ms; d = ds
  IF y < 1801 OR y > 2999 OR m < 1 OR m > 12 OR d < 1 OR d > 31 THEN RETURN 0.
  clarionDate = DATE(m, d, y)
  IF clarionDate = 0 THEN RETURN 0.
  IF YEAR(clarionDate) <> y OR MONTH(clarionDate) <> m OR DAY(clarionDate) <> d THEN RETURN 0.
  RETURN 1

tpsSql.ValidTime PROCEDURE(STRING s, *LONG clarionTime)
hh  LONG
mm  LONG
ss  LONG
hs  LONG
ln  LONG
  CODE
  ln = LEN(CLIP(s))
  CASE ln
  OF 5                                  ! HH:MM
    IF SUB(s,3,1) <> ':' THEN RETURN 0.
    IF NOT SqlAllDigits(SUB(s,1,2)) OR NOT SqlAllDigits(SUB(s,4,2)) THEN RETURN 0.
    hh = SUB(s,1,2); mm = SUB(s,4,2); ss = 0; hs = 0
  OF 8                                  ! HH:MM:SS
    IF SUB(s,3,1) <> ':' OR SUB(s,6,1) <> ':' THEN RETURN 0.
    IF NOT SqlAllDigits(SUB(s,1,2)) OR NOT SqlAllDigits(SUB(s,4,2)) OR NOT SqlAllDigits(SUB(s,7,2)) THEN RETURN 0.
    hh = SUB(s,1,2); mm = SUB(s,4,2); ss = SUB(s,7,2); hs = 0
  OF 11                                 ! HH:MM:SS.hh
    IF SUB(s,3,1) <> ':' OR SUB(s,6,1) <> ':' OR SUB(s,9,1) <> '.' THEN RETURN 0.
    IF NOT SqlAllDigits(SUB(s,1,2)) OR NOT SqlAllDigits(SUB(s,4,2)) OR NOT SqlAllDigits(SUB(s,7,2)) OR NOT SqlAllDigits(SUB(s,10,2)) THEN RETURN 0.
    hh = SUB(s,1,2); mm = SUB(s,4,2); ss = SUB(s,7,2); hs = SUB(s,10,2)
  ELSE
    RETURN 0
  END
  IF hh > 23 OR mm > 59 OR ss > 59 OR hs > 99 THEN RETURN 0.
  clarionTime = (hh * 3600 + mm * 60 + ss) * 100 + hs + 1
  RETURN 1

! ---- WHERE expression builder: OR < AND < NOT < comparison ----

tpsSql.Expr PROCEDURE()
left  StringTheory
right StringTheory
  CODE
  left.SetValue(SELF.ExprAnd())
  IF SELF.Err <> '' THEN RETURN ''.
  LOOP WHILE UPPER(SELF.Peek()) = 'OR'
    SELF.Take()
    right.SetValue(SELF.ExprAnd())
    IF SELF.Err <> '' THEN RETURN ''.
    left.SetValue('(' & left.GetValue() & ' OR ' & right.GetValue() & ')')
  END
  RETURN left.GetValue()

tpsSql.ExprAnd PROCEDURE()
left  StringTheory
right StringTheory
  CODE
  left.SetValue(SELF.ExprNot())
  IF SELF.Err <> '' THEN RETURN ''.
  LOOP WHILE UPPER(SELF.Peek()) = 'AND'
    SELF.Take()
    right.SetValue(SELF.ExprNot())
    IF SELF.Err <> '' THEN RETURN ''.
    left.SetValue('(' & left.GetValue() & ' AND ' & right.GetValue() & ')')
  END
  RETURN left.GetValue()

tpsSql.ExprNot PROCEDURE()
inner StringTheory
  CODE
  IF UPPER(SELF.Peek()) = 'NOT'
    SELF.Take()
    inner.SetValue(SELF.ExprNot())
    IF SELF.Err <> '' THEN RETURN ''.
    RETURN 'NOT (' & inner.GetValue() & ')'
  END
  RETURN SELF.ExprCmp()

tpsSql.ExprCmp PROCEDURE()
lc         ColQ
rc         ColQ
leftIsRef  BYTE
rightIsRef BYTE
leftKind   BYTE
leftRaw    StringTheory        ! never a fixed buffer: a WHERE literal past its width used to be
leftNeg    BYTE
leftPos    LONG
rightNeg   BYTE
rightKind  BYTE
rightRaw   StringTheory        ! silently cut, changing which rows matched (final-review C2)
opTxt      STRING(4)
pos        LONG
inner      StringTheory
pat        StringTheory
list       StringTheory
convL      StringTheory
notFlag    BYTE
first      BYTE
uw         STRING(64)
  CODE
  IF SELF.Peek() = '('
    SELF.Take()
    inner.SetValue(SELF.Expr())
    IF SELF.Err <> '' THEN RETURN ''.
    IF SELF.Expect(')') <> 0 THEN RETURN ''.
    RETURN '(' & inner.GetValue() & ')'
  END

  leftPos = SqlCurPos(SELF)
  IF SELF.PeekKind() = TK:Ident
    uw = SqlUnsupportedWord(SELF.Peek(), SqlPeekNext(SELF), 1)
    IF uw <> ''
      SELF.ErrPos = leftPos; SELF.ErrToken = SELF.Peek()
      SELF.Fail('UNSUPPORTED', uw)
      RETURN ''
    END
    IF SELF.ColumnRef(lc) <> 0 THEN RETURN ''.
    IF lc.GrpElem > 0
      SELF.ErrPos = leftPos; SELF.ErrToken = lc.Path
      SELF.Fail('UNSUPPORTED', 'Array elements in WHERE are not supported for a leaf inside a DIM''d GROUP (' & CLIP(lc.Path) & ')')
      RETURN ''
    END
    leftIsRef = 1
  ELSIF SELF.PeekKind() = TK:Num OR SELF.PeekKind() = TK:Str OR SELF.Peek() = '-'
    leftNeg = 0
    IF SELF.Peek() = '-'
      leftNeg = 1; SELF.Take()
    END
    IF SELF.PeekKind() <> TK:Num AND SELF.PeekKind() <> TK:Str
      SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
      SELF.Fail('SYNTAX', 'Expected a column or a literal')
      RETURN ''
    END
    leftKind = SELF.PeekKind()
    leftRaw.SetValue(SELF.Take())
    leftIsRef = 0
  ELSE
    SELF.ErrPos = leftPos; SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
    SELF.Fail('SYNTAX', 'Expected a column or a literal')
    RETURN ''
  END

  IF leftIsRef AND UPPER(SELF.Peek()) = 'LIKE'
    SELF.Take()
    IF SELF.PeekKind() <> TK:Str
      SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
      SELF.Fail('SYNTAX', 'LIKE requires a string pattern')
      RETURN ''
    END
    pos = SqlCurPos(SELF)
    pat.SetValue(SELF.Take())
    IF INSTRING('*', pat.GetValue(), 1, 1) > 0 OR INSTRING('?', pat.GetValue(), 1, 1) > 0
      SELF.ErrPos = pos; SELF.ErrToken = pat.GetValue()
      SELF.Fail('UNSUPPORTED', 'LIKE cannot match a literal * or ?')
      RETURN ''
    END
    pat.SetValue(SqlEscapeStr(pat.GetValue()))
    pat.Replace('%', '*')
    pat.Replace('_', '?')
    RETURN 'MATCH(' & CLIP(lc.Expr) & ',''' & pat.GetValue() & ''',1)'
  END

  IF leftIsRef AND (UPPER(SELF.Peek()) = 'IN' OR UPPER(SELF.Peek()) = 'NOT')
    notFlag = 0
    IF UPPER(SELF.Peek()) = 'NOT'
      SELF.Take()
      IF UPPER(SELF.Peek()) <> 'IN'
        SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
        SELF.Fail('SYNTAX', 'Expected IN after NOT')
        RETURN ''
      END
      notFlag = 1
    END
    SELF.Take()                              ! IN
    IF SELF.Expect('(') <> 0 THEN RETURN ''.
    list.SetValue('')
    first = 1
    LOOP
      inner.SetValue(SELF.Literal(lc.FieldNbr, lc.MemoNbr))
      IF SELF.Err <> '' THEN RETURN ''.
      list.Append(CHOOSE(first, '', ',') & inner.GetValue())
      first = 0
      IF SELF.Peek() = ',' THEN SELF.Take(); CYCLE.
      BREAK
    END
    IF SELF.Expect(')') <> 0 THEN RETURN ''.
    RETURN 'INLIST(' & CLIP(lc.Expr) & ',' & list.GetValue() & ')' & CHOOSE(notFlag, ' = 0', '')
  END

  IF UPPER(SELF.Peek()) = 'IS'
    SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = 'IS'
    SELF.Fail('UNSUPPORTED', 'IS NULL is not supported; TPS has no NULL')
    RETURN ''
  END

  IF SELF.PeekKind() = TK:Op AND (SELF.Peek() = '+' OR SELF.Peek() = '-' OR SELF.Peek() = '/' OR SELF.Peek() = '*')
    SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = SELF.Peek()
    SELF.Fail('UNSUPPORTED', 'Arithmetic expressions are not supported')
    RETURN ''
  END

  IF SELF.PeekKind() <> TK:Op OR NOT (SELF.Peek() = '=' OR SELF.Peek() = '<>' OR SELF.Peek() = '!=' OR SELF.Peek() = '<' OR SELF.Peek() = '>' OR SELF.Peek() = '<=' OR SELF.Peek() = '>=')
    SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
    SELF.Fail('SYNTAX', 'Expected a comparison operator')
    RETURN ''
  END
  opTxt = SELF.Take()
  IF opTxt = '!=' THEN opTxt = '<>'.

  pos = SqlCurPos(SELF)
  IF SELF.PeekKind() = TK:Ident
    uw = SqlUnsupportedWord(SELF.Peek(), SqlPeekNext(SELF), 1)
    IF uw <> ''
      SELF.ErrPos = pos; SELF.ErrToken = SELF.Peek()
      SELF.Fail('UNSUPPORTED', uw)
      RETURN ''
    END
    IF SELF.ColumnRef(rc) <> 0 THEN RETURN ''.
    IF rc.GrpElem > 0
      SELF.ErrPos = pos; SELF.ErrToken = rc.Path
      SELF.Fail('UNSUPPORTED', 'Array elements in WHERE are not supported for a leaf inside a DIM''d GROUP (' & CLIP(rc.Path) & ')')
      RETURN ''
    END
    rightIsRef = 1
  ELSIF SELF.PeekKind() = TK:Num OR SELF.PeekKind() = TK:Str OR SELF.Peek() = '-'
    rightIsRef = 0
  ELSE
    SELF.ErrPos = pos; SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
    SELF.Fail('SYNTAX', 'Expected a column or a literal')
    RETURN ''
  END

  IF leftIsRef AND rightIsRef
    SELF.ErrPos = pos; SELF.ErrToken = rc.Path
    SELF.Fail('UNSUPPORTED', 'Column-to-column comparison is not supported')
    RETURN ''
  END

  IF leftIsRef
    inner.SetValue(SELF.Literal(lc.FieldNbr, lc.MemoNbr))
    IF SELF.Err <> '' THEN RETURN ''.
    RETURN CLIP(lc.Expr) & ' ' & CLIP(opTxt) & ' ' & inner.GetValue()
  END
  IF rightIsRef
    IF SqlLitConvert(SELF, rc.FieldNbr, rc.MemoNbr, leftKind, leftRaw.GetValue(), leftNeg, convL) <> 0
      SELF.ErrPos = leftPos; SELF.ErrToken = CHOOSE(leftNeg, '-', '') & leftRaw.GetValue()
      RETURN ''
    END
    RETURN convL.GetValue() & ' ' & CLIP(opTxt) & ' ' & CLIP(rc.Expr)
  END

  ! both sides bare literals (e.g. 1 = 1): no column to carry a type, so pass the raw text through
  rightNeg = 0
  IF SELF.Peek() = '-'
    rightNeg = 1; SELF.Take()
  END
  rightKind = SELF.PeekKind()
  rightRaw.SetValue(SELF.Take())
  IF rightKind <> leftKind
    SELF.ErrPos = pos; SELF.ErrToken = rightRaw.GetValue()
    SELF.Fail('SYNTAX', 'Comparing two literals requires matching kinds')
    RETURN ''
  END
  IF leftKind = TK:Num
    RETURN CHOOSE(leftNeg, '-', '') & leftRaw.GetValue() & ' ' & CLIP(opTxt) & ' ' & CHOOSE(rightNeg, '-', '') & rightRaw.GetValue()
  END
  RETURN '''' & SqlEscapeStr(leftRaw.GetValue()) & '''' & ' ' & CLIP(opTxt) & ' ' & '''' & SqlEscapeStr(rightRaw.GetValue()) & ''''

! ---- statement body: SELECT / INSERT / UPDATE / DELETE, after Sch is loaded ----

tpsSql.ParseBody PROCEDURE()
c      ColQ
i      LONG
j      LONG
w      STRING(24)
uw     STRING(64)
fnbr   LONG
mnbr   LONG
colPos LONG
  CODE
  SELF.Err = ''; SELF.ErrMsg = ''; SELF.ErrPos = 0; SELF.ErrToken = ''; SELF.ErrColumn = ''
  FREE(SELF.Cols); FREE(SELF.Vals); FREE(SELF.Order)
  SELF.Where = ''; SELF.HasWhere = 0; SELF.Star = 0
  SELF.Limit = 0; SELF.HasLimit = 0; SELF.Offset = 0
  SELF.Cur = 1
  SELF.Take()                                    ! consume the op keyword

  CASE SELF.Op
  OF OP:Select
    IF SELF.Peek() = '*'
      SELF.Take(); SELF.Star = 1
    ELSE
      LOOP
        uw = SqlUnsupportedWord(SELF.Peek(), SqlPeekNext(SELF), 1)
        IF SELF.PeekKind() = TK:Ident AND uw <> ''
          SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = SELF.Peek()
          RETURN SELF.Fail('UNSUPPORTED', uw)
        END
        IF SELF.ColumnRef(c) <> 0 THEN RETURN 1.
        SELF.Cols = c; ADD(SELF.Cols)
        IF SELF.Peek() = ',' THEN SELF.Take(); CYCLE.
        BREAK
      END
    END
    IF SELF.Expect('FROM') <> 0 THEN RETURN 1.
    SELF.Take()                                  ! path token
    DO WhereRoutine
    DO OrderByRoutine
    DO LimitOffsetRoutine
    DO TrailingRoutine
  OF OP:Insert
    IF SELF.Expect('INTO') <> 0 THEN RETURN 1.
    SELF.Take()                                  ! path token
    IF SELF.Expect('(') <> 0 THEN RETURN 1.
    LOOP
      colPos = SqlCurPos(SELF)
      IF SELF.ColumnRef(c) <> 0 THEN RETURN 1.
      IF SqlRequireLeaf(SELF, c) <> 0 THEN RETURN 1.
      LOOP j = 1 TO RECORDS(SELF.Cols)
        GET(SELF.Cols, j)
        IF UPPER(SELF.Cols.Path) = UPPER(c.Path)
          SELF.ErrColumn = c.Path; SELF.ErrPos = colPos; SELF.ErrToken = c.Path
          RETURN SELF.Fail('SYNTAX', CLIP(c.Path) & ' is specified more than once')
        END
      END
      SELF.Cols = c; ADD(SELF.Cols)
      IF SELF.Peek() = ',' THEN SELF.Take(); CYCLE.
      BREAK
    END
    IF SELF.Expect(')') <> 0 THEN RETURN 1.
    IF SELF.Expect('VALUES') <> 0 THEN RETURN 1.
    IF SELF.Expect('(') <> 0 THEN RETURN 1.
    i = 0
    LOOP
      i += 1
      IF i > RECORDS(SELF.Cols)
        SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
        RETURN SELF.Fail('SYNTAX', 'INSERT has more values than columns')
      END
      GET(SELF.Cols, i); fnbr = SELF.Cols.FieldNbr; mnbr = SELF.Cols.MemoNbr
      IF SqlCaptureValue(SELF, fnbr, mnbr) <> 0 THEN RETURN 1.
      IF SELF.Peek() = ',' THEN SELF.Take(); CYCLE.
      BREAK
    END
    IF i <> RECORDS(SELF.Cols)
      SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
      RETURN SELF.Fail('SYNTAX', 'INSERT column count does not match value count')
    END
    IF SELF.Expect(')') <> 0 THEN RETURN 1.
    DO TrailingRoutine
  OF OP:Update
    SELF.Take()                                  ! path token
    IF SELF.Expect('SET') <> 0 THEN RETURN 1.
    LOOP
      colPos = SqlCurPos(SELF)
      IF SELF.ColumnRef(c) <> 0 THEN RETURN 1.
      IF SqlRequireLeaf(SELF, c) <> 0 THEN RETURN 1.
      LOOP j = 1 TO RECORDS(SELF.Cols)
        GET(SELF.Cols, j)
        IF UPPER(SELF.Cols.Path) = UPPER(c.Path)
          SELF.ErrColumn = c.Path; SELF.ErrPos = colPos; SELF.ErrToken = c.Path
          RETURN SELF.Fail('SYNTAX', CLIP(c.Path) & ' is specified more than once')
        END
      END
      IF SELF.Expect('=') <> 0 THEN RETURN 1.
      SELF.Cols = c; ADD(SELF.Cols)
      IF SqlCaptureValue(SELF, c.FieldNbr, c.MemoNbr) <> 0 THEN RETURN 1.
      IF SELF.Peek() = ',' THEN SELF.Take(); CYCLE.
      BREAK
    END
    IF UPPER(SELF.Peek()) <> 'WHERE'
      SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
      RETURN SELF.Fail('WHERE_REQUIRED', 'UPDATE without WHERE is refused. Use WHERE 1 = 1 to update every row.')
    END
    DO WhereRoutine
    IF UPPER(SELF.Peek()) = 'LIMIT' OR UPPER(SELF.Peek()) = 'OFFSET'
      w = SELF.Peek()
      SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = w
      RETURN SELF.Fail('UNSUPPORTED', CLIP(w) & ' is not supported on UPDATE')
    END
    DO TrailingRoutine
  OF OP:Delete
    SELF.Take()                                  ! FROM
    SELF.Take()                                  ! path token
    IF UPPER(SELF.Peek()) <> 'WHERE'
      SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
      RETURN SELF.Fail('WHERE_REQUIRED', 'DELETE without WHERE is refused. Use WHERE 1 = 1 to delete every row.')
    END
    DO WhereRoutine
    IF UPPER(SELF.Peek()) = 'LIMIT' OR UPPER(SELF.Peek()) = 'OFFSET'
      w = SELF.Peek()
      SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = w
      RETURN SELF.Fail('UNSUPPORTED', CLIP(w) & ' is not supported on DELETE')
    END
    DO TrailingRoutine
  END
  RETURN 0

WhereRoutine ROUTINE
  IF UPPER(SELF.Peek()) = 'WHERE'
    SELF.Take()
    SELF.Where = SELF.Expr()
    IF SELF.Err <> '' THEN RETURN 1.
    SELF.HasWhere = 1
  END

OrderByRoutine ROUTINE
  IF UPPER(SELF.Peek()) = 'ORDER'
    SELF.Take()
    IF SELF.Expect('BY') <> 0 THEN RETURN 1.
    LOOP
      colPos = SqlCurPos(SELF)
      IF SELF.ColumnRef(c) <> 0 THEN RETURN 1.
      IF c.GrpElem > 0
        SELF.ErrPos = colPos; SELF.ErrToken = c.Path
        RETURN SELF.Fail('UNSUPPORTED', 'ORDER BY is not supported for a leaf inside a DIM''d GROUP (' & CLIP(c.Path) & ')')
      END
      ! A memo/BLOB column has FieldNbr 0 and no record-buffer field to sort on, so it used to be
      ! accepted and then silently ignored - rows came back ok: true in file order (I3).
      IF c.MemoNbr > 0 OR c.FieldNbr < 1
        SELF.ErrColumn = c.Path; SELF.ErrPos = colPos; SELF.ErrToken = c.Path
        RETURN SELF.Fail('UNSUPPORTED', 'ORDER BY is not supported for a MEMO or BLOB column (' & CLIP(c.Path) & ')')
      END
      CLEAR(SELF.Order)
      SELF.Order.FieldNbr = c.FieldNbr
      GET(SELF.Sch.Fields, c.FieldNbr)
      SELF.Order.Elem = SELF.FlatElem(c, SELF.Sch.Fields)
      SELF.Order.Desc = 0
      IF UPPER(SELF.Peek()) = 'ASC'
        SELF.Take()
      ELSIF UPPER(SELF.Peek()) = 'DESC'
        SELF.Take(); SELF.Order.Desc = 1
      END
      ADD(SELF.Order)
      IF SELF.Peek() = ',' THEN SELF.Take(); CYCLE.
      BREAK
    END
  END

LimitOffsetRoutine ROUTINE
  IF UPPER(SELF.Peek()) = 'LIMIT'
    SELF.Take()
    IF SELF.PeekKind() <> TK:Num
      SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
      RETURN SELF.Fail('SYNTAX', 'LIMIT requires a non-negative integer')
    END
    SELF.Limit = SELF.Take(); SELF.HasLimit = 1
    IF UPPER(SELF.Peek()) = 'OFFSET'
      SELF.Take()
      IF SELF.PeekKind() <> TK:Num
        SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = CHOOSE(SELF.PeekKind() = TK:Eof, '<eof>', SELF.Peek())
        RETURN SELF.Fail('SYNTAX', 'OFFSET requires a non-negative integer')
      END
      SELF.Offset = SELF.Take()
    END
  END

TrailingRoutine ROUTINE
  uw = SqlUnsupportedWord(SELF.Peek(), SqlPeekNext(SELF), 0)
  IF SELF.PeekKind() = TK:Ident AND uw <> ''
    SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = SELF.Peek()
    RETURN SELF.Fail('UNSUPPORTED', uw)
  END
  IF SELF.PeekKind() <> TK:Eof
    SELF.ErrPos = SqlCurPos(SELF); SELF.ErrToken = SELF.Peek()
    RETURN SELF.Fail('SYNTAX', 'Unexpected token ' & SELF.Peek())
  END

! ---- private helpers (module-local, not on the class) ----

! Appends one token, storing its text in a &STRING of exactly the token's length. The old
! STRING(1024) field silently cut every literal longer than that: a MEMO was written short and a
! BLOB's base64 was written as a different value, with no warning and exit 0 (final-review C2).
! Len carries the true length because a zero-length token still needs a one-byte allocation.
SqlTokAdd PROCEDURE(tpsSql s, BYTE kind, STRING txt, LONG pos)
n  LONG
  CODE
  n = LEN(txt)
  CLEAR(s.Toks)
  s.Toks.Kind = kind
  s.Toks.Len = n
  s.Toks.Text &= NEW STRING(CHOOSE(n = 0, 1, n))
  IF n > 0 THEN s.Toks.Text = txt.
  s.Toks.Pos = pos
  ADD(s.Toks)

SqlTokFree PROCEDURE(tpsSql s)
i  LONG
  CODE
  LOOP i = 1 TO RECORDS(s.Toks)
    GET(s.Toks, i)
    IF NOT s.Toks.Text &= NULL THEN DISPOSE(s.Toks.Text).
  END
  FREE(s.Toks)

SqlCurPos PROCEDURE(tpsSql s)
  CODE
  IF s.Cur <= RECORDS(s.Toks)
    GET(s.Toks, s.Cur)
  ELSE
    GET(s.Toks, RECORDS(s.Toks))
  END
  RETURN s.Toks.Pos

! the token one past the current one, without consuming anything; used for GROUP-BY lookahead
SqlPeekNext PROCEDURE(tpsSql s)
  CODE
  IF s.Cur + 1 > RECORDS(s.Toks) THEN RETURN ''.
  GET(s.Toks, s.Cur + 1)
  IF s.Toks.Len = 0 THEN RETURN ''.
  RETURN s.Toks.Text[1 : s.Toks.Len]

SqlAllDigits PROCEDURE(STRING s)
i LONG
c BYTE
  CODE
  IF LEN(s) = 0 THEN RETURN 0.
  LOOP i = 1 TO LEN(s)
    c = VAL(s[i])
    IF c < 48 OR c > 57 THEN RETURN 0.
  END
  RETURN 1

SqlEscapeStr PROCEDURE(STRING s)
st StringTheory
  CODE
  st.SetValue(s)
  st.Replace('''', '''''')
  st.Replace('<', '<60>')
  st.Replace('{{', '<123>')
  RETURN st.GetValue()

! A reserved word is only reserved where it is syntactically a keyword. atColumnPos = 1 marks the
! three places a bare identifier is a COLUMN NAME (the SELECT list and either side of a WHERE
! comparison); there, JOIN/HAVING/DISTINCT/UNION/GROUP fall through to ordinary column
! resolution, and an aggregate name is only an aggregate when '(' follows it - the same
! one-token lookahead GROUP BY already used. Without this a TPS file with a column called COUNT
! or MAX, which is not rare in a POS schema, could not be selected at all and there is no
! quoted-identifier escape hatch (final-review I6).
SqlUnsupportedWord PROCEDURE(STRING w, STRING nextTok, BYTE atColumnPos)
u STRING(24)
  CODE
  u = UPPER(CLIP(w))
  CASE u
  OF 'COUNT' OROF 'SUM' OROF 'MIN' OROF 'MAX' OROF 'AVG'
    IF CLIP(nextTok) <> '(' THEN RETURN ''.
    RETURN 'Aggregate functions are not supported (' & CLIP(u) & ')'
  END
  IF atColumnPos THEN RETURN ''.
  CASE u
  OF 'JOIN'     ; RETURN 'JOIN is not supported'
  OF 'GROUP'
    IF UPPER(CLIP(nextTok)) = 'BY' THEN RETURN 'GROUP BY is not supported'.
    RETURN ''
  OF 'HAVING'   ; RETURN 'HAVING is not supported'
  OF 'DISTINCT' ; RETURN 'DISTINCT is not supported'
  OF 'UNION'    ; RETURN 'UNION is not supported'
  END
  RETURN ''

SqlRequireLeaf PROCEDURE(tpsSql s, ColQ c)
  CODE
  IF c.MemoNbr > 0 THEN RETURN 0.
  GET(s.Sch.Fields, c.FieldNbr)
  IF s.Sch.Fields.Type = 'GROUP'
    s.ErrColumn = s.Sch.Fields.Label; s.ErrPos = SqlCurPos(s); s.ErrToken = CLIP(s.Sch.Fields.Label)
    RETURN s.Fail('UNSUPPORTED', CLIP(s.Sch.Fields.Label) & ' is a GROUP; assign individual leaves')
  END
  IF s.Sch.Fields.Elements > 1 AND c.Elem = 0
    s.ErrColumn = s.Sch.Fields.Label; s.ErrPos = SqlCurPos(s); s.ErrToken = CLIP(s.Sch.Fields.Label)
    RETURN s.Fail('UNKNOWN_COLUMN', CLIP(s.Sch.Fields.Label) & ' needs a subscript, e.g. ' & CLIP(s.Sch.Fields.Label) & '[1]')
  END
  RETURN 0

SqlCaptureValue PROCEDURE(tpsSql s, LONG fieldNbr, LONG memoNbr)
neg  BYTE
kind BYTE
raw  StringTheory
pos  LONG
conv StringTheory
full StringTheory
n    LONG
  CODE
  pos = SqlCurPos(s)
  neg = 0
  IF s.Peek() = '-'
    neg = 1; s.Take()
  END
  IF s.PeekKind() <> TK:Num AND s.PeekKind() <> TK:Str
    s.ErrPos = pos; s.ErrToken = CHOOSE(s.PeekKind() = TK:Eof, '<eof>', s.Peek())
    RETURN s.Fail('SYNTAX', 'Expected a literal value')
  END
  kind = s.PeekKind()
  raw.SetValue(s.Take())
  IF SqlLitConvert(s, fieldNbr, memoNbr, kind, raw.GetValue(), neg, conv) <> 0
    s.ErrPos = pos; s.ErrToken = CHOOSE(neg, '-', '') & raw.GetValue()
    RETURN 1
  END
  ! Length from the StringTheory, never LEN(CLIP(...)): a MEMO or BLOB literal's trailing spaces
  ! are data, and clipping them here wrote a shorter value than the caller asked for.
  full.SetValue(CHOOSE(neg, '-', '') & raw.GetValue())
  n = full.Length()
  CLEAR(s.Vals)
  s.Vals.Kind = kind
  s.Vals.Text &= NEW STRING(CHOOSE(n = 0, 1, n))
  IF n > 0 THEN s.Vals.Text = full.GetValue().
  s.Vals.Len = n
  ADD(s.Vals)
  RETURN 0

! typed literal -> Clarion expression text. rawText/neg are the already-tokenized literal
! (never re-reads the token stream), so it serves both Literal() (WHERE) and SqlCaptureValue
! (INSERT/UPDATE values), and the literal-first branch of ExprCmp ('1 = 1', 'literal op ref').
SqlLitConvert PROCEDURE(tpsSql s, LONG fieldNbr, LONG memoNbr, BYTE kind, STRING rawText, BYTE neg, StringTheory outp)
typ    STRING(12)
label  STRING(64)
places LONG
digits LONG
cd     LONG
ct     LONG
dotPos LONG
intPart  STRING(32)
fracPart STRING(32)
roundDigit LONG
carry  LONG
i      LONG
d      LONG
ival   REAL
minV   REAL
maxV   REAL
usedDigits LONG
  CODE
  ! A memo or BLOB column has no entry in Sch.Fields at all - ColQ.FieldNbr is 0 for one - so
  ! GET(Fields, 0) used to fail and leave the queue buffer holding whatever the last scan put
  ! there (the file's LAST field), typing the literal from an unrelated column and naming that
  ! column in the error (final-review I3). The label lives in Sch.Memos instead.
  IF fieldNbr < 1
    GET(s.Sch.Memos, memoNbr)
    label = s.Sch.Memos.Label
    IF kind <> TK:Str
      s.ErrColumn = label
      RETURN s.Fail('VALUE_OUT_OF_RANGE', CLIP(label) & ' requires a string literal')
    END
    outp.SetValue('''' & SqlEscapeStr(rawText) & '''')
    RETURN 0
  END
  GET(s.Sch.Fields, fieldNbr)
  typ = s.Sch.Fields.Type; label = s.Sch.Fields.Label
  ! SchFieldQ.Size (not .Digits!) holds the true total digit count for a DECIMAL field - Build()
  ! passes fg.Size = Fields.Size to DynFile.AddField as the field's digit width, and it round-trips
  ! correctly for e.g. ALLTYPES.D (12345.67, a 7-digit DECIMAL(7,2)) which reads back intact.
  ! Fields.Digits is a different raw definition byte (see tpsSchema.clw's decode comment: "the file
  ! stores packed-decimal storage bytes, not digit count"); using it here rejected every literal
  ! needing more than 4 significant digits into that same field ("overflows DECIMAL(4,2)"),
  ! confirmed empirically with --parse-only against testdata\ALLTYPES.TPS. See task-8-report.md.
  places = s.Sch.Fields.Places; digits = s.Sch.Fields.Size
  CASE typ
  OF 'DATE'
    IF kind <> TK:Str
      s.ErrColumn = label
      RETURN s.Fail('VALUE_OUT_OF_RANGE', CLIP(label) & ' is a DATE column; use a ''YYYY-MM-DD'' literal')
    END
    IF rawText = ''
      outp.SetValue('0'); RETURN 0
    END
    IF NOT s.ValidDate(rawText, cd)
      s.ErrColumn = label
      RETURN s.Fail('VALUE_OUT_OF_RANGE', 'Invalid date ''' & CLIP(rawText) & ''' for column ' & CLIP(label))
    END
    outp.SetValue(cd)
  OF 'TIME'
    IF kind <> TK:Str
      s.ErrColumn = label
      RETURN s.Fail('VALUE_OUT_OF_RANGE', CLIP(label) & ' is a TIME column; use an ''HH:MM:SS'' literal')
    END
    IF rawText = ''
      outp.SetValue('0'); RETURN 0
    END
    IF NOT s.ValidTime(rawText, ct)
      s.ErrColumn = label
      RETURN s.Fail('VALUE_OUT_OF_RANGE', 'Invalid time ''' & CLIP(rawText) & ''' for column ' & CLIP(label))
    END
    outp.SetValue(ct)
  OF 'BYTE' OROF 'SHORT' OROF 'USHORT' OROF 'LONG' OROF 'ULONG'
    IF kind <> TK:Num
      s.ErrColumn = label
      RETURN s.Fail('VALUE_OUT_OF_RANGE', CLIP(label) & ' requires an integer literal')
    END
    IF INSTRING('.', rawText, 1, 1) > 0
      s.ErrColumn = label
      RETURN s.Fail('VALUE_OUT_OF_RANGE', CLIP(label) & ' does not accept a fraction')
    END
    ival = rawText; IF neg THEN ival = -ival.
    CASE typ
    OF 'BYTE'   ; minV = 0;           maxV = 255
    OF 'SHORT'  ; minV = -32768;      maxV = 32767
    OF 'USHORT' ; minV = 0;           maxV = 65535
    OF 'LONG'   ; minV = -2147483648; maxV = 2147483647
    OF 'ULONG'  ; minV = 0;           maxV = 4294967295
    END
    IF ival < minV OR ival > maxV
      s.ErrColumn = label
      RETURN s.Fail('VALUE_OUT_OF_RANGE', CLIP(label) & ' value ' & CHOOSE(neg,'-','') & CLIP(rawText) & ' is outside the range of ' & CLIP(typ))
    END
    outp.SetValue(CHOOSE(neg, '-', '') & rawText)
  OF 'SREAL' OROF 'REAL'
    IF kind <> TK:Num
      s.ErrColumn = label
      RETURN s.Fail('VALUE_OUT_OF_RANGE', CLIP(label) & ' requires a numeric literal')
    END
    outp.SetValue(CHOOSE(neg, '-', '') & rawText)
  OF 'DECIMAL'
    IF kind <> TK:Num
      s.ErrColumn = label
      RETURN s.Fail('VALUE_OUT_OF_RANGE', CLIP(label) & ' requires a numeric literal')
    END
    dotPos = INSTRING('.', rawText, 1, 1)
    IF dotPos = 0
      intPart = rawText; fracPart = ''
    ELSE
      intPart = SUB(rawText, 1, dotPos-1); fracPart = SUB(rawText, dotPos+1, LEN(rawText)-dotPos)
    END
    IF LEN(CLIP(fracPart)) > places
      roundDigit = VAL(fracPart[places+1]) - 48
      fracPart = SUB(fracPart, 1, places)
      IF roundDigit >= 5
        carry = 1
        i = places
        LOOP WHILE i >= 1 AND carry = 1
          d = VAL(fracPart[i]) - 48 + carry
          IF d = 10
            d = 0; carry = 1
          ELSE
            carry = 0
          END
          fracPart[i] = CHR(48 + d)
          i -= 1
        END
        IF carry = 1 THEN intPart = intPart + 1.
      END
    ELSE
      fracPart = fracPart & ALL('0', places - LEN(CLIP(fracPart)))
    END
    usedDigits = LEN(CLIP(intPart)) + places
    IF usedDigits > digits
      s.ErrColumn = label
      RETURN s.Fail('VALUE_OUT_OF_RANGE', CLIP(label) & ' value ' & CHOOSE(neg,'-','') & CLIP(rawText) & ' overflows DECIMAL(' & digits & ',' & places & ')')
    END
    outp.SetValue(CHOOSE(neg, '-', '') & CLIP(intPart) & CHOOSE(places > 0, '.' & CLIP(fracPart), ''))
  OF 'STRING' OROF 'CSTRING' OROF 'PSTRING'
    IF kind <> TK:Str
      s.ErrColumn = label
      RETURN s.Fail('VALUE_OUT_OF_RANGE', CLIP(label) & ' requires a string literal')
    END
    outp.SetValue('''' & SqlEscapeStr(rawText) & '''')
  ELSE
    s.ErrColumn = label
    RETURN s.Fail('SYNTAX', CLIP(label) & ' (' & CLIP(typ) & ') cannot be used as a literal-typed column')
  END
  RETURN 0
