  PROGRAM
  INCLUDE('StringTheory.inc'),ONCE
  INCLUDE('tpsOut.inc'),ONCE
  INCLUDE('tpsSchema.inc'),ONCE
  MAP
    ParseArgs()
    DumpDef()
    DoDescribe()
  END

Out        tpsOut
Opt        GROUP
Owner        STRING(64)
Table        BYTE
ParseOnly    BYTE
LimitDefault LONG(1000)
WantDumpDef  BYTE
DumpDefPath  STRING(260)
WantDumpSchema BYTE
Sql          &STRING
           END
TPSCLI_VERSION  EQUATE('0.1.0')

  CODE
  Out.Init()
  ParseArgs()
  IF Opt.WantDumpDef THEN DumpDef().
  IF Opt.Sql &= NULL OR LEN(CLIP(Opt.Sql)) = 0
    Out.Fail('SYNTAX', 'No SQL statement given. Pass it as the first argument or on stdin.', 1)
  END
  IF UPPER(SUB(LEFT(Opt.Sql), 1, 8)) = 'DESCRIBE' THEN DoDescribe().
  ! Tasks 6-9 replace this line with parse + execute.
  Out.Fail('SYNTAX', 'Parser not implemented yet', 1)

ParseArgs  PROCEDURE()
n     LONG
a     &STRING
seen  BYTE
x     LONG
y     LONG
  CODE
  LOOP n = 1 TO 4096                  ! COMMAND(n) returns '' past the last argument, which ends the loop; 4096 is a guard, not a cutoff
    a &= NEW STRING(LEN(CLIP(COMMAND(n))))
    a = COMMAND(n)
    IF a = '' THEN DISPOSE(a); BREAK.
    IF n = 4096 THEN Out.Fail('SYNTAX', 'Too many arguments', 1).
    CASE LOWER(CLIP(a))
    OF '--owner'
      n += 1
      Opt.Owner = COMMAND(n)
      IF Opt.Owner = '' THEN Out.Fail('SYNTAX', '--owner needs a value', 1).
    OF '--table'          ; Opt.Table = 1
    OF '--parse-only'     ; Opt.ParseOnly = 1
    OF '--limit-default'
      n += 1
      IF NOT MATCH(CLIP(COMMAND(n)), '^[0-9]+$', Match:Regular) OR LEN(CLIP(COMMAND(n))) > 10 OR COMMAND(n) > 2147483647
        Out.Fail('SYNTAX', '--limit-default needs a non-negative integer up to 2147483647', 1)
      END
      Opt.LimitDefault = COMMAND(n)
    OF '--version'
      Out.Line('{{ "ok": true, "op": null, "version": "' & TPSCLI_VERSION & '", "complete": true }')
      HALT(0)
    OF '--selftest'
      x = 2147483647; x += 1;  Out.Line('wrap=' & x)
      y = -2147483648; y -= 1; Out.Line('wrap2=' & y)
      Out.Line('bshift=' & BSHIFT(1, 31))
      HALT(0)
    OF '--dump-def'
      n += 1
      Opt.DumpDefPath = COMMAND(n)
      IF Opt.DumpDefPath = '' THEN Out.Fail('SYNTAX', '--dump-def needs a path', 1).
      Opt.WantDumpDef = 1
      seen = 1
    OF '--dump-schema'    ; Opt.WantDumpSchema = 1
    ELSE
      IF SUB(a, 1, 2) = '--' THEN Out.Fail('SYNTAX', 'Unknown option ' & CLIP(a), 1).
      IF seen THEN Out.Fail('SYNTAX', 'Only one statement per invocation', 1).
      seen = 1
      Opt.Sql &= a; a &= NULL; CYCLE
    END
    DISPOSE(a)
  END
  IF NOT seen
    Opt.Sql &= NEW STRING(LEN(CLIP(Out.ReadStdin())))
    Opt.Sql = Out.ReadStdin()   ! second call returns the buffered copy, see tpsOut.ReadStdin
  END

DumpDef  PROCEDURE()
Sch    tpsSchema
rc     LONG
n      LONG
pos    LONG
c      BYTE
hexln  StringTheory
  CODE
  rc = Sch.Load(Opt.DumpDefPath, Opt.Owner)
  IF rc <> 0 THEN Out.Fail(CLIP(Sch.Err), CLIP(Sch.ErrMsg), 2).
  n = LEN(Sch.Def)
  Out.Line('len=' & n & ' table=' & Sch.TableNo & ' encrypted=' & Sch.Encrypted)
  pos = 1
  LOOP WHILE pos <= n
    hexln.Free()
    LOOP WHILE pos <= n AND hexln.Length() < 64
      c = VAL(Sch.Def[pos])
      hexln.Append(SUB('0123456789abcdef', BSHIFT(c,-4)+1, 1) & SUB('0123456789abcdef', BAND(c,0Fh)+1, 1))
      pos += 1
    END
    Out.Line(hexln.GetValue())
  END
  HALT(0)

! Temporary DESCRIBE dispatch (Task 4); Task 6 replaces this with the real parser.
DoDescribe  PROCEDURE()
sql   StringTheory
lb    LONG
rb    LONG
path  STRING(260)
sch   tpsSchema
rc    LONG
  CODE
  sql.SetValue(Opt.Sql)
  lb = INSTRING('[', sql.GetValue(), 1, 1)
  IF lb > 0 THEN rb = INSTRING(']', sql.GetValue(), 1, lb+1).
  IF lb = 0 OR rb = 0
    Out.Fail('SYNTAX', 'DESCRIBE requires a bracketed file path', 1)
  END
  path = sql.Sub(lb+1, rb-lb-1)
  rc = sch.Load(CLIP(path), Opt.Owner)
  IF rc = 0 THEN rc = sch.Parse().
  IF rc <> 0
    Out.Line('{{ "ok": false, "op": "describe", "error": {{ "code": ' & Out.JStr(CLIP(sch.Err)) & ', "message": ' & Out.JStr(CLIP(sch.ErrMsg)) & ' }, "complete": true }')
    HALT(2)
  END
  IF Opt.WantDumpSchema
    Out.Line(sch.SchemaDumpJson(Out))
  ELSE
    Out.Line(sch.DescribeJson(Out, -1))
  END
  HALT(0)
