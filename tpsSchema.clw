  MEMBER()
  INCLUDE('tpsSchema.inc'),ONCE
  MAP
    SchFieldOffsetEnd(tpsSchema s, LONG i),LONG
    SchFieldOffsetOf(tpsSchema s, LONG i),LONG
    SchEmitFields(tpsSchema s, StringTheory js, LONG parentNbr, STRING dotted)
    SchEmitOneField(tpsSchema s, StringTheory js, LONG idx, STRING dotted)
  END
Kw    LONG,DIM(16)          ! decryption key schedule, module static (OVER is not allowed on class members)
Kb    STRING(64),OVER(Kw)

tpsSchema.Construct  PROCEDURE()
  CODE
  SELF.st &= NEW StringTheory
  SELF.Fields &= NEW SchFieldQ; SELF.Keys &= NEW SchKeyQ
  SELF.Comps  &= NEW SchKeyCompQ; SELF.Memos &= NEW SchMemoQ

tpsSchema.Destruct   PROCEDURE()
  CODE
  DISPOSE(SELF.st)
  DISPOSE(SELF.Fields); DISPOSE(SELF.Keys)
  DISPOSE(SELF.Comps); DISPOSE(SELF.Memos)
  IF NOT SELF.Def &= NULL THEN DISPOSE(SELF.Def).

tpsSchema.Bad  PROCEDURE(STRING why)
  CODE
  SELF.Err = 'DEFINITION_UNREADABLE'; SELF.ErrMsg = CLIP(why) & '; run TPSFix'
  RETURN 2

! Every byte helper range-checks; an out-of-range read sets SELF.Overrun and returns 0. Parse and Walk
! test SELF.Overrun after each structure and return Bad('read past end of ...') when it is set.
tpsSchema.U8   PROCEDURE(LONG o)
  CODE
  IF o < 0 OR o >= SELF.size THEN SELF.Overrun = 1; RETURN 0.
  RETURN VAL(SELF.buf[o+1])

tpsSchema.U16  PROCEDURE(LONG o)
v  USHORT
s  STRING(2),OVER(v)
  CODE
  IF o < 0 OR o+2 > SELF.size THEN SELF.Overrun = 1; RETURN 0.
  s = SELF.buf[o+1 : o+2]
  RETURN v

tpsSchema.U32  PROCEDURE(LONG o)
v  LONG
s  STRING(4),OVER(v)
  CODE
  IF o < 0 OR o+4 > SELF.size THEN SELF.Overrun = 1; RETURN 0.
  s = SELF.buf[o+1 : o+4]
  RETURN v

tpsSchema.BE32 PROCEDURE(LONG o)
v  LONG
s  STRING(4),OVER(v)
  CODE
  s = SELF.buf[o+4] & SELF.buf[o+3] & SELF.buf[o+2] & SELF.buf[o+1]
  RETURN v

tpsSchema.ZStr PROCEDURE(*LONG o)
start LONG
  CODE
  start = o
  LOOP WHILE o < SELF.size AND VAL(SELF.buf[o+1]) <> 0
    o += 1
  END
  IF o >= SELF.size THEN SELF.Overrun = 1; RETURN ''.       ! no terminator before end of data
  o += 1                         ! step over the terminator
  IF o - 1 > start THEN RETURN SELF.buf[start+1 : o-1].
  RETURN ''

