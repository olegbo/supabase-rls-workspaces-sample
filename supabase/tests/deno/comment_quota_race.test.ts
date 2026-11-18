// Concurrency check for the comment quota, which pgTAP cannot express (it needs two
// sessions). The author has 99 comments in the window; two sessions each add one at the same
// time. Without serialization both count 99 and both insert; exactly one may succeed.
// Skipped unless DB_URL points at a local stack (`supabase status -o env`).
import { assertEquals } from '@std/assert';
import postgres from 'postgres';

const dbUrl = Deno.env.get('DB_URL');

function connect() {
  return postgres(dbUrl!, { max: 1, onnotice: () => {} });
}

type Sql = ReturnType<typeof connect>;

async function comment(sql: Sql, userId: string, ws: string, article: string, holdMs: number) {
  await sql.begin(async (tx) => {
    await tx`set local role authenticated`;
    await tx`select set_config('request.jwt.claims', ${
      JSON.stringify({ sub: userId, role: 'authenticated' })
    }, true)`;
    await tx`insert into public.kb_article_comments (workspace_id, article_id, body)
             values (${ws}, ${article}, 'race')`;
    await tx`select pg_sleep(${holdMs / 1000})`;
  });
}

Deno.test({
  name: 'two concurrent comments at the quota edge: exactly one gets through',
  ignore: !dbUrl,
  async fn() {
    const admin = connect();
    const [user, ws, article] = [crypto.randomUUID(), crypto.randomUUID(), crypto.randomUUID()];
    await admin`insert into auth.users (id, email, email_confirmed_at)
      values (${user}, ${`quota-${user}@example.test`}, now())`;
    await admin`insert into public.workspaces (id, name, slug)
      values (${ws}, 'Quota', ${`quota-${ws.slice(0, 8)}`})`;
    await admin`insert into public.workspace_members (workspace_id, user_id, role)
      values (${ws}, ${user}, 'owner')`;
    await admin`insert into public.kb_articles (id, workspace_id, title, published, created_by)
      values (${article}, ${ws}, 'Board', true, ${user})`;
    await admin`insert into public.kb_article_comments
        (workspace_id, article_id, body, created_by, created_at)
      select ${ws}, ${article}, 'old ' || g, ${user}, now() - interval '30 minutes'
      from generate_series(1, 99) g`;

    const [s1, s2] = [connect(), connect()];
    try {
      // Connect both sessions first, so neither start is delayed by connection setup.
      await Promise.all([s1`select 1`, s2`select 1`]);
      const first = comment(s1, user, ws, article, 500);
      await new Promise((r) => setTimeout(r, 100)); // second starts while first is uncommitted
      const second = comment(s2, user, ws, article, 0);
      const results = await Promise.allSettled([first, second]);

      // Whichever session wins, exactly one insert may succeed and the other gets PT429.
      const rejected = results.filter((r): r is PromiseRejectedResult => r.status === 'rejected');
      assertEquals(results.length - rejected.length, 1);
      assertEquals(rejected.map((r) => r.reason.code), ['PT429']);

      const [{ n }] = await admin`select count(*)::int as n from public.kb_article_comments
                                  where created_by = ${user}`;
      assertEquals(n, 100);
    } finally {
      await Promise.all([s1.end(), s2.end()]);
      await admin`delete from public.workspaces where id = ${ws}`;
      await admin`delete from auth.users where id = ${user}`;
      await admin.end();
    }
  },
});
