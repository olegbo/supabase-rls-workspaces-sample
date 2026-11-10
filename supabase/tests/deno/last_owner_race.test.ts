// Concurrency check for the last-owner guard, which pgTAP cannot express (it needs two
// sessions). Two owners each step down at the same time: exactly one may succeed.
// Skipped unless DB_URL points at a local stack (`supabase status -o env`).
import { assert, assertEquals, assertRejects } from '@std/assert';
import postgres from 'postgres';

const dbUrl = Deno.env.get('DB_URL');

function connect() {
  return postgres(dbUrl!, { max: 1, onnotice: () => {} });
}

type Sql = ReturnType<typeof connect>;

async function stepDown(
  sql: Sql,
  userId: string,
  workspaceId: string,
  holdMs: number,
  isolation = 'read committed',
) {
  await sql.begin(`isolation level ${isolation}`, async (tx) => {
    await tx`set local role authenticated`;
    await tx`select set_config('request.jwt.claims', ${
      JSON.stringify({ sub: userId, role: 'authenticated' })
    }, true)`;
    await tx`update public.workspace_members set role = 'admin'
             where workspace_id = ${workspaceId} and user_id = ${userId}`;
    await tx`select pg_sleep(${holdMs / 1000})`;
  });
}

async function withTwoOwners(fn: (ws: string, a: string, b: string) => Promise<void>) {
  const admin = connect();
  const [a, b, ws] = [crypto.randomUUID(), crypto.randomUUID(), crypto.randomUUID()];
  await admin`insert into auth.users (id, email, email_confirmed_at) values
    (${a}, ${`race-${a}@example.test`}, now()), (${b}, ${`race-${b}@example.test`}, now())`;
  await admin`insert into public.workspaces (id, name, slug)
    values (${ws}, 'Race', ${`race-${ws.slice(0, 8)}`})`;
  await admin`insert into public.workspace_members (workspace_id, user_id, role)
    values (${ws}, ${a}, 'owner'), (${ws}, ${b}, 'owner')`;
  try {
    await fn(ws, a, b);
  } finally {
    await admin`delete from public.workspaces where id = ${ws}`;
    await admin`delete from auth.users where id in (${a}, ${b})`;
    await admin.end();
  }
}

Deno.test({
  name: 'two owners stepping down concurrently leave one owner',
  ignore: !dbUrl,
  async fn() {
    await withTwoOwners(async (ws, a, b) => {
      const [s1, s2] = [connect(), connect()];
      try {
        const first = stepDown(s1, a, ws, 500);
        await new Promise((r) => setTimeout(r, 100)); // second starts while first holds the lock
        const second = stepDown(s2, b, ws, 0);
        const results = await Promise.allSettled([first, second]);

        assertEquals(results.map((r) => r.status), ['fulfilled', 'rejected']);
        const err = (results[1] as PromiseRejectedResult).reason;
        assertEquals(err.code, 'PT409');

        const check = connect();
        const owners = await check`select user_id from public.workspace_members
                                   where workspace_id = ${ws} and role = 'owner'`;
        await check.end();
        assertEquals(owners.map((o) => o.user_id), [b]);
      } finally {
        await Promise.all([s1.end(), s2.end()]);
      }
    });
  },
});

Deno.test({
  name: 'owner changes refuse repeatable read, where the guard could be bypassed',
  ignore: !dbUrl,
  async fn() {
    await withTwoOwners(async (ws, a) => {
      const sql = connect();
      try {
        const err = await assertRejects(() => stepDown(sql, a, ws, 0, 'repeatable read'));
        assert(err instanceof Error);
        assertEquals((err as Error & { code: string }).code, '25001');
      } finally {
        await sql.end();
      }
    });
  },
});