tpsSchema.Load PROCEDURE(STRING path, STRING owner)
  CODE
  SELF.Path = path
  SELF.Owner = owner
  IF NOT EXISTS(path)
    SELF.Err = 'FILE_NOT_FOUND'; SELF.ErrMsg = 'File not found: ' & CLIP(path); RETURN 2
  END
  IF SELF.st.LoadFile(path) = 0
    SELF.Err = 'FILE_NOT_FOUND'; SELF.ErrMsg = 'Cannot read ' & CLIP(path) & ': ' & SELF.st.lastError; RETURN 2
  END
  SELF.buf &= SELF.st.valueptr
  SELF.size = SELF.st.Length()
  IF SELF.size < 200h
    SELF.Err = 'DEFINITION_UNREADABLE'; SELF.ErrMsg = 'File shorter than the 512-byte TPS header'; RETURN 2
  END
  IF SELF.buf[0Fh : 12h] <> 'tOpS'
    IF owner = ''
      SELF.Err = 'OWNER_REQUIRED'; SELF.ErrMsg = 'Not a plain TopSpeed file; if it is encrypted pass --owner'; RETURN 2
    END
    SELF.Decrypt(owner)
    IF SELF.buf[0Fh : 12h] <> 'tOpS'
      SELF.Err = 'OWNER_WRONG'; SELF.ErrMsg = 'Owner string does not decrypt this file'; RETURN 2
    END
    SELF.Encrypted = 1
  END
  IF SELF.U32(0) <> 0
    SELF.Err = 'DEFINITION_UNREADABLE'; SELF.ErrMsg = 'Header address is not zero'; RETURN 2
  END
  RETURN SELF.Walk()

tpsSchema.Decrypt PROCEDURE(STRING owner)
ownerBytes STRING(65)
klen  LONG
t     LONG
tx    LONG
i     LONG
wa    LONG
pb    LONG
wb    LONG
ofs   LONG
endo  LONG
  CODE
  klen = LEN(CLIP(owner)) + 1               ! trailing zero byte is part of the key
  ownerBytes = CLIP(owner) & '<0>'
  LOOP t = 0 TO 63
    tx = BAND(t * 11h, 3Fh)
    Kb[tx+1] = CHR(BAND(t + VAL(ownerBytes[((t+1) % klen) + 1]), 0FFh))
  END
  LOOP i = 1 TO 2                            ! shuffle twice
    LOOP t = 1 TO 16
      wa = Kw[t]; pb = BAND(wa, 0Fh) + 1; wb = Kw[pb]
      Kw[pb] = wa + BAND(wa, wb)        ! unsigned add, wraps
      Kw[t]  = BOR(wa, wb) + wa
    END
  END
  SELF.Decrypt64(0); SELF.Decrypt64(64); SELF.Decrypt64(128); SELF.Decrypt64(192)
  SELF.Decrypt64(256); SELF.Decrypt64(320); SELF.Decrypt64(384); SELF.Decrypt64(448)
  IF SELF.buf[0Fh : 12h] <> 'tOpS' THEN RETURN.               ! wrong owner: caller reports OWNER_WRONG, never follow block pointers
  LOOP t = 0 TO 59
    ofs  = BSHIFT(SELF.U32(20h + t*4), 8) + 200h
    endo = BSHIFT(SELF.U32(110h + t*4), 8) + 200h
    IF (ofs = 200h AND endo = 200h) OR ofs < 200h OR ofs >= SELF.size OR endo < ofs THEN CYCLE.
    IF endo > SELF.size THEN endo = SELF.size.
    LOOP WHILE ofs + 64 <= endo
      SELF.Decrypt64(ofs); ofs += 64
    END
  END

tpsSchema.Decrypt64 PROCEDURE(LONG o)
dw    LONG,DIM(16)
db    STRING(64),OVER(dw)
t     LONG
ka    LONG
pb    LONG
d1    LONG
d2    LONG
nk    LONG
  CODE
  db = SELF.buf[o+1 : o+64]
  LOOP t = 16 TO 1 BY -1
    ka = Kw[t]; pb = BAND(ka, 0Fh) + 1
    d1 = dw[t]  - ka
    d2 = dw[pb] - ka
    nk = BXOR(ka, -1)
    dw[t]  = BOR(BAND(d1, ka), BAND(d2, nk))
    dw[pb] = BOR(BAND(d2, ka), BAND(d1, nk))
  END
  SELF.buf[o+1 : o+64] = db

