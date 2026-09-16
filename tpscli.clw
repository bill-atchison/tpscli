  PROGRAM
  INCLUDE('StringTheory.inc'),ONCE
  INCLUDE('tpsOut.inc'),ONCE
  MAP
    ParseArgs()
  END

Out        tpsOut
Opt        GROUP
Owner        STRING(64)
Table        BYTE
ParseOnly    BYTE
LimitDefault LONG(1000)
Sql          &STRING
           END
TPSCLI_VERSION  EQUATE('0.1.0')

  CODE
  Out.Init()
  ParseArgs()
  IF Opt.Sql &= NULL OR LEN(CLIP(Opt.Sql)) = 0
    Out.Fail('SYNTAX', 'No SQL statement given. Pass it as the first argument or on stdin.', 1)
  END
  ! Tasks 6-9 replace this line with parse + execute.
  Out.Fail('SYNTAX', 'Parser not implemented yet', 1)

ParseArgs  PROCEDURE()
n     LONG
a     &STRING
seen  BYTE
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
      IF NOT MATCH(CLIP(COMMAND(n)), '^[0-9]' & CHR(123) & '1,10' & CHR(125) & '$', Match:Regular) OR COMMAND(n) > 2147483647
        Out.Fail('SYNTAX', '--limit-default needs a non-negative integer up to 2147483647', 1)
      END
      Opt.LimitDefault = COMMAND(n)
    OF '--version'
      Out.Line('{ "ok": true, "op": null, "version": "' & TPSCLI_VERSION & '", "complete": true }')
      HALT(0)
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
