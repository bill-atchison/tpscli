  MEMBER()
  INCLUDE('tpsSchema.inc'),ONCE
  MAP
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