tpsSchema.DeRle PROCEDURE(LONG o, LONG clen, StringTheory outp)
p     LONG
endo  LONG
skip  LONG
msb   LONG
rep   LONG
cnt   LONG
  CODE
  p = o; endo = o + clen
  LOOP WHILE p < endo
    skip = SELF.U8(p); p += 1
    IF skip = 0 THEN RETURN 0.
    IF skip > 7Fh
      IF p >= endo THEN RETURN 0.
      msb = SELF.U8(p); p += 1
      skip = BAND(BSHIFT(msb, 7), 0FF00h) + BAND(skip, 7Fh) + 80h * BAND(msb, 1)
    END
    IF p + skip > endo THEN RETURN 0.
    outp.Append(SELF.buf[p+1 : p+skip]); p += skip
    IF p >= endo THEN BREAK.
    rep = SELF.U8(p-1)                       ! last literal byte
    cnt = SELF.U8(p); p += 1
    IF cnt > 7Fh
      IF p >= endo THEN RETURN 0.
      msb = SELF.U8(p); p += 1
      cnt = BAND(BSHIFT(msb, 7), 0FF00h) + BAND(cnt, 7Fh) + 80h * BAND(msb, 1)
    END
    outp.Append(ALL(CHR(rep), cnt))
  END
  RETURN 1

tpsSchema.Walk PROCEDURE()
t        LONG
ofs      LONG
endo     LONG
pos      LONG
psize    LONG
pusize   LONG
recs     LONG
flags    LONG
page     StringTheory
pg       &STRING
plen     LONG
rp       LONG                                   ! cursor inside page data
rflags   LONG
rlen     LONG
hlen     LONG
copy     LONG
prev     StringTheory                           ! previous record data
cur      StringTheory
hdr      STRING(16)
blk      LONG
parts    QUEUE
Blk        LONG
Data       &StringTheory
         END
seenTbl  LONG
i        LONG
maxblk   LONG
merged   StringTheory
  CODE
  LOOP t = 0 TO 59
    ofs  = BSHIFT(SELF.U32(20h + t*4), 8) + 200h
    endo = BSHIFT(SELF.U32(110h + t*4), 8) + 200h
    IF (ofs = 200h AND endo = 200h) OR ofs >= SELF.size THEN CYCLE.
    IF endo > SELF.size THEN endo = SELF.size.
    pos = ofs
    LOOP WHILE pos + 13 <= endo
      IF SELF.U32(pos) <> pos                   ! not a page start: scan forward on 0x100 boundaries
        pos = BAND(pos, 0FFFFFF00h) + 100h
        CYCLE
      END
      psize  = SELF.U16(pos+4); pusize = SELF.U16(pos+6); recs = SELF.U16(pos+10); flags = SELF.U8(pos+12)
      IF psize < 13 OR pos + psize > endo THEN RETURN SELF.Bad('page size out of range at ' & pos).
      IF flags = 0
        page.Free()
        IF psize <> pusize
          IF NOT SELF.DeRle(pos+13, psize-13, page) THEN RETURN SELF.Bad('bad RLE data in page at ' & pos).
          IF page.Length() <> pusize - 13 THEN RETURN SELF.Bad('decompressed size mismatch in page at ' & pos).
        ELSE
          page.SetValue(SELF.buf[pos+14 : pos+psize])
        END
        pg &= page.valueptr; plen = page.Length()
        rp = 1; prev.Free()
        LOOP i = 1 TO recs
          IF rp > plen THEN RETURN SELF.Bad('page declares ' & recs & ' records but data ends after ' & (i-1)).
          rflags = VAL(pg[rp]); rp += 1
          IF BAND(rflags, 80h)
            IF rp + 1 > plen THEN RETURN SELF.Bad('record header truncated').
            rlen = VAL(pg[rp]) + VAL(pg[rp+1])*256; rp += 2
          END
          IF BAND(rflags, 40h)
            IF rp + 1 > plen THEN RETURN SELF.Bad('record header truncated').
            hlen = VAL(pg[rp]) + VAL(pg[rp+1])*256; rp += 2
          END
          copy = BAND(rflags, 3Fh)
          IF i = 1 AND BAND(rflags, 0C0h) <> 0C0h THEN RETURN SELF.Bad('first record on page lacks 0xC0 header flags').
          IF copy > prev.Length() OR rlen < copy OR rp + rlen - copy - 1 > plen THEN RETURN SELF.Bad('record length exceeds page').
          cur.SetValue(CHOOSE(copy > 0, prev.Sub(1, copy), '') & pg[rp : rp + rlen - copy - 1])
          rp += rlen - copy
          prev.SetValue(cur.GetValue())
          IF hlen >= 7 AND VAL(cur.valueptr[1]) <> 0FEh AND VAL(cur.valueptr[5]) = 0FAh
            hdr = cur.Sub(1, hlen)
            blk = VAL(hdr[6]) + VAL(hdr[7])*256
            seenTbl = VAL(hdr[4]) + VAL(hdr[3])*256 + VAL(hdr[2])*65536 + VAL(hdr[1])*16777216
            IF NOT SELF.HaveTable THEN SELF.TableNo = seenTbl; SELF.HaveTable = 1.
            IF seenTbl <> SELF.TableNo
              SELF.Err = 'DEFINITION_UNREADABLE'
              SELF.ErrMsg = 'File holds more than one table (' & SELF.TableNo & ' and ' & seenTbl & '); multi-table TPS files are not supported'
              LOOP i = 1 TO RECORDS(parts); GET(parts, i); DISPOSE(parts.Data); END
              RETURN 2
            END
            parts.Blk = blk; GET(parts, parts.Blk)
            IF ERRORCODE()
              parts.Blk = blk; parts.Data &= NEW StringTheory
              parts.Data.SetValue(cur.Sub(hlen+1, rlen-hlen)); ADD(parts, parts.Blk)
              IF blk > maxblk THEN maxblk = blk.
            END
          END
        END
      END
      pos += psize
      IF SELF.Overrun THEN RETURN SELF.Bad('read past end of file while walking pages').
    END
  END
  IF RECORDS(parts) = 0
    SELF.Err = 'DEFINITION_UNREADABLE'; SELF.ErrMsg = 'No table definition record found; run TPSFix'; RETURN 2
  END
  LOOP i = 0 TO maxblk
    parts.Blk = i; GET(parts, parts.Blk)
    IF ERRORCODE()
      SELF.Err = 'DEFINITION_UNREADABLE'; SELF.ErrMsg = 'Definition block ' & i & ' missing'; RETURN 2
    END
    merged.Append(parts.Data.GetValue())
  END
  SELF.Def &= NEW STRING(merged.Length())
  SELF.Def = merged.GetValue()
  LOOP i = 1 TO RECORDS(parts); GET(parts, i); DISPOSE(parts.Data); END
  RETURN 0

