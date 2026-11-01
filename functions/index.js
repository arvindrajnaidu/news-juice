// News Lens's one server function: reads a paragraph of a filtered article aloud with a
// steerable speech model and returns the audio. PROVIDER picks the model:
// - 'gemini': Gemini Flash TTS through Google Cloud Text-to-Speech, called as this
//   function's own service account (no key).
// - 'openai': OpenAI's gpt-4o-mini-tts; its key lives in Secret Manager (OPENAI_API_KEY).
// The app never sees a key either way.
//
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

const PROVIDER = 'gemini';
const PROVIDERS = {
  gemini: {
    model: 'gemini-2.5-flash-tts',
    voice: 'Kore',
    // Voices a request may ask for instead (for comparing them).
    voices: ['Kore', 'Aoede', 'Leda', 'Zephyr', 'Charon', 'Puck', 'Fenrir', 'Orus'],
    // Gemini reads long directions aloud, so it gets one short line.
    direct: (head) => `Read this as a calm, authoritative TV news anchor${head ? ' announcing a headline' : ''}.`,
    speak: geminiSpeak,
  },
  openai: {
    model: 'gpt-4o-mini-tts',
    voice: 'coral',
    voices: ['alloy', 'ash', 'ballad', 'coral', 'echo', 'fable', 'nova', 'onyx', 'sage', 'shimmer', 'verse'],
    direct: (head, story, site) => INSTRUCTIONS + context(story, site) + (head ? HEADLINE : ''),
    speak: openaiSpeak,
  },
};
const CACHE_BUCKET = 'news-lens-4ea95-tts-cache';
// Bump to start a fresh cache (say, after changing the model's output format).
const CACHE_VERSION = 1;
const MAX_CHARS = 4000;
// About 30 minutes of speech a day per install (roughly 15 characters a second).
const DAILY_CHARS = 27000;

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
    const { text, head, voice, story, site, lang } = req.body || {};
    if (!/^[A-Za-z0-9-]{16,64}$/.test(device)) return res.status(400).json({ error: 'device' });
    if (typeof text !== 'string' || !text.trim() || text.length > MAX_CHARS) {
      return res.status(400).json({ error: 'text' });
    }

    const spoken = text.replace(/\s+/g, ' ').trim();
    const provider = PROVIDERS[PROVIDER];
    const chosen = provider.voices.includes(voice) ? voice : provider.voice;
    const language = LANGUAGES[lang] || 'en-US';
    const instructions = provider.direct(head, story, site);
    const key = crypto.createHash('sha256')
      .update(JSON.stringify([CACHE_VERSION, PROVIDER, provider.model, chosen, language, instructions, spoken]))
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

    let audio;
    try {
      audio = await provider.speak({ model: provider.model, voice: chosen, language, instructions, text: spoken });
    } catch (e) {
      logger.error('speech failed', PROVIDER, e.message);
      // Nothing was read, so give the allowance back.
      await ref.set({ chars: admin.firestore.FieldValue.increment(-spoken.length) }, { merge: true });
      return res.status(502).json({ error: 'voice' });
    }
    await cached.save(audio, { contentType: 'audio/mpeg', resumable: false })
      .catch((e) => logger.warn('speak cache write failed', e.message));
    logger.info('speak cache', { cache: 'miss', chars: spoken.length });
    return sendAudio(res, audio, 'miss');
  }
);

// The page's language (from the app) as a speech locale; anything else reads as en-US.
const LANGUAGES = {
  en: 'en-US', hi: 'hi-IN', bn: 'bn-IN', ta: 'ta-IN', te: 'te-IN', mr: 'mr-IN', gu: 'gu-IN',
  kn: 'kn-IN', ml: 'ml-IN', ur: 'ur-PK', ar: 'ar-EG', fr: 'fr-FR', de: 'de-DE', es: 'es-ES',
  it: 'it-IT', pt: 'pt-BR', nl: 'nl-NL', ja: 'ja-JP', ko: 'ko-KR', zh: 'cmn-CN',
};

async function geminiSpeak({ model, voice, language, instructions, text }) {
  // This function's own service account, from the metadata server.
  const auth = await fetch(
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token',
    { headers: { 'Metadata-Flavor': 'Google' } }
  ).then((r) => r.json());
  const reply = await fetch('https://texttospeech.googleapis.com/v1/text:synthesize', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${auth.access_token}`,
      'Content-Type': 'application/json',
      'x-goog-user-project': process.env.GCLOUD_PROJECT || 'news-lens-4ea95',
    },
    body: JSON.stringify({
      input: { prompt: instructions, text },
      voice: { languageCode: language, name: voice, modelName: model },
      audioConfig: { audioEncoding: 'MP3' },
    }),
  });
  if (!reply.ok) throw new Error(`${reply.status} ${await reply.text()}`);
  return Buffer.from((await reply.json()).audioContent, 'base64');
}

async function openaiSpeak({ model, voice, instructions, text }) {
  const reply = await fetch('https://api.openai.com/v1/audio/speech', {
    method: 'POST',
    headers: { Authorization: `Bearer ${OPENAI_API_KEY.value()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, voice, input: text, instructions, response_format: 'mp3' }),
  });
  if (!reply.ok) throw new Error(`${reply.status} ${await reply.text()}`);
  return Buffer.from(await reply.arrayBuffer());
}

function sendAudio(res, audio, cache) {
  res.set('Content-Type', 'audio/mpeg');
  res.set('Cache-Control', 'no-store');
  res.set('X-NL-Cache', cache);
  return res.send(audio);
}
