// resendMailer runs against a stubbed fetch. supabaseInviteStore runs against the local
// stack (skipped unless SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY and
// JWT_SECRET are set), because its job is exactly the behaviour of the real auth and RLS.
import { createClient } from '@supabase/supabase-js';
import { assert, assertEquals, assertRejects } from '@std/assert';
import { resendMailer, supabaseInviteStore } from './adapters.ts';

type Call = { url: string; init: RequestInit };

function stubFetch(response: Response | Error): { calls: Call[]; restore: () => void } {
  const original = globalThis.fetch;
  const calls: Call[] = [];
  globalThis.fetch = ((url: string, init: RequestInit) => {
    calls.push({ url, init });
    return response instanceof Error ? Promise.reject(response) : Promise.resolve(response);
  }) as typeof fetch;
  return { calls, restore: () => (globalThis.fetch = original) };
}

const email = {
  to: 'new.user@example.test',
  acceptUrl: 'https://app.example.test/invites/accept#token=t',
  role: 'member' as const,
};

Deno.test('mailer without an API key sends nothing', async () => {
  const stub = stubFetch(new Error('must not be called'));
  try {
    assertEquals(await resendMailer(undefined, 'from@example.test')(email), false);
    assertEquals(stub.calls.length, 0);
  } finally {
    stub.restore();
  }
});

Deno.test('mailer posts one message with the link and a timeout', async () => {
  const stub = stubFetch(new Response('{"id":"m1"}', { status: 200 }));
  try {
    assertEquals(await resendMailer('re_key', 'Workspace <from@example.test>')(email), true);
    assertEquals(stub.calls.length, 1);
    const { url, init } = stub.calls[0];
    assertEquals(url, 'https://api.resend.com/emails');
    assertEquals(init.method, 'POST');
    assertEquals((init.headers as Record<string, string>).Authorization, 'Bearer re_key');
    assert(init.signal instanceof AbortSignal);
    const body = JSON.parse(init.body as string);
    assertEquals(body.from, 'Workspace <from@example.test>');
    assertEquals(body.to, 'new.user@example.test');
    assert(body.text.includes(email.acceptUrl));
    assert(body.text.includes('member'));
  } finally {
    stub.restore();
  }
});

Deno.test('mailer reports provider errors and network failures', async () => {
  for (const response of [new Response('bad', { status: 422 }), new TypeError('offline')]) {
    const stub = stubFetch(response);
    try {
      await assertRejects(() => resendMailer('re_key', 'from@example.test')(email));
    } finally {
      stub.restore();
    }
  }
});

// --- supabaseInviteStore against the local stack --------------------------------

const url = Deno.env.get('SUPABASE_URL');
const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const jwtSecret = Deno.env.get('JWT_SECRET');
const live = Boolean(url && anonKey && serviceKey && jwtSecret);
const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

async function signHs256(payload: Record<string, unknown>): Promise<string> {
  const enc = (v: unknown) =>
    btoa(JSON.stringify(v)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
  const head = `${enc({ alg: 'HS256', typ: 'JWT' })}.${enc(payload)}`;
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(jwtSecret!),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(head)));
  return `${head}.${
    btoa(String.fromCharCode(...sig)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')
  }`;
}

Deno.test({
  name: 'store: only a live, signed-in user session yields a user id',
  ignore: !live,
  sanitizeResources: false,
  async fn() {
    const admin = createClient(url!, serviceKey!, noSession);
    const addr = `store-${crypto.randomUUID()}@example.test`;
    const password = crypto.randomUUID();
    const { data: created, error } = await admin.auth.admin.createUser({
      email: addr,
      password,
      email_confirm: true,
    });
    if (error) throw error;
    try {
      const client = createClient(url!, anonKey!, noSession);
      const { data: session } = await client.auth.signInWithPassword({ email: addr, password });
      const userJwt = session.session!.access_token;
      const store = (jwt: string) => supabaseInviteStore(url!, anonKey!, jwt);

      assertEquals(await store(userJwt).currentUserId(), created.user.id);

      const now = Math.floor(Date.now() / 1000);
      const claims = { sub: created.user.id, role: 'authenticated', aud: 'authenticated' };
      const rejected: Record<string, string> = {
        'anon key': anonKey!,
        'service role key': serviceKey!,
        'garbage': 'not-a-jwt',
        'tampered signature': `${userJwt.slice(0, userJwt.lastIndexOf('.'))}.AAAA`,
        'expired token': await signHs256({ ...claims, iat: now - 7200, exp: now - 3600 }),
        // Correctly signed and unexpired, but not a signed-in user session.
        'signed, user sub, service_role': await signHs256({
          ...claims,
          role: 'service_role',
          iat: now,
          exp: now + 600,
        }),
        'signed, no sub': await signHs256({
          role: 'authenticated',
          aud: 'authenticated',
          iat: now,
          exp: now + 600,
        }),
      };
      for (const [label, jwt] of Object.entries(rejected)) {
        assertEquals(await store(jwt).currentUserId(), null, label);
      }

      // Database errors come back as codes, not exceptions.
      const result = await store(userJwt).insertInvite({
        workspaceId: crypto.randomUUID(),
        email: 'x@example.test',
        role: 'member',
        tokenHash: 'a'.repeat(64),
      });
      assertEquals(result.ok, false);
      if (!result.ok) assertEquals(result.code, '42501');

      const { data: workspaceId, error: rpcError } = await createClient(url!, anonKey!, {
        ...noSession,
        global: { headers: { Authorization: `Bearer ${userJwt}` } },
      }).rpc('create_workspace', {
        workspace_name: 'Store test',
        workspace_slug: `store-${crypto.randomUUID().slice(0, 8)}`,
      });
      if (rpcError) throw rpcError;
      const hash = Array.from(
        crypto.getRandomValues(new Uint8Array(32)),
        (b) => b.toString(16).padStart(2, '0'),
      ).join('');
      const created2 = await store(userJwt).insertInvite({
        workspaceId,
        email: 'invitee@example.test',
        role: 'member',
        tokenHash: hash,
      });
      assert(created2.ok);
      const days = (Date.parse(created2.expiresAt) - Date.now()) / 86_400_000;
      assert(days > 6.9 && days <= 7, `expires in ${days} days`);
    } finally {
      await admin.auth.admin.deleteUser(created.user.id);
    }
  },
});