! ---- Task 4: definition parser and DESCRIBE parity ----

SchFieldOffsetEnd PROCEDURE(tpsSchema s, LONG i)
  CODE
  GET(s.Fields, i)
  RETURN s.Fields.Offset + s.Fields.Bytes

SchFieldOffsetOf PROCEDURE(tpsSchema s, LONG i)
  CODE
  GET(s.Fields, i)
  RETURN s.Fields.Offset

tpsSchema.Parse PROCEDURE()
o       LONG
nF      LONG
nM      LONG
nK      LONG
i       LONG
j       LONG
full    STRING(128)
cpos    LONG
mask    STRING(64)
kflags  LONG
nComp   LONG
fno     LONG
cflag   LONG
saveBuf &STRING
saveSz  LONG
target  LONG
myOfs   LONG
groupEnd LONG
  CODE
  saveBuf &= SELF.buf; saveSz = SELF.size; SELF.Overrun = 0
  SELF.buf &= SELF.Def; SELF.size = LEN(SELF.Def)
  SELF.DriverVer = SELF.U16(0); SELF.RecLen = SELF.U16(2)
  nF = SELF.U16(4); nM = SELF.U16(6); nK = SELF.U16(8); o = 10
  LOOP i = 1 TO nF
    CLEAR(SELF.Fields)
    SELF.Fields.Nbr = i
    SELF.Fields.TpsType = SELF.U8(o); o += 1
    SELF.Fields.Offset  = SELF.U16(o); o += 2
    full = SELF.ZStr(o)
    cpos = INSTRING(':', full, 1, 1)
    IF cpos
      IF SELF.Prefix = '' THEN SELF.Prefix = SUB(full, 1, cpos-1).
      SELF.Fields.Label = SUB(full, cpos+1, LEN(CLIP(full))-cpos)
    ELSE
      SELF.Fields.Label = full
    END
    SELF.Fields.Elements = SELF.U16(o); o += 2
    SELF.Fields.Bytes    = SELF.U16(o); o += 2
    SELF.Fields.Over     = CHOOSE(SELF.U16(o) = 1, -1, 0); o += 2     ! resolved below
    o += 2                                                              ! ordinal, redundant
    IF SELF.Fields.Elements < 1 THEN SELF.Fields.Elements = 1.
    CASE SELF.Fields.TpsType
    OF 01h ; SELF.Fields.Type = 'BYTE'
    OF 02h ; SELF.Fields.Type = 'SHORT'
    OF 03h ; SELF.Fields.Type = 'USHORT'
    OF 04h ; SELF.Fields.Type = 'DATE'
    OF 05h ; SELF.Fields.Type = 'TIME'
    OF 06h ; SELF.Fields.Type = 'LONG'
    OF 07h ; SELF.Fields.Type = 'ULONG'
    OF 08h ; SELF.Fields.Type = 'SREAL'
    OF 09h ; SELF.Fields.Type = 'REAL'
    OF 0Ah ; SELF.Fields.Type = 'DECIMAL'
             SELF.Fields.Places = SELF.U8(o); SELF.Fields.Digits = SELF.U8(o+1); o += 2
             SELF.Fields.Size = 2 * SELF.Fields.Digits - 1  ! the file stores packed-decimal storage bytes, not digit count: bytes=(digits+2)/2
             ! No PDECIMAL in this corpus (the driver rejects it at CREATE); IsPacked stays 0.
    OF 12h OROF 13h OROF 14h
             SELF.Fields.Type = CHOOSE(SELF.Fields.TpsType = 12h, 'STRING', CHOOSE(SELF.Fields.TpsType = 13h, 'CSTRING', 'PSTRING'))
             SELF.Fields.Size = SELF.U16(o); o += 2
             mask = SELF.ZStr(o)
             IF mask = '' THEN o += 1 ELSE SELF.Fields.Picture = mask.   ! empty mask: file carries one stray NUL past ZStr's own terminator
    OF 16h ; SELF.Fields.Type = 'GROUP'
    ELSE
      SELF.Err = 'UNSUPPORTED_FIELD_TYPE'
      SELF.ErrMsg = 'Field ' & CLIP(SELF.Fields.Label) & ' has TPS type code ' & SELF.Fields.TpsType & ' which tpscli does not support'
      SELF.buf &= saveBuf; SELF.size = saveSz
      RETURN 2
    END
    IF SELF.Fields.Size = 0 AND SELF.Fields.Elements > 0    ! DynFile.Size for a scalar/GROUP field: bytes per element
      SELF.Fields.Size = SELF.Fields.Bytes / SELF.Fields.Elements
    END
    ADD(SELF.Fields)
  END
  ! group membership, member counts, OVER targets
  LOOP i = 1 TO RECORDS(SELF.Fields)
    GET(SELF.Fields, i)
    IF SELF.Fields.Type = 'GROUP'
      SELF.Fields.Fields = 0
      groupEnd = SELF.Fields.Offset + SELF.Fields.Bytes   ! captured before the inner GET moves the cursor
      LOOP j = i+1 TO RECORDS(SELF.Fields)
        GET(SELF.Fields, j)
        IF SELF.Fields.Offset >= groupEnd THEN BREAK.
        ! nearest enclosing wins: a later (inner) group has the larger number
        IF SELF.Fields.Parent = 0 OR SELF.Fields.Parent < i THEN SELF.Fields.Parent = i; PUT(SELF.Fields).
        GET(SELF.Fields, i); SELF.Fields.Fields += 1; PUT(SELF.Fields)
      END
    END
    GET(SELF.Fields, i)
    IF SELF.Fields.Over = -1
      target = 0; myOfs = SELF.Fields.Offset
      LOOP j = i-1 TO 1 BY -1
        GET(SELF.Fields, j)
        IF SELF.Fields.Offset = myOfs THEN target = j; BREAK.
      END
      GET(SELF.Fields, i); SELF.Fields.Over = target; PUT(SELF.Fields)
      IF target = 0
        DO Restore
        RETURN SELF.Bad('OVER field ' & CLIP(SELF.Fields.Label) & ' has no field at its offset')
      END
    END
  END
  LOOP i = 1 TO nM
    CLEAR(SELF.Memos); SELF.Memos.Nbr = i
    full = SELF.ZStr(o)
    IF full = ''
      IF SELF.U8(o) <> 1
        DO Restore
        RETURN SELF.Bad('memo entry marker byte is not 0x01')
      END
      o += 1
    END
    full = SELF.ZStr(o)
    cpos = INSTRING(':', full, 1, 1)
    SELF.Memos.Label = CHOOSE(cpos > 0, SUB(full, cpos+1, LEN(CLIP(full))-cpos), full)
    SELF.Memos.Bytes = SELF.U16(o); o += 2
    SELF.Memos.Flags = SELF.U16(o); o += 2
    SELF.Memos.IsBlob = CHOOSE(BAND(SELF.Memos.Flags, 4) <> 0, 1, 0)
    SELF.Memos.Binary = CHOOSE(BAND(SELF.Memos.Flags, 2) <> 0, 1, 0)   ! bit 0x02 distinguishes BINARY (Notes=0x1, Bin=0x3, Pic/BLOB=0x5)
    ADD(SELF.Memos)
  END
  LOOP i = 1 TO nK
    CLEAR(SELF.Keys); SELF.Keys.Nbr = i
    full = SELF.ZStr(o)
    IF full = ''
      IF SELF.U8(o) <> 1
        DO Restore
        RETURN SELF.Bad('key entry marker byte is not 0x01')
      END
      o += 1
    END
    full = SELF.ZStr(o)
    cpos = INSTRING(':', full, 1, 1)
    SELF.Keys.Label = CHOOSE(cpos > 0, SUB(full, cpos+1, LEN(CLIP(full))-cpos), full)
    kflags = SELF.U8(o); o += 1
    SELF.Keys.Flags   = kflags
    SELF.Keys.Dup     = BAND(kflags, 01h) / 01h
    SELF.Keys.Opt     = BAND(kflags, 02h) / 02h
    SELF.Keys.NoCase  = BAND(kflags, 04h) / 04h
    SELF.Keys.Primary = BAND(kflags, 10h) / 10h
    SELF.Keys.IsKey   = CHOOSE(BAND(kflags, 60h) = 0, 1, 0)
    IF NOT SELF.Keys.IsKey THEN SELF.Keys.Dup = 1.        ! INDEX always allows duplicates
    nComp = SELF.U16(o); o += 2
    LOOP j = 1 TO nComp
      fno = SELF.U16(o); cflag = SELF.U16(o+2); o += 4
      CLEAR(SELF.Comps)
      SELF.Comps.KeyNbr = i; SELF.Comps.FieldNbr = fno + 1; SELF.Comps.Descending = CHOOSE(cflag <> 0, 1, 0); SELF.Comps.Rank = j
      ADD(SELF.Comps)
    END
    ADD(SELF.Keys)
  END
  ! every key component must name a real field ordinal; SchemaDumpJson/DescribeJson GET(Fields, FieldNbr)
  ! without re-checking, so a bad ordinal is caught here rather than trusted downstream.
  LOOP i = 1 TO RECORDS(SELF.Comps)
    GET(SELF.Comps, i)
    IF SELF.Comps.FieldNbr < 1 OR SELF.Comps.FieldNbr > RECORDS(SELF.Fields)
      DO Restore
      RETURN SELF.Bad('key ' & SELF.Comps.KeyNbr & ' component ' & SELF.Comps.Rank & ' names field ordinal ' & SELF.Comps.FieldNbr & ', outside 1..' & RECORDS(SELF.Fields))
    END
  END
  SELF.buf &= saveBuf; SELF.size = saveSz
  IF SELF.Overrun THEN RETURN SELF.Bad('definition record shorter than its field, memo and key counts imply').
  RETURN 0
