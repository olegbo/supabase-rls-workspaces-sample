// Production implementations of the handler ports.
import { createClient } from '@supabase/supabase-js';
import type { InviteEmail, InviteStore } from './handler.ts';

export function supabaseInviteStore(
  url: string,
  publishableKey: string,
  jwt: string,
): InviteStore {
  const client = createClient(url, publishableKey, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  return {
    async currentUserId() {
      // Verifies the signature (locally via JWKS for asymmetric keys). API keys such as
      // anon or service_role carry no `sub`, so they never count as a signed-in user.
      const { data, error } = await client.auth.getClaims(jwt);
      if (error || !data) return null;
      const { sub, role } = data.claims;
      return role === 'authenticated' && sub ? sub : null;
    },

    async insertInvite({ workspaceId, email, role, tokenHash }) {
      const { data, error } = await client
        .from('workspace_invites')
        .insert({ workspace_id: workspaceId, email, role, token_hash: tokenHash })
        .select('id, expires_at')
        .single();
      if (error) return { ok: false, code: error.code, message: error.message };
      return { ok: true, id: data.id, expiresAt: data.expires_at };
    },
  };
}

export function resendMailer(apiKey: string | undefined, from: string) {
  return async ({ to, acceptUrl, role }: InviteEmail): Promise<boolean> => {
    if (!apiKey) return false;

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from,
        to,
        subject: 'You have been invited to a workspace',
        text: `You were invited as ${role}. Accept the invite: ${acceptUrl}\n` +
          'The link expires in 7 days.',
      }),
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) throw new Error(`Resend responded ${res.status}`);
    return true;
  };
}
