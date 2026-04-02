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

    return env.ASSETS.fetch(request);
  }
};

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
