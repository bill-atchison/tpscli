-- tests\parser.sql: one statement per line, run through tpscli.exe --parse-only
-- blank lines and lines starting with -- are ignored by tests\parser.ps1

-- DESCRIBE with bracket path
DESCRIBE [testdata\ALLTYPES.TPS]

-- SELECT *
SELECT * FROM [testdata\ALLTYPES.TPS]

-- SELECT with a column list
SELECT ID, STR, D FROM [testdata\ALLTYPES.TPS]

-- WHERE, every comparison operator
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE ID = 1
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE ID <> 1
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE ID != 1
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE ID < 5
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE ID > 5
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE ID <= 5
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE ID >= 5

-- AND / OR / NOT / parentheses
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE (ID = 1 OR ID = 2) AND NOT ID = 3

-- LIKE
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE STR LIKE 'AB%'

-- IN / NOT IN
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE ID IN (1, 2, 3)
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE ID NOT IN (1, 2, 3)

-- DATE compare
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE DT = '2026-09-15'

-- TIME compare
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE TM = '13:45:00'

-- literal = literal
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE 1 = 1

-- ORDER BY two columns, mixed direction
SELECT ID FROM [testdata\ALLTYPES.TPS] ORDER BY ID DESC, STR ASC

-- LIMIT / LIMIT OFFSET
SELECT ID FROM [testdata\ALLTYPES.TPS] LIMIT 10
SELECT ID FROM [testdata\ALLTYPES.TPS] LIMIT 10 OFFSET 5

-- a group path
SELECT ADDR.CITY FROM [testdata\GROUPS.TPS]

-- a subscript on a dimmed group, carried onto its members
SELECT PHONES[1].KIND FROM [testdata\GROUPS.TPS]

-- an array element
SELECT ARR[2] FROM [testdata\ALLTYPES.TPS]

-- INSERT with a column list
INSERT INTO [testdata\ALLTYPES.TPS] (ID, STR) VALUES (99, 'HELLO')

-- UPDATE with two SETs
UPDATE [testdata\ALLTYPES.TPS] SET STR = 'X', B = 1 WHERE ID = 1

-- DELETE with WHERE
DELETE FROM [testdata\ALLTYPES.TPS] WHERE ID = 1

-- rejections below this line

-- UPDATE without WHERE
UPDATE [testdata\ALLTYPES.TPS] SET STR = 'X'

-- DELETE without WHERE
DELETE FROM [testdata\ALLTYPES.TPS]

-- DELETE with LIMIT
DELETE FROM [testdata\ALLTYPES.TPS] WHERE ID = 1 LIMIT 5

-- UPDATE with LIMIT
UPDATE [testdata\ALLTYPES.TPS] SET STR = 'X' WHERE ID = 1 LIMIT 5

-- JOIN
SELECT ID FROM [testdata\ALLTYPES.TPS] JOIN OTHER

-- COUNT(*)
SELECT COUNT(*) FROM [testdata\ALLTYPES.TPS]

-- IS NULL
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE STR IS NULL

-- arithmetic in WHERE
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE ID + 1 = 2

-- unknown column
SELECT NOPE FROM [testdata\ALLTYPES.TPS]

-- duplicate INSERT column
INSERT INTO [testdata\ALLTYPES.TPS] (ID, ID) VALUES (1, 2)

-- mismatched INSERT column/value counts
INSERT INTO [testdata\ALLTYPES.TPS] (ID, STR) VALUES (1)

-- unquoted path with a backslash
DESCRIBE testdata\ALLTYPES.TPS

-- two statements separated by a semicolon
SELECT ID FROM [testdata\ALLTYPES.TPS]; SELECT ID FROM [testdata\ALLTYPES.TPS]

-- an unterminated string
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE STR = 'ABC

-- LIKE pattern with a literal * (MATCH has no escape in wildcard mode)
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE STR LIKE 'A*B'

-- a second subscript on GRID (stored as one dimension of 6, not DIM(2,3))
SELECT GRID[2][2] FROM [testdata\GROUPS.TPS]

-- INSERT assigning a whole GROUP
INSERT INTO [testdata\GROUPS.TPS] (ID, ADDR) VALUES (1, 'x')

-- INSERT assigning a whole array with no subscript
INSERT INTO [testdata\ALLTYPES.TPS] (ID, ARR) VALUES (1, 1)

-- GROUP BY is rejected
SELECT ID FROM [testdata\ALLTYPES.TPS] GROUP BY ID

-- a bare GROUP is resolved as a column reference (not a reserved word by itself)
SELECT ID FROM [testdata\ALLTYPES.TPS] WHERE GROUP = 1
