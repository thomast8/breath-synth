// Transcribed from Sources/BreathEnrollApp/EnrollmentScript.swift (the native app's source of
// truth) — prompts are verbatim except where noted. Keep this in sync by inspection if the native
// script changes; `SCRIPT_VERSION` is stamped onto every session so a mismatch is at least visible
// in the data later, not silently blended.
//
// One structural difference from the native script, forced by what the server-side grading code
// actually supports: `Segmenter`'s "texture" role (`Sources/BreathBank/Segmenter.swift`) grades a
// whole uploaded take as already isolated to one phase — there is no server-side equivalent of the
// native `CaptureAnalyzer`'s live mid-pause cycle split (that lives only in the native app's
// real-time capture path, which nothing here reuses). So unlike the native single continuous
// inhale-pause-exhale recording, calm here is two separate takes (inhale, then exhale), each
// recorded on its own. FRC/RV/packing/recovery need no such split — `trimToMainBody` (oneShotBody)
// and the cores/gaps extractors (`UnitExtractor`) already operate correctly on one whole continuous
// recording, so those record hands-free through the full maneuver exactly like the native app.
export const SCRIPT_VERSION = "web-v1";

export type BreathType = "inhale" | "exhale";
export type RenderMode = "textured" | "oneShot" | "counted";

export interface Lane {
  /// `captures.json` slug — also the object-storage/export filename prefix.
  slug: string;
  style: string;
  type: BreathType;
  renderMode: RenderMode;
  /// Builder role: "texture" (calm), "oneShotBody" (frc/rv), "cores" / "gaps" (counted).
  role: string;
  /// Gold reference WAV filename in web/server/Resources/gold-refs, or null (recovery has none).
  reference: string | null;
}

export interface Step {
  id: string;
  title: string;
  prompt: string;
  /// Demo audio filename under /demo (AAC, transcoded from the native reference for browser
  /// playback) — distinct from the server's WAV gold-refs used for grading.
  demoReference: string | null;
  takes: number;
  minSeconds: number;
  maxSeconds: number;
  targetEvents: number | null;
  /// Every take recorded for this step is uploaded once per lane here (same audio, different
  /// role/slug) — packing's cores+gaps share one recording exactly as the native app pools them.
  lanes: Lane[];
}

export const STEPS: Step[] = [
  {
    id: "calm_inhale",
    title: "Calm breathing — inhale",
    // Adapted from the native cycle prompt (see file header) since this records inhale and exhale
    // as separate takes rather than one continuous cycle.
    prompt:
      "Breathe in slow and relaxed — a smooth, natural resting inhale, nothing forced. " +
      "Repeat a few times, each one about 8–12 s.",
    demoReference: "calm_inhale.m4a",
    takes: 3,
    minSeconds: 4,
    maxSeconds: 15,
    targetEvents: null,
    lanes: [
      { slug: "calm_inhale", style: "calm", type: "inhale", renderMode: "textured", role: "texture", reference: "calm_inhale.wav" },
    ],
  },
  {
    id: "calm_exhale",
    title: "Calm breathing — exhale",
    prompt:
      "Now the exhale — breathe out slow and relaxed, the same natural pace as the inhale. " +
      "Repeat a few times, each one about 8–12 s.",
    demoReference: "calm_exhale.m4a",
    takes: 3,
    minSeconds: 4,
    maxSeconds: 15,
    targetEvents: null,
    lanes: [
      { slug: "calm_exhale", style: "calm", type: "exhale", renderMode: "textured", role: "texture", reference: "calm_exhale.wav" },
    ],
  },
  {
    id: "frc_exhale",
    title: "FRC exhale",
    prompt:
      "Inhale, hold a beat, then let it fall out passively to a relaxed (FRC) volume — " +
      "don't hold it out longer than feels natural. Breathe normally between takes.",
    demoReference: "frc_1.m4a",
    takes: 4,
    minSeconds: 0.7,
    maxSeconds: 6,
    targetEvents: null,
    lanes: [
      { slug: "frc_exhale", style: "frc", type: "exhale", renderMode: "oneShot", role: "oneShotBody", reference: "frc_1.wav" },
    ],
  },
  {
    id: "rv_exhale",
    title: "RV exhale",
    prompt:
      "Inhale, hold a beat, then force it all the way out to residual volume — as much as you can " +
      "manage, not a specific count. Recover normally between takes.",
    demoReference: "rv.m4a",
    takes: 3,
    minSeconds: 3,
    maxSeconds: 11,
    targetEvents: null,
    lanes: [
      { slug: "rv_exhale", style: "rv", type: "exhale", renderMode: "oneShot", role: "oneShotBody", reference: "rv.wav" },
    ],
  },
  {
    id: "packing",
    title: "Packing",
    prompt:
      "Pack at your NATURAL rhythm — continuous, real-cadence packing. Whatever lung fill is " +
      "comfortable is fine, it doesn't need to be full. Reset between takes.",
    demoReference: "packing_2.m4a",
    takes: 2,
    minSeconds: 8,
    maxSeconds: 25,
    targetEvents: null,
    lanes: [
      { slug: "packing_cadence", style: "packing", type: "inhale", renderMode: "counted", role: "gaps", reference: "packing_2.wav" },
      { slug: "packing_cadence", style: "packing", type: "inhale", renderMode: "counted", role: "cores", reference: "packing_2.wav" },
    ],
  },
  {
    id: "recovery_separated",
    title: "Recovery — separated",
    prompt:
      "Recovery hook breaths: each one is a quick inhale then exhale — like calm breathing sped " +
      "way up. Breathe IN, breathe OUT, that's one hook. Do 3 hooks with a clearly deliberate pause " +
      "between each — even if your real post-hold pace has less gap than that — so the app gets " +
      "clean isolated examples. Breathe out between takes.",
    demoReference: null,
    takes: 2,
    minSeconds: 3,
    maxSeconds: 15,
    targetEvents: 3,
    lanes: [
      { slug: "recovery_separated", style: "recovery", type: "inhale", renderMode: "counted", role: "cores", reference: null },
    ],
  },
  {
    id: "recovery_cadence",
    title: "Recovery — natural rhythm",
    prompt:
      "Now do the same hook breaths, but at whatever pace is actually natural for you post-hold — " +
      "tight back-to-back or more spaced out, whichever you'd really do. This step wants your real " +
      "rhythm, not the deliberate pause from the last step.",
    demoReference: null,
    takes: 2,
    minSeconds: 3,
    maxSeconds: 20,
    targetEvents: null,
    lanes: [
      { slug: "recovery_cadence", style: "recovery", type: "inhale", renderMode: "counted", role: "gaps", reference: null },
    ],
  },
];