Restore ROUTINE
  SELF.buf &= saveBuf; SELF.size = saveSz

tpsSchema.FindField PROCEDURE(STRING label)
i    LONG
want STRING(64)
  CODE
  want = UPPER(CLIP(label))
  LOOP i = 1 TO RECORDS(SELF.Fields)
    GET(SELF.Fields, i)
    IF UPPER(CLIP(SELF.Fields.Label)) = want THEN RETURN i.
  END
  RETURN 0

tpsSchema.SchemaDumpJson PROCEDURE(tpsOut o)
js    StringTheory
i     LONG
j     LONG
full  STRING(80)
cfirst BYTE
  CODE
  js.SetValue('{{ "file": ' & o.JStr(CLIP(SELF.Path)) & ', "fields": [')
  LOOP i = 1 TO RECORDS(SELF.Fields)
    GET(SELF.Fields, i)
    full = CLIP(SELF.Prefix) & ':' & CLIP(SELF.Fields.Label)
    js.Append(CHOOSE(i = 1, '', ',') & '{{"nbr":' & SELF.Fields.Nbr & ',"label":' & o.JStr(CLIP(full)) |
      & ',"type":' & o.JStr(CLIP(SELF.Fields.Type)) |
      & ',"size":' & SELF.Fields.Size & ',"places":' & SELF.Fields.Places |
      & ',"dim":' & CHOOSE(SELF.Fields.Elements > 1, SELF.Fields.Elements, 0) & ',"over":' & SELF.Fields.Over |
      & ',"fields":' & SELF.Fields.Fields & ',"picture":' & o.JStr(CLIP(SELF.Fields.Picture)) & '}')
  END
  js.Append('], "memos": [')
  LOOP i = 1 TO RECORDS(SELF.Memos)
    GET(SELF.Memos, i)
    full = CLIP(SELF.Prefix) & ':' & CLIP(SELF.Memos.Label)
    js.Append(CHOOSE(i = 1, '', ',') & '{{"nbr":' & SELF.Memos.Nbr & ',"label":' & o.JStr(CLIP(full)) |
      & ',"type":' & o.JStr(CHOOSE(SELF.Memos.IsBlob = 1, 'B', 'M')) |
      & ',"binary":' & SELF.Memos.Binary & ',"size":' & SELF.Memos.Bytes & ',"flags":' & SELF.Memos.Flags & '}')
  END
  js.Append('], "keys": [')
  LOOP i = 1 TO RECORDS(SELF.Keys)
    GET(SELF.Keys, i)
    full = CLIP(SELF.Prefix) & ':' & CLIP(SELF.Keys.Label)
    js.Append(CHOOSE(i = 1, '', ',') & '{{"nbr":' & SELF.Keys.Nbr & ',"label":' & o.JStr(CLIP(full)) |
      & ',"type":' & o.JStr(CHOOSE(SELF.Keys.IsKey = 1, 'K', 'I')) |
      & ',"dup":' & SELF.Keys.Dup & ',"primary":' & SELF.Keys.Primary |
      & ',"nocase":' & SELF.Keys.NoCase & ',"opt":' & SELF.Keys.Opt & ',"flags":' & SELF.Keys.Flags & ',"components":[')
    cfirst = 1
    LOOP j = 1 TO RECORDS(SELF.Comps)
      GET(SELF.Comps, j)
      IF SELF.Comps.KeyNbr <> SELF.Keys.Nbr THEN CYCLE.
      GET(SELF.Fields, SELF.Comps.FieldNbr)
      full = CLIP(SELF.Prefix) & ':' & CLIP(SELF.Fields.Label)
      js.Append(CHOOSE(cfirst, '', ',') & '{{"label":' & o.JStr(CLIP(full)) & ',"nbr":' & SELF.Comps.FieldNbr |
        & ',"asc":' & CHOOSE(SELF.Comps.Descending = 1, 0, 1) & ',"rank":' & SELF.Comps.Rank & '}')
      cfirst = 0
    END
    js.Append(']}')
  END
  js.Append('] }')
  RETURN js.GetValue()

