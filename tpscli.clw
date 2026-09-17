  PROGRAM
  INCLUDE('StringTheory.inc'),ONCE
  INCLUDE('tpsOut.inc'),ONCE
  INCLUDE('tpsSchema.inc'),ONCE
  INCLUDE('tpsSql.inc'),ONCE
  INCLUDE('tpsExec.inc'),ONCE
  MAP
    ParseArgs()
    DumpDef()
    Dispatch()
  END

TpsDrv     FILE,DRIVER('TOPSPEED'),NAME('tpsdrv.tps'),PRE(TD)
Record       RECORD
Dummy          BYTE
             END
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
  Dispatch()

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

! Real dispatch (Task 6): tokenize + parse the statement head, load the schema the path names,
! then either run DESCRIBE (Build+Open+DescribeJson) or finish parsing the body and either
! report --parse-only success or hand off to the executor (Task 7 onward).
Dispatch  PROCEDURE()
Stmt      tpsSql
Sc        tpsSchema
Exec      tpsExec
rc        LONG
opName    STRING(12)
exitCode  LONG
errJs     StringTheory
  CODE
  Stmt.Sch &= Sc
  rc = Stmt.Parse(Opt.Sql)
  IF rc <> 0
    CASE Stmt.Op
    OF OP:Describe ; opName = 'describe'
    OF OP:Select   ; opName = 'select'
    OF OP:Insert   ; opName = 'insert'
    OF OP:Update   ; opName = 'update'
    OF OP:Delete   ; opName = 'delete'
    ELSE            ; opName = ''
    END
    exitCode = CHOOSE(Stmt.Err = 'VALUE_OUT_OF_RANGE', 3, 1)
    errJs.SetValue('{{ "ok": false, "op": ' & CHOOSE(CLIP(opName) = '', 'null', Out.JStr(CLIP(opName))) & ', "error": {{ "code": ' & Out.JStr(CLIP(Stmt.Err)) & ', "message": ' & Out.JStr(CLIP(Stmt.ErrMsg)) & ', "position": ' & Stmt.ErrPos & ', "token": ' & Out.JStr(CLIP(Stmt.ErrToken)))
    IF Stmt.Err = 'UNKNOWN_COLUMN' OR Stmt.Err = 'VALUE_OUT_OF_RANGE' THEN errJs.Append(', "column": ' & Out.JStr(CLIP(Stmt.ErrColumn))).
    errJs.Append(' }, "outcome": "none", "complete": true }')
    IF Opt.Table THEN Out.Line(CLIP(Stmt.Err) & ': ' & CLIP(Stmt.ErrMsg)) ELSE Out.Line(errJs.GetValue()).
    HALT(exitCode)
  END
  CASE Stmt.Op
  OF OP:Describe ; opName = 'describe'
  OF OP:Select   ; opName = 'select'
  OF OP:Insert   ; opName = 'insert'
  OF OP:Update   ; opName = 'update'
  OF OP:Delete   ; opName = 'delete'
  END

  rc = Sc.Load(CLIP(Stmt.Path), Opt.Owner)
  IF rc = 0 THEN rc = Sc.Parse().
  IF rc <> 0
    IF Opt.Table
      Out.Line(CLIP(Sc.Err) & ': ' & CLIP(Sc.ErrMsg))
    ELSE
      Out.Line('{{ "ok": false, "op": ' & Out.JStr(CLIP(opName)) & ', "error": {{ "code": ' & Out.JStr(CLIP(Sc.Err)) & ', "message": ' & Out.JStr(CLIP(Sc.ErrMsg)) & ' }, "complete": true }')
    END
    HALT(2)
  END

  IF Stmt.Op = OP:Describe
    IF Opt.WantDumpSchema
      Out.Line(Sc.SchemaDumpJson(Out))
      HALT(0)
    END
    rc = Sc.Build(TpsDrv)
    IF rc = 0 THEN rc = Sc.Open().
    IF rc <> 0
      IF Opt.Table
        Out.Line(CLIP(Sc.Err) & ': ' & CLIP(Sc.ErrMsg))
      ELSE
        Out.Line('{{ "ok": false, "op": "describe", "error": {{ "code": ' & Out.JStr(CLIP(Sc.Err)) & ', "message": ' & Out.JStr(CLIP(Sc.ErrMsg)) & ' }, "complete": true }')
      END
      HALT(2)
    END
    Out.Line(Sc.DescribeJson(Out, RECORDS(Sc.F)))
    CLOSE(Sc.F)
    HALT(0)
  END

  rc = Stmt.ParseBody()
  IF rc <> 0
    exitCode = CHOOSE(Stmt.Err = 'VALUE_OUT_OF_RANGE', 3, 1)
    errJs.SetValue('{{ "ok": false, "op": ' & Out.JStr(CLIP(opName)) & ', "error": {{ "code": ' & Out.JStr(CLIP(Stmt.Err)) & ', "message": ' & Out.JStr(CLIP(Stmt.ErrMsg)) & ', "position": ' & Stmt.ErrPos & ', "token": ' & Out.JStr(CLIP(Stmt.ErrToken)))
    IF Stmt.Err = 'UNKNOWN_COLUMN' OR Stmt.Err = 'VALUE_OUT_OF_RANGE' THEN errJs.Append(', "column": ' & Out.JStr(CLIP(Stmt.ErrColumn))).
    errJs.Append(' }, "outcome": "none", "complete": true }')
    IF Opt.Table THEN Out.Line(CLIP(Stmt.Err) & ': ' & CLIP(Stmt.ErrMsg)) ELSE Out.Line(errJs.GetValue()).
    HALT(exitCode)
  END

  IF Opt.ParseOnly
    Out.Line('{{ "ok": true, "op": ' & Out.JStr(CLIP(opName)) & ', "parse_only": true, "complete": true }')
    HALT(0)
  END

  rc = Sc.Build(TpsDrv)
  IF rc = 0 THEN rc = Sc.Open().
  IF rc <> 0
    IF Opt.Table
      Out.Line(CLIP(Sc.Err) & ': ' & CLIP(Sc.ErrMsg))
    ELSE
      Out.Line('{{ "ok": false, "op": ' & Out.JStr(CLIP(opName)) & ', "error": {{ "code": ' & Out.JStr(CLIP(Sc.Err)) & ', "message": ' & Out.JStr(CLIP(Sc.ErrMsg)) & ' }, "complete": true }')
    END
    HALT(2)
  END

  Exec.Sch &= Sc; Exec.Sql &= Stmt; Exec.Out &= Out
  Exec.LimitDefault = Opt.LimitDefault; Exec.WantTable = Opt.Table
  rc = Exec.Run()
  CLOSE(Sc.F)
  HALT(rc)
