# persistent on D1

`Database.Persist.D1` (`haskell/persistent-d1`) runs persistent's SQL API
against Cloudflare D1. The SQL is persistent-sqlite's SQLite dialect, reused
as is; the statements go through `Cloudflare.Workers.D1` (see [d1.md](d1.md))
instead of a SQLite connection. Entities, `mkPersist`, `selectList`, `insert`,
`update` and the rest are the ordinary persistent API.

The differences from persistent-sqlite, all of which follow from D1, are
below: no transactions, at most 100 parameters per statement, how values are
stored, and no migrations at run time.

## Usage

Configure the D1 binding as in [d1.md](d1.md), then:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- plus the extensions persistent's Template Haskell needs, as usual

import qualified Cloudflare.Workers.D1 as D1
import Cloudflare.Workers.Env (Env)
import Data.Text (Text)
import Database.Persist
import Database.Persist.D1 (runD1)
import Database.Persist.TH

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
Note
  title Text
  count Int
  UniqueTitle title
|]

example :: Env -> IO [Entity Note]
example env = do
  db <- D1.d1 env "DB"
  runD1 db $ do
    _ <- insert (Note "hello" 1)
    selectList [NoteCount >=. 1] [Desc NoteCount, LimitTo 10]
```

| Function | Does |
|---|---|
| `runD1 db action` | Runs a `SqlPersistT IO` action against the database. |
| `d1Backend db` | The `SqlBackend` itself, for `runReaderT` or anything else that takes one. It holds no connection and is cheap to build, so one per request is fine. |
| `createD1Pool db` | A `Pool SqlBackend` for `runSqlPool`, so code written for a pool works unchanged. Its size and idle time limit nothing, since a backend holds no connection. |
| `d1MigrationSql db migration` | The statements persistent would run to migrate the database to the given definitions. Nothing is executed (see [Migrations](#migrations)). |
| `putManyChunked rows` | `putMany` split into statements within the parameter limit. |
| `repsertManyChunked pairs` | `repsertMany` split the same way. |

### Yesod

Keep the pool in the foundation and run `runDB` through it:

```haskell
data App = App { appDb :: D1.D1Database, appPool :: Pool SqlBackend }

instance YesodPersist App where
  type YesodPersistBackend App = SqlBackend
  runDB action = getsYesod appPool >>= runSqlPool action

main :: IO ()
main = runCloudflareWith $ \env -> do
  db <- D1.d1 env "DB"
  pool <- createD1Pool db
  toWaiAppPlain (App db pool)
```

`runSqlPool` calls persistent's begin, commit and rollback hooks, which do
nothing here, so a handler that throws halfway through `runDB` keeps the
writes it has already made. `test-yesod` checks `createD1Pool` with
`runSqlPool` directly; it does not depend on `yesod-persistent`, which
provides `YesodPersist`.

## No transactions

D1 has no `BEGIN`/`COMMIT`, so every statement commits on its own, and an
exception does not undo the statements before it. That covers `runD1`,
`runSqlPool` and `runDB` alike.

Writes that must be atomic go through `Cloudflare.Workers.D1.batch`, which
runs a list of statements in one transaction. It takes raw SQL, not
persistent actions:

```haskell
transfer :: D1.D1Database -> Int64 -> Int64 -> Int64 -> IO ()
transfer db from to amount = do
  _ <- D1.batch db
    [ D1.Statement "UPDATE account SET balance = balance - ? WHERE id = ?" [D1.D1Integer amount, D1.D1Integer from]
    , D1.Statement "UPDATE account SET balance = balance + ? WHERE id = ?" [D1.D1Integer amount, D1.D1Integer to]
    ]
  pure ()
