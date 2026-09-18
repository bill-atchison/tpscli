  OMIT('_EndTpsExec_',_TpsExecPresent_)
_TpsExecPresent_ EQUATE(1)
  INCLUDE('tpsSchema.inc'),ONCE
  INCLUDE('tpsSql.inc'),ONCE
  INCLUDE('tpsOut.inc'),ONCE

ConvQ     QUEUE,TYPE               ! validated literal per Sql.Cols entry
Num         DECIMAL(31,15)
Txt         &STRING
TxtLen      LONG
IsNum       BYTE
          END
OutColQ   QUEUE,TYPE
Name        STRING(128)
FieldNbr    LONG
MemoNbr     LONG
GrpElem     LONG                   ! > 0: this leaf sits inside a DIM'd GROUP's GrpElem'th
                                    ! occurrence; WHAT(fieldNbr,elem) cannot reach it (WHAT's
                                    ! dimension parameter only ever selects a field's OWN
                                    ! element, never the enclosing group's - confirmed empirically,
                                    ! see task-7-report.md), so Format() takes the enclosing
                                    ! GROUP's raw bytes via WHAT(groupFieldNbr,GrpElem) instead
                                    ! and slices the leaf out at its relative byte offset.
Elem        LONG                   ! this leaf's own element (0 = scalar), never combined with GrpElem
Type        STRING(12)
          END
! Candidates for update/delete, or the sort buffer for a non-key ORDER BY on SELECT.
! K1..K4/S1..S4 carry NAME() attributes so tpsExec.DoSelect can build a runtime SORT
! spec string (SORT's field-list form requires compile-time labels; SORT's NAME-string
! form accepts a runtime string of NAME() attributes instead, per the Language Reference).
! Named SortQ, not PosQ: a QUEUE,TYPE literally named "PosQ" crashes NEW with an access
! violation (0xC0000005, read near address 4) even with nothing else in the program - a
! reserved-name collision inside Clarion's own runtime, not a bug in this code. Confirmed
! with an isolated repro (bare PROGRAM, single BYTE field, no includes): renaming the type
! is what fixes it, not the field list. See task-7-report.md.
SortQ     QUEUE,TYPE
K1          DECIMAL(31,15),NAME('K1')
S1          STRING(255),NAME('S1')
K2          DECIMAL(31,15),NAME('K2')
S2          STRING(255),NAME('S2')
K3          DECIMAL(31,15),NAME('K3')
S3          STRING(255),NAME('S3')
K4          DECIMAL(31,15),NAME('K4')
S4          STRING(255),NAME('S4')
RowId       STRING(255)
Pos         STRING(512)
          END
tpsExec   CLASS,TYPE,MODULE('tpsExec.clw'),LINK('tpsExec.clw')
Sch         &tpsSchema
Sql         &tpsSql
Out         &tpsOut
LimitDefault LONG                  ! Opt.LimitDefault, set by the caller before Run()
WantTable   BYTE                   ! Opt.Table, set by the caller before Run()
Rows        &StringTheory          ! buffered JSON rows
Warnings    &StringTheory
ErrCode     STRING(24)
ErrCol      STRING(128)
ErrMsg      STRING(512)
Cols        &OutColQ
Conv        &ConvQ
Construct   PROCEDURE()             ! Cols &= NEW OutColQ; Conv &= NEW ConvQ; Rows/Warnings &= NEW StringTheory
Destruct    PROCEDURE()             ! dispose every Conv.Txt, then both queues and the two StringTheory objects
Run         PROCEDURE(),LONG
ExpandCols  PROCEDURE()
AddLeaf     PROCEDURE(LONG fieldNbr, STRING namePrefix, LONG elem)
Format      PROCEDURE(LONG fieldNbr, LONG grpElem, LONG elem),STRING
FormatMemo  PROCEDURE(LONG memoNbr),STRING
Matches     PROCEDURE(),BYTE       ! EVALUATE(Where) on current record
ChooseKey   PROCEDURE(*BYTE reverse),LONG    ! 0 = none matches ORDER BY
DoSelect    PROCEDURE(),LONG
DoInsert    PROCEDURE(),LONG
DoUpdate    PROCEDURE(),LONG
DoDelete    PROCEDURE(),LONG
Validate    PROCEDURE(LONG colIdx),LONG       ! converts Sql.Vals[i] into Conv[i], no buffer access
Assign      PROCEDURE(LONG colIdx)            ! Sql.Cols[i] := Conv[i], after Validate succeeded
Range       PROCEDURE(LONG colIdx, STRING why),LONG   ! sets VALUE_OUT_OF_RANGE, returns 3
Mutate      PROCEDURE(BYTE isDelete),LONG     ! two-pass UPDATE/DELETE, spec section 5; DoUpdate/DoDelete wrap it
Undo        PROCEDURE(),STRING               ! ROLLBACK; 'rolled_back' or 'unknown'
RowIdText   PROCEDURE(),STRING               ! primary/unique key values of the current buffer, else position hex
IdKeyNbr    PROCEDURE(),LONG                 ! primary key, else the first unique key, else 0
ErrOut      PROCEDURE(STRING op, STRING code, STRING msg, STRING outcome, LONG exitCode, <STRING errExtra>, <STRING topExtra>),LONG
          END
  _EndTpsExec_
