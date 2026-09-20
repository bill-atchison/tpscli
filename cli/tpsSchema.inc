  OMIT('_EndTpsSchema_',_TpsSchemaPresent_)
_TpsSchemaPresent_ EQUATE(1)
  INCLUDE('StringTheory.inc'),ONCE
  INCLUDE('DynFile.inc'),ONCE
  INCLUDE('tpsOut.inc'),ONCE

SchFieldQ  QUEUE,TYPE
Nbr          LONG        ! 1-based, definition order
Label        STRING(64)  ! after the colon
TpsType      BYTE
Type         STRING(12)  ! DynFile type text
Offset       LONG
Bytes        LONG        ! total bytes incl. all elements
Elements     LONG        ! DIM, 1 = scalar
Size         LONG        ! DynFile Size
Places       LONG
Digits       LONG        ! DECIMAL: the packed STORAGE BYTE count from the definition, not a digit count; the decoded digit count is Size (= 2*Digits-1)
Fields       LONG        ! GROUP member count (all nesting)
Dim2         LONG        ! second extent for DIM(a,b), 0 otherwise
IsPacked     BYTE        ! PDECIMAL, per Task 4 reconciliation
Over         LONG        ! field nbr overlaid, 0 = none
Parent       LONG        ! enclosing GROUP nbr, 0 = record
Picture      STRING(50)
           END
SchKeyQ    QUEUE,TYPE
Nbr          LONG
Label        STRING(64)
IsKey        BYTE
Dup          BYTE
Opt          BYTE
NoCase       BYTE
Primary      BYTE
Flags        BYTE
           END
SchKeyCompQ QUEUE,TYPE
KeyNbr       LONG
FieldNbr     LONG        ! 1-based SchFieldQ.Nbr
Descending   BYTE
Rank         LONG
           END
WhoQ       QUEUE,TYPE
FieldNbr     LONG
Idx          LONG
           END
SchMemoQ   QUEUE,TYPE
Nbr          LONG
Label        STRING(64)
Bytes        LONG
IsBlob       BYTE
Binary       BYTE
Flags        LONG
           END

tpsDynFile CLASS(DynFile),TYPE,MODULE('tpsSchema.clw'),LINK('tpsSchema.clw')
FixFormat    PROCEDURE(),LONG,PROC       ! shadows the modal one
           END

tpsSchema  CLASS,TYPE,MODULE('tpsSchema.clw'),LINK('tpsSchema.clw')
st           &StringTheory
buf          &STRING
size         LONG
Err          STRING(24)
ErrMsg       STRING(255)
Def          &STRING
Encrypted    BYTE
Overrun      BYTE
HaveTable    BYTE
TableNo      LONG
Path         STRING(260)
Owner        STRING(64)
Prefix       STRING(16)
DriverVer    LONG
RecLen       LONG
Fields       &SchFieldQ
Keys         &SchKeyQ
Comps        &SchKeyCompQ
Memos        &SchMemoQ
Who          &WhoQ
F            &FILE
Dyn          &tpsDynFile
Construct    PROCEDURE()
Destruct     PROCEDURE()
Load         PROCEDURE(STRING path, STRING owner),LONG
U8           PROCEDURE(LONG o),LONG
U16          PROCEDURE(LONG o),LONG
U32          PROCEDURE(LONG o),LONG          ! LE, may be negative
ZStr         PROCEDURE(*LONG o),STRING       ! reads zero-terminated, advances o
Decrypt      PROCEDURE(STRING owner)
Decrypt64    PROCEDURE(LONG o)
Walk         PROCEDURE(),LONG                ! finds and merges 0xFA records
Bad          PROCEDURE(STRING why),LONG      ! sets DEFINITION_UNREADABLE, returns 2
DeRle        PROCEDURE(LONG o, LONG clen, LONG want, StringTheory outp),LONG   ! stops once want bytes are out
Parse        PROCEDURE(),LONG                ! fills Fields/Keys/Comps/Memos from Def
SchemaDumpJson PROCEDURE(tpsOut o),STRING    ! oracle vocabulary, hidden --dump-schema
DescribeJson PROCEDURE(tpsOut o, LONG records),STRING   ! public DESCRIBE shape, spec §4
FindField    PROCEDURE(STRING label),LONG    ! case-insensitive, 0 = not found
Build        PROCEDURE(FILE driver),LONG     ! builds SELF.F through DynFile from Fields/Keys/Comps/Memos
Open         PROCEDURE(),LONG                ! SHARE(SELF.F), maps field numbers to WHAT() indexes into Who
FieldRef     PROCEDURE(LONG fieldNbr, LONG elem),*?   ! null ANY for a bad field number
MemoRef      PROCEDURE(LONG memoNbr),STRING           ! memo/blob content by value; no addressable reference exists
KeyRef       PROCEDURE(LONG keyNbr),*KEY
           END
  _EndTpsSchema_