```

A single statement is atomic. `putMany`, `repsertMany` and `repsert` are each
one statement, as in persistent-sqlite, so concurrent requests cannot
interleave between their lookup and their write. `upsert` and `upsertBy` are
not: they use persistent's default, a `getBy` followed by an `insert` or an
`update`, and two requests can race between the two.

## At most 100 parameters per statement

D1 rejects a statement with more than 100 bound parameters. The backend
declares that limit to persistent, so:

- `insertMany_` and `insertEntityMany` are split into chunks by persistent.
- `insertMany` runs one `INSERT … RETURNING` per row.
- `putMany`, `repsertMany` and `repsert` stay one atomic statement for all
  rows and fail past the limit. For many rows use `putManyChunked` and
  `repsertManyChunked`, which send as many rows per statement as fit (100
  divided by the entity's field count plus one for the key). Each chunk is
  atomic; the chunks together are not.
- Any other statement over the limit fails, for example a `<-.` filter with
  more than 100 values or a `getMany` with more than 100 keys. Split those
  yourself.

```haskell
importNotes :: D1.D1Database -> [Note] -> IO ()
importNotes db notes = runD1 db (putManyChunked notes)
```

## Insert ids come from `RETURNING`

persistent-sqlite reads a new row's id with a second statement,
`SELECT last_insert_rowid()`. On Workers, requests interleave within one
isolate, so that statement can return the id of another request's insert;
under `wrangler dev`, 16 of 20 concurrent inserts read back the wrong row
before this was fixed. The backend appends `RETURNING <id column>` to the
`INSERT` instead, which gets the id from the same statement.

## Values

Values are converted as persistent-sqlite converts them, then cross into D1 as
described in [d1.md](d1.md).

| persistent | Stored as |
|---|---|
| `Int`, `Int64`, keys | INTEGER |
| `Double` | REAL |
| `Bool` | INTEGER, 0 or 1 |
| `Text` | TEXT |
| `ByteString` | BLOB |
| `Rational` | TEXT, at `Pico` precision |
| `Day`, `TimeOfDay` | TEXT, ISO 8601 (`2026-10-03`, `13:45:00`) |
| `UTCTime` | TEXT, ISO 8601 (`2026-10-03T12:34:56.123456Z`) |
| lists and maps | TEXT, as JSON |

`PersistObjectId` cannot be stored and raises an error.

The D1 caveats carry over:

- **Every number is bound as a REAL.** A column with INTEGER affinity turns a
  whole number back into an integer, but an `Int` written to a TEXT column is
  stored as `"5.0"`.
- **A whole-number REAL reads back as an integer.** A `Double` field holding
  `2.0` comes back as `PersistInt64 2`. persistent's built-in instances accept
  that; a custom `PersistField` that only matches `PersistDouble` does not.
- **±(2^53 − 1).** Integers and keys outside that range throw `D1Exception`,
  when bound and when read.

## Queries are not streamed

D1 returns all rows of a query at once, so they are all held in memory, and
`selectSource` yields them from there. A query runs when it is acquired, not
when its rows are pulled. Bound large results with `LimitTo` and
`OffsetBy`.

## No SQL logging

The backend's log function does nothing, so the SQL persistent runs is never
logged, whatever logger is in scope.

## Migrations

Do not run `runMigration` in the Worker. Each new isolate would run it on its
first request, isolates start concurrently, and with no transactions two of
them can apply the same changes at once or leave a migration half done. Apply
migrations with wrangler, before the code that needs them is deployed:

1. Generate the SQL with `d1MigrationSql`. It inspects the database's current
   schema, so run it against a local database that is up to date, for
   example from a route that exists only in development, under
   `wrangler dev`:

   ```haskell
   -- Development only: never serve this route in production.
   getMigrationR :: Handler Text
   getMigrationR = do
     db <- getsYesod appDb
     stmts <- liftIO (d1MigrationSql db migrateAll)
     pure (T.concat [s <> ";\n" | s <- stmts])
   ```

   The statements come without a trailing `;`, so join them with `";\n"` as
   above.

2. Save the output as a wrangler migration:

   ```sh
   wrangler d1 migrations create DB add_notes    # creates migrations/0001_add_notes.sql
   curl http://localhost:8787/dev/migration > migrations/0001_add_notes.sql
   ```

3. Review it, then apply it:

   ```sh
   wrangler d1 migrations apply DB --local     # or --remote
   ```

Read every generated file before applying it. `d1MigrationSql` returns all of
persistent's statements, including the ones `runMigration` would refuse as
unsafe, such as dropping a column.

Whenever a table's definition changes (a column added, removed or retyped),
persistent-sqlite rebuilds the table: it copies the rows into a backup
table `<table>_backup`, drops the original, recreates it, copies the rows
back and drops the backup. persistent-sqlite makes the backup a `TEMP`
table, which D1 refuses (`not authorized`), so `d1MigrationSql` emits an
ordinary `CREATE TABLE` for it instead.

D1 always enforces foreign keys, and `DROP TABLE` first deletes every row of
the table. If other tables reference it (a `userId UserId` field, say), a
rebuild of the referenced table therefore:

- fails, when the reference has no `ON DELETE` action (persistent's
  default). Start the migration file with the pragma below, which defers the
  check to the end of the migration, when the rows are back:

  ```sql
  PRAGMA defer_foreign_keys = true;
  ```

- deletes the referencing rows, when the reference is `OnDeleteCascade`, or
  overwrites their reference with `OnDeleteSetNull` or `OnDeleteSetDefault`.
  The pragma does not stop this: it defers checks, not actions.

- fails even with the pragma, when the reference is `OnDeleteRestrict`:
  SQLite enforces `RESTRICT` at once, deferred or not.

Write these last two kinds of migration by hand.

## The vendored persistent-sqlite

`persistent-d1` reuses persistent-sqlite's SQL generation, which upstream does
not export. `haskell/vendor/persistent-sqlite-2.13.3.1` is the Hackage release
with a patch that:

- exports `insertSql'`, `migrate'`, `escape`, `putManySql`, `repsertManySql`
  and `Database.Sqlite.format8601`;
- on wasi, drops `-lpthread`, which GHC's Template Haskell interpreter cannot
  load (see [constraints.md](constraints.md)), and builds SQLite with
  `SQLITE_THREADSAFE=0`.

persistent-sqlite's bundled SQLite C code is linked into the module but never
runs. Disabling SQLite's optional features did not change the wasm size.
`haskell/vendor/README.md` lists the patch with the others.

## Testing

D1 exists only on workerd, so persistent on D1 is not covered by
`test/*.test.mjs`. `node scripts/check-wrangler.mjs` runs `test-yesod` with a
local D1 (binding `DB` in `test/yesod-wrangler.toml`) and calls its
`/persist/*` routes:

- the migration creates the table, and afterwards none is left to apply;
- CRUD: insert, get, a filtered, ordered and limited `selectList`, update,
  delete and count;
- 20 concurrent inserts each read back their own row;
- every field type of the test entity round-trips;
- a unique constraint rejects a duplicate;
- bulk writes past 100 parameters (`insertMany_`, `putManyChunked`,
  `repsertManyChunked`), and an unchunked `putMany` that is too big is
  rejected;
- `createD1Pool` with `runSqlPool`;
- a migration that adds a column rebuilds the table and keeps its rows.

`test-yesod` applies the migration with `D1.execute`, which is fine for tests;
apps should use `wrangler d1 migrations`.
