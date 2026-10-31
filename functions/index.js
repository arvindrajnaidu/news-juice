// News Lens's one server function: reads a paragraph of a filtered article aloud with
// OpenAI's steerable speech model and returns the audio.
//
// - The OpenAI key lives in Secret Manager (OPENAI_API_KEY); the app never sees it.
// - Only the real app gets in: every request carries a Firebase App Check token
//   (App Attest on devices, a registered debug token in the Simulator).
// - Each install has a daily allowance, counted in Firestore by the install's random id.
// - Readings are cached, shared between listeners, in a private bucket (no public
//   access; only this function reads it) and deleted after 30 days by a lifecycle rule.
//   The key is a hash of everything that shapes the audio, so a cached reading is
//   exactly what a fresh one would be; cache hits cost nothing and aren't counted.
const crypto = require('crypto');
const { onRequest } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

admin.initializeApp();
const OPENAI_API_KEY = defineSecret('OPENAI_API_KEY');

const MODEL = 'gpt-4o-mini-tts';
const CACHE_BUCKET = 'news-lens-4ea95-tts-cache';
// Bump to start a fresh cache (say, after changing the model's output format).
const CACHE_VERSION = 1;
const MAX_CHARS = 4000;
// About 30 minutes of speech a day per install (roughly 15 characters a second).
const DAILY_CHARS = 27000;

const VOICE = 'coral';
// Voices a request may ask for instead (for comparing them).
const VOICES = ['alloy', 'ash', 'ballad', 'coral', 'echo', 'fable', 'nova', 'onyx', 'sage', 'shimmer', 'verse'];
const INSTRUCTIONS = [
  'Voice: a professional broadcast news anchor, like a primetime TV news presenter:',
  'authoritative, clear and confident.',
  'Delivery: crisp diction and a measured newsroom cadence; give names, places and numbers',
  'a little weight; land the end of each sentence firmly.',
  'Tone: composed and serious for hard news, conflict or loss; a touch warmer for lighter',
  'stories. Never casual, never dramatic.',
  'Pauses: short and deliberate between sentences.',
  'Read the text exactly as written; do not add or skip words.',
].join(' ');
const HEADLINE = ' This is a headline: deliver it like the top of a bulletin, clear and punchy, with slight emphasis.';

// Each paragraph is a separate request; naming the story keeps the delivery consistent.
function context(story, site) {
  const clean = (v, n) => (typeof v === 'string' ? v.replace(/["\n\r]+/g, ' ').trim().slice(0, n) : '');
  const title = clean(story, 200);
  const from = clean(site, 80);
  if (!title) return '';
  return ` You are reading the story "${title}"${from ? ` from ${from}` : ''}; keep the same anchor delivery across every paragraph of it.`;
}

exports.speak = onRequest(
  { region: 'us-central1', secrets: [OPENAI_API_KEY], maxInstances: 10, timeoutSeconds: 60, memory: '256MiB' },
  async (req, res) => {
    if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });

    try {
      await admin.appCheck().verifyToken(req.get('X-Firebase-AppCheck') || '');
    } catch (e) {
      return res.status(401).json({ error: 'app check' });
    }

    const device = req.get('X-NL-Device') || '';
    const { text, head, voice, story, site } = req.body || {};
    if (!/^[A-Za-z0-9-]{16,64}$/.test(device)) return res.status(400).json({ error: 'device' });
    if (typeof text !== 'string' || !text.trim() || text.length > MAX_CHARS) {
      return res.status(400).json({ error: 'text' });
    }

    const spoken = text.replace(/\s+/g, ' ').trim();
    const chosen = VOICES.includes(voice) ? voice : VOICE;
    const instructions = INSTRUCTIONS + context(story, site) + (head ? HEADLINE : '');
    const key = crypto.createHash('sha256')
      .update(JSON.stringify([CACHE_VERSION, MODEL, chosen, instructions, spoken]))
      .digest('hex');
    const cached = admin.storage().bucket(CACHE_BUCKET).file(`tts-cache/${key}.mp3`);

    const [hit] = await cached.exists();
    if (hit) {
      logger.info('speak cache', { cache: 'hit', chars: spoken.length });
      const [audio] = await cached.download();
      return sendAudio(res, audio, 'hit');
    }

    // Count it against today's allowance before spending anything.
    const day = new Date().toISOString().slice(0, 10);
    const ref = admin.firestore().doc(`usage/${day}_${device}`);
    const allowed = await admin.firestore().runTransaction(async (t) => {
      const snap = await t.get(ref);
      const used = snap.exists ? snap.get('chars') : 0;
      if (used + spoken.length > DAILY_CHARS) return false;
      t.set(ref, { chars: used + spoken.length, day }, { merge: true });
      return true;
    });
    if (!allowed) return res.status(429).json({ error: 'daily limit' });

    const reply = await fetch('https://api.openai.com/v1/audio/speech', {
      method: 'POST',
      headers: { Authorization: `Bearer ${OPENAI_API_KEY.value()}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: MODEL,
        voice: chosen,
        input: spoken,
        instructions,
        response_format: 'mp3',
      }),
    });
    if (!reply.ok) {
      logger.error('OpenAI speech failed', reply.status, await reply.text());
      // Nothing was read, so give the allowance back.
      await ref.set({ chars: admin.firestore.FieldValue.increment(-spoken.length) }, { merge: true });
      return res.status(502).json({ error: 'voice' });
    }
    const audio = Buffer.from(await reply.arrayBuffer());
    await cached.save(audio, { contentType: 'audio/mpeg', resumable: false })
      .catch((e) => logger.warn('speak cache write failed', e.message));
    logger.info('speak cache', { cache: 'miss', chars: spoken.length });
    return sendAudio(res, audio, 'miss');
  }
);

function sendAudio(res, audio, cache) {
  res.set('Content-Type', 'audio/mpeg');
  res.set('Cache-Control', 'no-store');
  res.set('X-NL-Cache', cache);
  return res.send(audio);
}
