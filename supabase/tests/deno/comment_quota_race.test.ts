// Concurrency check for the comment quota, which pgTAP cannot express (it needs two
// sessions). The author has 99 comments in the window. Session 1 inserts the 100th and keeps
// its transaction open; session 2 inserts while session 1 is uncommitted. Session 1 commits
// only once session 2 is waiting on a lock, or has already finished, so the order does not
// depend on timing:
// - with the per-author lock, session 2 waits, then counts 100 and gets PT429;
// - without it, session 2 counts 99 (session 1 is not committed) and inserts: the test fails.
// Skipped unless DB_URL points at a local stack (`supabase status -o env`).
import { assertEquals } from '@std/assert';
import postgres from 'postgres';

const dbUrl = Deno.env.get('DB_URL');

function connect() {
  return postgres(dbUrl!, { max: 1, onnotice: () => {} });
}

type Tx = postgres.TransactionSql;

async function insertAs(tx: Tx, userId: string, ws: string, article: string) {
  await tx`set local role authenticated`;
  await tx`select set_config('request.jwt.claims', ${
    JSON.stringify({ sub: userId, role: 'authenticated' })
  }, true)`;
  await tx`insert into public.kb_article_comments (workspace_id, article_id, body)
           values (${ws}, ${article}, 'race')`;
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
      const [{ pid: s2pid }] = await s2`select pg_backend_pid() as pid`;
      let s2Done = false;
      let markInserted!: () => void;
      const inserted = new Promise<void>((resolve) => markInserted = resolve);

      const first = s1.begin(async (tx) => {
        await insertAs(tx, user, ws, article);
        markInserted();
        // Keep the transaction open until session 2 is blocked behind it, or has finished
        // (which happens only when nothing blocks it).
        for (let i = 0; i < 500 && !s2Done; i++) {
          const [{ n }] = await admin`select count(*)::int as n from pg_stat_activity
                                      where pid = ${s2pid} and wait_event_type = 'Lock'`;
          if (n > 0) break;
          await new Promise((r) => setTimeout(r, 10));
        }
      });
      await inserted;
      const second = s2.begin((tx) => insertAs(tx, user, ws, article))
        .finally(() => s2Done = true);
      const results = await Promise.allSettled([first, second]);

      assertEquals(results.map((r) => r.status), ['fulfilled', 'rejected']);
      assertEquals((results[1] as PromiseRejectedResult).reason.code, 'PT429');
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
