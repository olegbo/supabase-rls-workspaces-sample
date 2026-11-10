import { assert, assertEquals, assertMatch } from '@std/assert';
import { createHandler, type Deps, type InsertResult, randomToken, sha256Hex } from './handler.ts';

const WORKSPACE_ID = '10000000-0000-4000-8000-000000000001';

interface Recorded {
  inserted: Array<Record<string, unknown>>;
  emails: Array<{ to: string; acceptUrl: string }>;
  logs: string[];
  logFields: Array<Record<string, unknown>>;
  jwts: string[];
}

function setup(opts: {
  userId?: string | null;
  insert?: InsertResult;
  mail?: 'sent' | 'disabled' | 'throws';
} = {}) {
  const rec: Recorded = { inserted: [], emails: [], logs: [], logFields: [], jwts: [] };
  const deps: Deps = {
    storeFor: (jwt) => (rec.jwts.push(jwt), {
      currentUserId: () => Promise.resolve(opts.userId === undefined ? 'user-1' : opts.userId),
      insertInvite: (row) => {
        rec.inserted.push(row);
        return Promise.resolve(
          opts.insert ?? { ok: true, id: 'invite-1', expiresAt: '2026-11-17T00:00:00Z' },
        );
      },
    }),
    sendInviteEmail: (email) => {
      rec.emails.push(email);
      if (opts.mail === 'throws') return Promise.reject(new Error('smtp down'));
      return Promise.resolve(opts.mail !== 'disabled');
    },
    newToken: () => 'fixed-token',
    appUrl: 'https://app.example.test',
    allowedOrigin: 'https://app.example.test',
    log: (event, fields) => {
      rec.logs.push(event);
      rec.logFields.push(fields);
    },
  };
  return { handler: createHandler(deps), rec };
}