tpsSchema.DescribeJson PROCEDURE(tpsOut o, LONG records)
js    StringTheory
i     LONG
j     LONG
first BYTE
  CODE
  js.SetValue('{{ "ok": true, "op": "describe", "file": ' & o.JStr(CLIP(SELF.Path)) |
    & ', "encrypted": ' & CHOOSE(SELF.Encrypted = 1, 'true', 'false'))
  IF records >= 0 THEN js.Append(', "records": ' & records).
  js.Append(', "columns": [')
  SchEmitFields(SELF, js, 0, '')
  IF RECORDS(SELF.Fields) > 0 AND RECORDS(SELF.Memos) > 0 THEN js.Append(',').
  LOOP i = 1 TO RECORDS(SELF.Memos)
    GET(SELF.Memos, i)
    IF i > 1 THEN js.Append(',').
    js.Append('{{"name":' & o.JStr(CLIP(SELF.Memos.Label)) & ',"type":' & o.JStr(CHOOSE(SELF.Memos.IsBlob = 1, 'BLOB', 'MEMO')) |
      & ',"size":' & SELF.Memos.Bytes)
    IF SELF.Memos.IsBlob = 1 THEN js.Append(',"encoding":"base64"').
    js.Append('}')
  END
  js.Append('], "keys": [')
  LOOP i = 1 TO RECORDS(SELF.Keys)
    GET(SELF.Keys, i)
    IF i > 1 THEN js.Append(',').
    js.Append('{{"name":' & o.JStr(CLIP(SELF.Keys.Label)) & ',"primary":' & CHOOSE(SELF.Keys.Primary = 1, 'true', 'false') |
      & ',"unique":' & CHOOSE(SELF.Keys.Dup = 1, 'false', 'true'))
    IF SELF.Keys.NoCase = 1 THEN js.Append(',"nocase":true').
    IF SELF.Keys.Opt = 1 THEN js.Append(',"optional":true').
    js.Append(',"components":[')
    first = 1
    LOOP j = 1 TO RECORDS(SELF.Comps)
      GET(SELF.Comps, j)
      IF SELF.Comps.KeyNbr <> SELF.Keys.Nbr THEN CYCLE.
      GET(SELF.Fields, SELF.Comps.FieldNbr)
      IF NOT first THEN js.Append(',').
      first = 0
      js.Append('{{"col":' & o.JStr(CLIP(SELF.Fields.Label)) & ',"asc":' & CHOOSE(SELF.Comps.Descending = 1, 'false', 'true') & '}')
    END
    js.Append(']}')
  END
  js.Append('], "complete": true }')
  RETURN js.GetValue()

