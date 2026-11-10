// End-to-end against a local stack: `supabase start && supabase functions serve`.
// Skipped unless SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are set.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { assertEquals } from '@std/assert';

const url = Deno.env.get('SUPABASE_URL');
const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const enabled = Boolean(url && anonKey && serviceKey);

const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

async function signedInUser(admin: SupabaseClient, label: string) {
  const email = `${label}-${crypto.randomUUID()}@example.test`;
  const password = crypto.randomUUID();
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (error) throw error;

  const client = createClient(url!, anonKey!, noSession);
  const { data: session, error: signInError } = await client.auth.signInWithPassword({
    email,
    password,
  });
  if (signInError) throw signInError;
  return { id: data.user.id, email, client, jwt: session.session!.access_token };
}

function invite(jwt: string, body: unknown) {
  return fetch(`${url}/functions/v1/invite-member`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

async function statusOf(res: Promise<Response>): Promise<number> {
  const r = await res;
  await r.body?.cancel();
  return r.status;
}

Deno.test({
  name: 'invite flow end to end: auth, roles, duplicates, acceptance',
  ignore: !enabled,
  sanitizeResources: false,
  async fn() {
    const admin = createClient(url!, serviceKey!, noSession);
    const owner = await signedInUser(admin, 'owner');
    const invitee = await signedInUser(admin, 'invitee');
    const outsider = await signedInUser(admin, 'outsider');

    const { data: workspaceId, error } = await owner.client.rpc('create_workspace', {
      workspace_name: 'E2E',
      workspace_slug: `e2e-${crypto.randomUUID().slice(0, 8)}`,
    });
    if (error) throw error;

    const body = { workspaceId, email: invitee.email };
    // API keys are valid JWTs for the gateway but carry no user; a forged token is not valid.
    const [header, payload] = owner.jwt.split('.');
    const forged = `${header}.${payload}.${'A'.repeat(43)}`;
    for (
      const [label, jwt] of [['anon key', anonKey!], ['service role key', serviceKey!], [
        'forged',
        forged,
      ]]
    ) {
      assertEquals(await statusOf(invite(jwt, body)), 401, label);
    }

    assertEquals(await statusOf(invite(outsider.jwt, body)), 403, 'outsider');

    const res = await invite(owner.jwt, { workspaceId, email: invitee.email, role: 'admin' });
    assertEquals(res.status, 201);
    const { data } = await res.json();
    assertEquals(data.emailSent, false);

    assertEquals(await statusOf(invite(owner.jwt, body)), 409, 'duplicate');

    const token = new URL(data.acceptUrl).hash.replace('#token=', '');
    const { data: joined, error: acceptError } = await invitee.client.rpc(
      'accept_workspace_invite',
      { invite_token: decodeURIComponent(token) },
    );
    if (acceptError) throw acceptError;
    assertEquals(joined, workspaceId);

    const { data: members } = await invitee.client
      .from('workspace_members')
      .select('user_id, role')
      .eq('workspace_id', workspaceId)
      .order('role');
    assertEquals(members?.length, 2);
    assertEquals(members?.find((m) => m.user_id === invitee.id)?.role, 'admin');

    // The new admin may invite members but not other admins.
    const peer = { workspaceId, email: `peer-${crypto.randomUUID()}@example.test` };
    assertEquals(await statusOf(invite(invitee.jwt, { ...peer, role: 'admin' })), 403);
    assertEquals(await statusOf(invite(invitee.jwt, peer)), 201);

    const { data: visible } = await outsider.client.from('workspaces').select('id');
    assertEquals(visible, []);
  },
});
