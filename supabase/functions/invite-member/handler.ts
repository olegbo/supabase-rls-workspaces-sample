// Request handling for the invite-member function. Pure with respect to I/O:
// everything external (database, mail, clock, randomness) comes in through `Deps`,
// so the whole flow is unit-testable without a running stack.
import { z } from 'zod';

export const InviteRequest = z.object({
  workspaceId: z.uuid(),
  email: z.string().trim().toLowerCase().pipe(z.email().max(320)),
  role: z.enum(['member', 'admin']).default('member'),
});
export type InviteRequest = z.infer<typeof InviteRequest>;

export type InsertResult =
  | { ok: true; id: string; expiresAt: string }
  | { ok: false; code: string; message: string };

// Narrow port over the user-scoped Supabase client. Calls run with the caller's JWT,
// so RLS decides whether the caller may invite into the workspace.
export interface InviteStore {
  currentUserId(): Promise<string | null>;
  insertInvite(row: InviteRequest & { tokenHash: string }): Promise<InsertResult>;
}

export interface InviteEmail {
  to: string;
  acceptUrl: string;
  role: InviteRequest['role'];
}

export interface Deps {
  storeFor(jwt: string): InviteStore;
  sendInviteEmail(email: InviteEmail): Promise<boolean>;
  newToken(): string;
  appUrl: string;
  allowedOrigin: string;
  log(event: string, fields: Record<string, unknown>): void;
}

type Envelope = { data: unknown; error: { code: string; message: string } | null };

// Database error codes -> HTTP responses. Anything else is logged and reported as 500.
const DB_ERRORS: Record<string, { status: number; code: string; message: string }> = {
  '42501': { status: 403, code: 'forbidden', message: 'You cannot invite with this role here' },
  '23505': {
    status: 409,
    code: 'already_invited',
    message: 'A pending invite for this email exists',
  },
  '23514': { status: 400, code: 'invalid_request', message: 'Invite data was rejected' },
  'PT429': { status: 429, code: 'rate_limited', message: 'Too many invites, try again later' },
};

const BEARER = /^bearer\s+(\S+)$/i;

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

export function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/, '');
}

export function createHandler(deps: Deps): (req: Request) => Promise<Response> {
  const cors = {
    'Access-Control-Allow-Origin': deps.allowedOrigin,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };

  const reply = (status: number, body: Envelope): Response =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, 'Content-Type': 'application/json' },
    });

  const fail = (status: number, code: string, message: string): Response =>
    reply(status, { data: null, error: { code, message } });

  return async (req) => {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    if (req.method !== 'POST') return fail(405, 'method_not_allowed', 'Use POST');

    const jwt = BEARER.exec(req.headers.get('Authorization') ?? '')?.[1];
    if (!jwt) return fail(401, 'unauthorized', 'Missing bearer token');

    // Authenticate before looking at the body, so anonymous callers learn nothing
    // about the expected input.
    const store = deps.storeFor(jwt);
    const userId = await store.currentUserId();
    if (!userId) return fail(401, 'unauthorized', 'Invalid or expired session');

    let payload: unknown;
    try {
      payload = await req.json();
    } catch {
      return fail(400, 'invalid_json', 'Body must be JSON');
    }

    const parsed = InviteRequest.safeParse(payload);
    if (!parsed.success) {
      return fail(400, 'invalid_request', z.prettifyError(parsed.error));
    }

    const token = deps.newToken();
    const result = await store.insertInvite({ ...parsed.data, tokenHash: await sha256Hex(token) });

    const target = {
      userId,
      workspaceId: parsed.data.workspaceId,
      emailDomain: parsed.data.email.split('@')[1],
    };

    if (!result.ok) {
      const known = DB_ERRORS[result.code];
      if (known) {
        deps.log('invite_rejected', { ...target, code: result.code });
        return fail(known.status, known.code, known.message);
      }
      deps.log('invite_insert_failed', { ...target, code: result.code, message: result.message });
      return fail(500, 'internal', 'Could not create invite');
    }

    const acceptUrl = `${deps.appUrl}/invites/accept#token=${encodeURIComponent(token)}`;
    let emailSent = false;
    try {
      emailSent = await deps.sendInviteEmail({
        to: parsed.data.email,
        acceptUrl,
        role: parsed.data.role,
      });
    } catch (err) {
      // The invite exists; the admin can still share the link manually.
      deps.log('invite_email_failed', { inviteId: result.id, error: String(err) });
    }

    deps.log('invite_created', { ...target, inviteId: result.id, emailSent });
    return reply(201, {
      data: {
        id: result.id,
        expiresAt: result.expiresAt,
        emailSent,
        // Returned only when mail delivery did not happen, so the link is never lost.
        ...(emailSent ? {} : { acceptUrl }),
      },
      error: null,
    });
  };
}