function post(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request('http://localhost/invite-member', {
    method: 'POST',
    headers: { Authorization: 'Bearer jwt', 'Content-Type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

const validBody = { workspaceId: WORKSPACE_ID, email: '  New.User@Example.TEST ' };

Deno.test('answers CORS preflight', async () => {
  const { handler } = setup();
  const res = await handler(new Request('http://localhost', { method: 'OPTIONS' }));
  assertEquals(res.status, 204);
  assertEquals(res.headers.get('Access-Control-Allow-Origin'), 'https://app.example.test');
});

Deno.test('rejects non-POST methods', async () => {
  const { handler } = setup();
  const res = await handler(new Request('http://localhost', { method: 'GET' }));
  assertEquals(res.status, 405);
});

Deno.test('requires a bearer token', async () => {
  const { handler, rec } = setup();
  const res = await handler(post(validBody, { Authorization: '' }));
  assertEquals(res.status, 401);
  assertEquals(rec.inserted.length, 0);
});

Deno.test('accepts any case of the bearer scheme and passes the bare JWT', async () => {
  const { handler, rec } = setup();
  const res = await handler(post(validBody, { Authorization: 'bearer   abc.def.ghi' }));
  assertEquals(res.status, 201);
  assertEquals(rec.jwts, ['abc.def.ghi']);
});

Deno.test('authenticates before reading the body', async () => {
  const { handler } = setup({ userId: null });
  for (const body of ['{not json', { workspaceId: 'nope' }]) {
    const res = await handler(post(body));
    assertEquals(res.status, 401);
    assertEquals((await res.json()).error.code, 'unauthorized');
  }
});

Deno.test('rejects invalid JSON', async () => {
  const { handler } = setup();
  const res = await handler(post('{not json'));
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error.code, 'invalid_json');
});

Deno.test('validates payload and never allows owner role', async () => {
  const { handler, rec } = setup();
  for (
    const body of [
      { workspaceId: 'nope', email: 'a@b.test' },
      { workspaceId: WORKSPACE_ID, email: 'not-an-email' },
      { workspaceId: WORKSPACE_ID, email: 'a@b.test', role: 'owner' },
    ]
  ) {
    const res = await handler(post(body));
    assertEquals(res.status, 400, JSON.stringify(body));
    assertEquals((await res.json()).error.code, 'invalid_request');
  }
  assertEquals(rec.inserted.length, 0);
});

Deno.test('rejects an invalid session', async () => {
  const { handler, rec } = setup({ userId: null });
  const res = await handler(post(validBody));
  assertEquals(res.status, 401);
  assertEquals(rec.inserted.length, 0);
});

Deno.test('stores only the token hash and normalizes email', async () => {
  const { handler, rec } = setup();
  const res = await handler(post(validBody));
  assertEquals(res.status, 201);
  assertEquals(rec.inserted, [{
    workspaceId: WORKSPACE_ID,
    email: 'new.user@example.test',
    role: 'member',
    tokenHash: await sha256Hex('fixed-token'),
  }]);
  assertEquals(
    rec.emails[0].acceptUrl,
    'https://app.example.test/invites/accept#token=fixed-token',
  );
});

Deno.test('hides the link when the email was sent', async () => {
  const { handler } = setup({ mail: 'sent' });
  const { data, error } = await (await handler(post(validBody))).json();
  assertEquals(error, null);
  assertEquals(data, { id: 'invite-1', expiresAt: '2026-11-17T00:00:00Z', emailSent: true });
});

Deno.test('returns the link when mail is disabled or fails', async () => {
  for (const mail of ['disabled', 'throws'] as const) {
    const { handler, rec } = setup({ mail });
    const res = await handler(post(validBody));
    assertEquals(res.status, 201);
    const { data } = await res.json();
    assertEquals(data.emailSent, false);
    assertMatch(data.acceptUrl, /#token=fixed-token$/);
    if (mail === 'throws') assert(rec.logs.includes('invite_email_failed'));
  }
});

Deno.test('maps database errors to HTTP codes and sends no email', async () => {
  const cases: Array<[string, number, string]> = [
    ['42501', 403, 'forbidden'], // RLS: not an admin, or an admin inviting an admin
    ['23505', 409, 'already_invited'],
    ['23514', 400, 'invalid_request'],
    ['PT429', 429, 'rate_limited'],
  ];
  for (const [dbCode, status, code] of cases) {
    const { handler, rec } = setup({ insert: { ok: false, code: dbCode, message: 'db detail' } });
    const res = await handler(post(validBody));
    assertEquals(res.status, status, dbCode);
    const body = await res.json();
    assertEquals(body.error.code, code);
    assert(!JSON.stringify(body).includes('db detail'));
    assertEquals(rec.emails.length, 0);
  }
});

Deno.test('logs the target workspace and email domain, never the address', async () => {
  const { handler, rec } = setup();
  await handler(post(validBody));
  const created = rec.logFields[rec.logs.indexOf('invite_created')];
  assertEquals(created.workspaceId, WORKSPACE_ID);
  assertEquals(created.emailDomain, 'example.test');
  assert(!JSON.stringify(rec.logFields).includes('new.user@'));
});

Deno.test('does not leak database errors', async () => {
  const { handler, rec } = setup({
    insert: { ok: false, code: 'XX000', message: 'secret detail' },
  });
  const res = await handler(post(validBody));
  assertEquals(res.status, 500);
  const text = await res.text();
  assert(!text.includes('secret detail'));
  assert(rec.logs.includes('invite_insert_failed'));
});

Deno.test('random tokens are url-safe and unique', () => {
  const tokens = new Set(Array.from({ length: 100 }, randomToken));
  assertEquals(tokens.size, 100);
  for (const t of tokens) assertMatch(t, /^[A-Za-z0-9_-]{43}$/);
});

Deno.test('sha256Hex matches the database digest format', async () => {
  // select encode(extensions.digest('abc', 'sha256'), 'hex')
  assertEquals(
    await sha256Hex('abc'),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  );
});
