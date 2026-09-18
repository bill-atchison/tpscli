  OMIT('_EndTpsSql_',_TpsSqlPresent_)
_TpsSqlPresent_ EQUATE(1)
  INCLUDE('StringTheory.inc'),ONCE
  INCLUDE('tpsSchema.inc'),ONCE

TK:Ident  EQUATE(1)
TK:Num    EQUATE(2)
TK:Str    EQUATE(3)
TK:Op     EQUATE(4)
TK:Path   EQUATE(5)
TK:Eof    EQUATE(6)

OP:Describe EQUATE(1)
OP:Select   EQUATE(2)
OP:Insert   EQUATE(3)
OP:Update   EQUATE(4)
OP:Delete   EQUATE(5)

TokQ      QUEUE,TYPE
Kind        BYTE
Text        &STRING                ! exact-length token text, NEW'd by SqlTokAdd, disposed in SqlTokFree
Len         LONG                   ! true length of Text; 0 means the empty token, Text is then a 1-byte placeholder
Pos         LONG
          END
ColQ      QUEUE,TYPE               ! a resolved column reference
Path        STRING(128)            ! canonical qualified path, upper (ADDR.GEO.LAT, PHONES[2].KIND)
Prefix      STRING(128)            ! Path minus the last label, used to name expanded leaves
FieldNbr    LONG                   ! 0 for memo
MemoNbr     LONG
GrpElem     LONG                   ! element of an enclosing dimmed group, 0 = none
Elem        LONG                   ! 0 scalar, else 1-based element
Elem2       LONG                   ! second subscript for DIM(a,b) leaves
Expr        STRING(96)             ! Clarion expression text: PRE:LABEL or PRE:LABEL[n] or PRE:LABEL[n,m]
          END

ValQ      QUEUE,TYPE
Kind        BYTE                   ! TK:Num or TK:Str
Text        &STRING                ! exact-length decoded literal, NEW'd by the tokenizer, disposed in Destruct
Len         LONG
          END
OrdQ      QUEUE,TYPE
FieldNbr    LONG
Elem        LONG
Desc        BYTE
          END

tpsSql    CLASS,TYPE,MODULE('tpsSql.clw'),LINK('tpsSql.clw')
Sch         &tpsSchema
Toks        &TokQ
Cur         LONG
Op          BYTE
Path        STRING(260)
Star        BYTE
Cols        &ColQ
Vals        &ValQ
Order       &OrdQ
Where       CSTRING(8192)
HasWhere    BYTE
Limit       LONG
HasLimit    BYTE
Offset      LONG
Err         STRING(24)
ErrMsg      STRING(512)
ErrPos      LONG
ErrToken    STRING(64)
ErrColumn   STRING(128)
Construct   PROCEDURE()
Destruct    PROCEDURE()
Tokenize    PROCEDURE(STRING sql),LONG
ParsePath   PROCEDURE(),LONG                  ! after DESCRIBE/FROM/INTO/UPDATE
Parse       PROCEDURE(STRING sql),LONG        ! statement head only (op + path)
ParseBody   PROCEDURE(),LONG                  ! after schema is loaded
Peek        PROCEDURE(),STRING
PeekKind    PROCEDURE(),BYTE
Take        PROCEDURE(),STRING
Expect      PROCEDURE(STRING word),LONG
ColumnRef   PROCEDURE(*ColQ c),LONG           ! parses IDENT([n])(.IDENT([n]))*
Expr        PROCEDURE(),STRING                ! OR level
ExprAnd     PROCEDURE(),STRING
ExprNot     PROCEDURE(),STRING
ExprCmp     PROCEDURE(),STRING
Literal     PROCEDURE(LONG fieldNbr, LONG memoNbr),STRING   ! typed literal to Clarion expression text
ValidDate   PROCEDURE(STRING s, *LONG clarionDate),BYTE   ! strict YYYY-MM-DD, year 1801..2999, round-trips Y/M/D
ValidTime   PROCEDURE(STRING s, *LONG clarionTime),BYTE   ! HH:MM[:SS[.hh]], all digits, in range
FlatElem    PROCEDURE(ColQ c, SchFieldQ f),LONG       ! single WHAT element index from GrpElem/Elem/Elem2
Fail        PROCEDURE(STRING code, STRING msg),LONG
          END
  _EndTpsSql_