SchEmitFields PROCEDURE(tpsSchema s, StringTheory js, LONG parentNbr, STRING dotted)
i     LONG
first BYTE
  CODE
  first = 1
  LOOP i = 1 TO RECORDS(s.Fields)
    GET(s.Fields, i)
    IF s.Fields.Parent <> parentNbr THEN CYCLE.
    IF NOT first THEN js.Append(',').
    first = 0
    SchEmitOneField(s, js, i, dotted)
  END

SchEmitOneField PROCEDURE(tpsSchema s, StringTheory js, LONG idx, STRING dotted)
name STRING(80)
nbr  LONG
  CODE
  GET(s.Fields, idx)
  nbr = s.Fields.Nbr
  name = CHOOSE(dotted = '', CLIP(s.Fields.Label), CLIP(dotted) & '.' & CLIP(s.Fields.Label))
  js.Append('{{"name":"' & CLIP(name) & '","type":"' & CLIP(s.Fields.Type) & '"')
  IF s.Fields.Elements > 1 THEN js.Append(',"dim":' & s.Fields.Elements).
  CASE s.Fields.Type
  OF 'DECIMAL'
    js.Append(',"size":' & s.Fields.Size & ',"places":' & s.Fields.Places)
  OF 'STRING' OROF 'CSTRING' OROF 'PSTRING'
    js.Append(',"size":' & s.Fields.Size)
  OF 'GROUP'
    js.Append(',"members":[')
    SchEmitFields(s, js, nbr, name)
    js.Append(']')
  END
  js.Append('}')
