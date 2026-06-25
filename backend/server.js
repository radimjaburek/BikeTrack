require('dotenv').config();
const express = require('express');
const OAuth = require('oauth-1.0a');
const crypto = require('crypto');
const axios = require('axios');
const { v4: uuidv4 } = require('uuid');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;
const CONSUMER_KEY = process.env.GARMIN_CONSUMER_KEY;
const CONSUMER_SECRET = process.env.GARMIN_CONSUMER_SECRET;
const BACKEND_URL = process.env.BACKEND_URL;
const CALLBACK_SCHEME = process.env.APP_CALLBACK_SCHEME || 'biketrack';

const GARMIN_REQUEST_TOKEN_URL =
  'https://connectapi.garmin.com/oauth-service/oauth/request_token';
const GARMIN_AUTHORIZE_URL =
  'https://connect.garmin.com/oauthConfirm';
const GARMIN_ACCESS_TOKEN_URL =
  'https://connectapi.garmin.com/oauth-service/oauth/access_token';

// In-memory stores – nahraď databází (Redis / PostgreSQL) v produkci
const pendingTokens = new Map();  // oauth_token → oauth_token_secret
const sessions = new Map();       // session_id → { userId, accessToken, accessTokenSecret }
const userActivities = new Map(); // userId → Activity[]

function makeOAuth(tokenKey = '', tokenSecret = '') {
  const oauth = new OAuth({
    consumer: { key: CONSUMER_KEY, secret: CONSUMER_SECRET },
    signature_method: 'HMAC-SHA1',
    hash_function(base, key) {
      return crypto.createHmac('sha1', key).update(base).digest('base64');
    },
  });
  return { oauth, token: tokenKey ? { key: tokenKey, secret: tokenSecret } : undefined };
}

// ── Krok 1: Flutter zavolá tento endpoint – vrátí URL pro přihlášení na Garmin ──

app.get('/auth/garmin/init', async (req, res) => {
  if (!CONSUMER_KEY || !CONSUMER_SECRET || !BACKEND_URL) {
    return res.status(500).json({ error: 'Backend není nakonfigurován (.env)' });
  }

  try {
    const callbackUrl = `${BACKEND_URL}/auth/garmin/callback`;
    const { oauth } = makeOAuth();

    const requestData = {
      url: GARMIN_REQUEST_TOKEN_URL,
      method: 'POST',
      data: { oauth_callback: callbackUrl },
    };
    const authHeader = oauth.toHeader(oauth.authorize(requestData));

    const response = await axios.post(GARMIN_REQUEST_TOKEN_URL, null, {
      headers: {
        ...authHeader,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
    });

    const params = new URLSearchParams(response.data);
    const requestToken = params.get('oauth_token');
    const requestTokenSecret = params.get('oauth_token_secret');

    if (!requestToken) throw new Error('Garmin nevrátil request token');

    pendingTokens.set(requestToken, requestTokenSecret);
    setTimeout(() => pendingTokens.delete(requestToken), 10 * 60 * 1000);

    res.json({ auth_url: `${GARMIN_AUTHORIZE_URL}?oauth_token=${requestToken}` });
  } catch (err) {
    console.error('[/auth/garmin/init]', err.response?.data ?? err.message);
    res.status(500).json({ error: 'Nepodařilo se získat request token od Garmin' });
  }
});

// ── Krok 2: Garmin přesměruje sem po autorizaci uživatele ──

app.get('/auth/garmin/callback', async (req, res) => {
  const { oauth_token, oauth_verifier } = req.query;

  const requestTokenSecret = pendingTokens.get(oauth_token);
  if (!requestTokenSecret) {
    return res.redirect(`${CALLBACK_SCHEME}://auth-error?reason=invalid_token`);
  }
  pendingTokens.delete(oauth_token);

  try {
    const { oauth, token } = makeOAuth(oauth_token, requestTokenSecret);

    const requestData = {
      url: GARMIN_ACCESS_TOKEN_URL,
      method: 'POST',
      data: { oauth_verifier },
    };
    const authHeader = oauth.toHeader(oauth.authorize(requestData, token));

    const response = await axios.post(GARMIN_ACCESS_TOKEN_URL, null, {
      headers: {
        ...authHeader,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      params: { oauth_verifier },
    });

    const params = new URLSearchParams(response.data);
    const accessToken = params.get('oauth_token');
    const accessTokenSecret = params.get('oauth_token_secret');
    const userId = params.get('user_id') ?? accessToken;

    const sessionId = uuidv4();
    sessions.set(sessionId, { userId, accessToken, accessTokenSecret });
    if (!userActivities.has(userId)) userActivities.set(userId, []);

    // Přesměruje zpět do Flutter aplikace s session ID
    res.redirect(`${CALLBACK_SCHEME}://auth-success?session_id=${sessionId}`);
  } catch (err) {
    console.error('[/auth/garmin/callback]', err.response?.data ?? err.message);
    res.redirect(`${CALLBACK_SCHEME}://auth-error?reason=token_exchange_failed`);
  }
});

// ── Krok 3: Flutter stahuje aktivity pro přihlášeného uživatele ──

app.get('/activities', (req, res) => {
  const sessionId = req.headers.authorization?.replace('Bearer ', '');
  const session = sessions.get(sessionId);
  if (!session) return res.status(401).json({ error: 'Neplatná nebo vypršená session' });

  const activities = userActivities.get(session.userId) ?? [];
  res.json({ activities });
});

// ── Krok 4: Garmin tlačí data aktivit přes webhook (zaregistruj URL v dev portálu) ──
// Webhook URL pro Garmin developer portál: POST https://your-server.com/webhook/garmin/activities

app.post('/webhook/garmin/activities', (req, res) => {
  const incoming = req.body?.activities ?? [];

  for (const act of incoming) {
    const uid = act.userId;
    if (!uid) continue;
    if (!userActivities.has(uid)) userActivities.set(uid, []);

    const list = userActivities.get(uid);
    const alreadyExists = list.some((a) => a.activityId === act.activityId);
    if (!alreadyExists) {
      list.push({
        activityId: act.activityId,
        activityName: act.activityName ?? 'Aktivita',
        activityType: act.activityType ?? 'CYCLING',
        startTimeInSeconds: act.startTimeInSeconds,
        startTimeOffsetInSeconds: act.startTimeOffsetInSeconds ?? 0,
        durationInSeconds: act.durationInSeconds ?? 0,
        distanceInMeters: act.distanceInMeters ?? 0,
        averageHeartRateInBeatsPerMinute: act.averageHeartRateInBeatsPerMinute ?? null,
        averageSpeedInMetersPerSecond: act.averageSpeedInMetersPerSecond ?? null,
        calories: act.calories ?? null,
        userId: uid,
      });
    }
  }

  // Garmin vyžaduje 200 OK – jinak to zopakuje
  res.status(200).json({ success: true });
});

// Garmin ověřuje webhook pomocí GET před registrací
app.get('/webhook/garmin/activities', (_req, res) => {
  res.status(200).json({ success: true });
});

app.listen(PORT, () => {
  console.log(`BikeTrack backend běží na portu ${PORT}`);
  console.log(`Garmin OAuth callback: ${BACKEND_URL}/auth/garmin/callback`);
  console.log(`Garmin webhook: ${BACKEND_URL}/webhook/garmin/activities`);
});
