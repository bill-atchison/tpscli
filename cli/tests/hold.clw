  PROGRAM
! Test helper for tests\update.ps1: opens the work copy of KEYS.TPS shared, HOLDs the record
! with Id 2 for eight seconds, and flags that it has done so with testdata\work\held.flag so the
! test knows when tpscli can safely be run against the held row. Paths are relative, so run this
! with the repository root as the working directory (same convention as testdata\gen\mkcorpus).
! The FILE declaration below must stay byte-compatible with testdata\gen\mkcorpus.clw's Keys.
  MAP
    MODULE('WINAPI')
      SleepMs(ULONG),PASCAL,RAW,NAME('Sleep')
    END
  END

HOLD_MS  EQUATE(8000)

Keys     FILE,DRIVER('TOPSPEED'),NAME('testdata\work\KEYS.TPS'),PRE(KY)
PKey       KEY(KY:Id),PRIMARY
DupKey     KEY(KY:Name),DUP,NOCASE
OptKey     KEY(KY:Code),OPT
DescKey    KEY(-KY:Amount,+KY:Id),DUP
Idx        INDEX(KY:Name)
Record       RECORD
Id           LONG
Name         STRING(30)
Code         STRING(4)
Amount       DECIMAL(9,2)
             END
         END

Flag     FILE,DRIVER('DOS'),NAME('testdata\work\held.flag'),CREATE
Record       RECORD
Marker         BYTE
             END
         END

  CODE
  SHARE(Keys)
  IF ERRORCODE() THEN HALT(2).
  KY:Id = 2
  HOLD(Keys, 1)
  GET(Keys, KY:PKey)
  IF ERRORCODE() THEN CLOSE(Keys); HALT(3).
  CREATE(Flag)
  IF ERRORCODE() THEN RELEASE(Keys); CLOSE(Keys); HALT(4).
  SleepMs(HOLD_MS)
  RELEASE(Keys)
  CLOSE(Keys)
  REMOVE(Flag)
  HALT(0)
