export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const corsHeaders = buildCorsHeaders(request, env);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    if (url.pathname === '/api/state') {
      const siteId = getSiteId(request, url);
      if (!siteId) {
        return json({ ok: false, error: 'Missing site id' }, 400, corsHeaders);
      }

      if (!authorize(request, env)) {
        return json({ ok: false, error: 'Unauthorized' }, 401, corsHeaders);
      }

      const kvKey = `site:${siteId}:state`;

      try {
        if (request.method === 'GET') {
          const stored = await env.GABBAI_KV.get(kvKey, 'json');
          if (!stored) {
            return json({ ok: true, state: null, siteId, exists: false }, 404, corsHeaders);
          }
          return json({ ok: true, siteId, exists: true, ...stored }, 200, corsHeaders);
        }

        if (request.method === 'POST') {
          const body = await request.json();
          const state = body?.state && typeof body.state === 'object' ? body.state : null;
          if (!state) {
            return json({ ok: false, error: 'Missing state object' }, 400, corsHeaders);
          }

          const document = {
            schemaVersion: body?.schemaVersion || state?.schemaVersion || 2,
            namespace: body?.namespace || 'gabbai-db',
            siteId,
            updatedAt: body?.updatedAt || new Date().toISOString(),
            state
          };

          await env.GABBAI_KV.put(kvKey, JSON.stringify(document));
          return json({ ok: true, saved: true, siteId, updatedAt: document.updatedAt }, 200, corsHeaders);
        }

        return json({ ok: false, error: 'Method not allowed' }, 405, {
          ...corsHeaders,
          'Allow': 'GET,POST,OPTIONS'
        });
      } catch (error) {
        return json({ ok: false, error: error instanceof Error ? error.message : 'Unknown error' }, 500, corsHeaders);
      }
    }

    // =========================================
    // HITVADUYOT (התוועדויות) API
    // =========================================
    if (url.pathname.startsWith('/api/hitvaduyot')) {
      const kvKey = 'hitvaduyot_current';

      try {
        // GET — return all data
        if (request.method === 'GET') {
          const stored = await env.GABBAI_KV.get(kvKey, 'json');
          return json({ ok: true, data: stored || null }, 200, corsHeaders);
        }

        if (request.method === 'POST') {
          const body = await request.json();
          const action = url.pathname.replace('/api/hitvaduyot', '').replace(/^\//, '') || body?.action;

          // INIT — initialize year table (admin only)
          if (action === 'init') {
            const adminPass = env.GABBAI_ADMIN_PASS || 'chabad770';
            if (body.password !== adminPass) {
              return json({ ok: false, error: 'סיסמה שגויה' }, 403, corsHeaders);
            }
            const data = { year: body.year || '', entries: body.entries || [], updatedAt: new Date().toISOString() };
            await env.GABBAI_KV.put(kvKey, JSON.stringify(data));
            return json({ ok: true, saved: true }, 200, corsHeaders);
          }

          // CLAIM — claim a parsha (public, first come first served)
          if (action === 'claim') {
            const { parshaIndex, donor, additionalDonors, eventType, notes } = body;
            if (typeof parshaIndex !== 'number' || !donor) {
              return json({ ok: false, error: 'חסרים נתונים' }, 400, corsHeaders);
            }
            const stored = await env.GABBAI_KV.get(kvKey, 'json');
            if (!stored || !stored.entries || !stored.entries[parshaIndex]) {
              return json({ ok: false, error: 'פרשה לא נמצאה' }, 404, corsHeaders);
            }
            const entry = stored.entries[parshaIndex];
            if (entry.locked && entry.donor) {
              return json({ ok: false, error: 'הפרשה כבר תפוסה! תפס: ' + entry.donor }, 409, corsHeaders);
            }
            entry.donor = donor;
            entry.additionalDonors = Array.isArray(additionalDonors) ? additionalDonors : [];
            entry.eventType = eventType || '';
            entry.notes = notes || '';
            entry.locked = true;
            entry.lockedAt = new Date().toISOString();
            stored.updatedAt = new Date().toISOString();
            await env.GABBAI_KV.put(kvKey, JSON.stringify(stored));
            return json({ ok: true, claimed: true, parsha: entry.parsha }, 200, corsHeaders);
          }

          // EDIT — donor self-edit within 10-minute window
          if (action === 'edit') {
            const { parshaIndex, donor, newDonor, eventType, notes, cancel } = body;
            if (typeof parshaIndex !== 'number' || !donor) {
              return json({ ok: false, error: 'חסרים נתונים' }, 400, corsHeaders);
            }
            const stored = await env.GABBAI_KV.get(kvKey, 'json');
            if (!stored || !stored.entries || !stored.entries[parshaIndex]) {
              return json({ ok: false, error: 'פרשה לא נמצאה' }, 404, corsHeaders);
            }
            const entry = stored.entries[parshaIndex];
            // Verify donor match
            if (entry.donor !== donor) {
              return json({ ok: false, error: 'אין הרשאה — השם לא תואם' }, 403, corsHeaders);
            }
            // Verify 10-minute window
            const lockedTime = entry.lockedAt ? new Date(entry.lockedAt).getTime() : 0;
            const elapsed = Date.now() - lockedTime;
            if (elapsed > 10 * 60 * 1000) {
              return json({ ok: false, error: 'חלון העריכה נסגר (10 דקות). פנה לרב לשינויים.' }, 403, corsHeaders);
            }
            if (cancel) {
              entry.donor = '';
              entry.additionalDonors = [];
              entry.eventType = '';
              entry.notes = '';
              entry.locked = false;
              entry.lockedAt = '';
            } else {
              if (typeof newDonor === 'string' && newDonor.trim()) entry.donor = newDonor.trim();
              if (Array.isArray(body.additionalDonors)) entry.additionalDonors = body.additionalDonors;
              if (typeof eventType === 'string') entry.eventType = eventType;
              if (typeof notes === 'string') entry.notes = notes;
            }
            stored.updatedAt = new Date().toISOString();
            await env.GABBAI_KV.put(kvKey, JSON.stringify(stored));
            return json({ ok: true, updated: true, cancelled: Boolean(cancel) }, 200, corsHeaders);
          }

          // ADMIN — edit any entry (requires password)
          if (action === 'admin') {
            const adminPass = env.GABBAI_ADMIN_PASS || 'chabad770';
            if (body.password !== adminPass) {
              return json({ ok: false, error: 'סיסמה שגויה' }, 403, corsHeaders);
            }
            const stored = await env.GABBAI_KV.get(kvKey, 'json');
            if (!stored || !stored.entries) {
              return json({ ok: false, error: 'אין נתונים' }, 404, corsHeaders);
            }
            const { parshaIndex, donor, eventType, notes, unlock } = body;
            if (typeof parshaIndex !== 'number' || !stored.entries[parshaIndex]) {
              return json({ ok: false, error: 'פרשה לא נמצאה' }, 404, corsHeaders);
            }
            const entry = stored.entries[parshaIndex];
            if (unlock) {
              entry.donor = '';
              entry.additionalDonors = [];
              entry.eventType = '';
              entry.notes = '';
              entry.locked = false;
              entry.lockedAt = '';
            } else {
              if (typeof donor === 'string') entry.donor = donor;
              if (Array.isArray(body.additionalDonors)) entry.additionalDonors = body.additionalDonors;
              if (typeof eventType === 'string') entry.eventType = eventType;
              if (typeof notes === 'string') entry.notes = notes;
              entry.locked = Boolean(entry.donor);
              if (entry.donor && !entry.lockedAt) entry.lockedAt = new Date().toISOString();
            }
            stored.updatedAt = new Date().toISOString();
            await env.GABBAI_KV.put(kvKey, JSON.stringify(stored));
            return json({ ok: true, updated: true }, 200, corsHeaders);
          }

          return json({ ok: false, error: 'Unknown action' }, 400, corsHeaders);
        }

        return json({ ok: false, error: 'Method not allowed' }, 405, corsHeaders);
      } catch (error) {
        return json({ ok: false, error: error instanceof Error ? error.message : 'Unknown error' }, 500, corsHeaders);
      }
    }

    const assetResponse = await env.ASSETS.fetch(request);
    if (shouldBypassHtmlCache(url.pathname)) {
      return withHeaders(assetResponse, {
        'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0'
      });
    }
    return assetResponse;
  }
};

function shouldBypassHtmlCache(pathname) {
  return pathname === '/' ||
    pathname === '/index.html' ||
    pathname === '/hitvaduyot.html' ||
    pathname === '/Aliyot-Pro-CHABAD_Pro_DIGI_cloudflare_ready.html';
}

function getSiteId(request, url) {
  return request.headers.get('X-Gabbai-Site') || url.searchParams.get('siteId') || 'default';
}

function authorize(request, env) {
  const configuredToken = env.GABBAI_API_TOKEN || '';
  if (!configuredToken) return true;
  const auth = request.headers.get('Authorization') || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  return token === configuredToken;
}

function buildCorsHeaders(request, env) {
  const requestOrigin = request.headers.get('Origin') || '*';
  const allowedOrigin = env.GABBAI_ALLOWED_ORIGIN || requestOrigin || '*';
  return {
    'Access-Control-Allow-Origin': allowedOrigin,
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Gabbai-Site',
    'Vary': 'Origin'
  };
}

function json(payload, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(payload, null, 2), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      ...extraHeaders
    }
  });
}

function withHeaders(response, headers) {
  const merged = new Headers(response.headers);
  Object.entries(headers).forEach(([key, value]) => merged.set(key, value));
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: merged
  });
}
