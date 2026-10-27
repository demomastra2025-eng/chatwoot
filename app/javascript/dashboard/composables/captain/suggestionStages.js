// What the manager sees while «Предложить ответ» works: one plain sentence
// («AI проверяет базу знаний…») instead of agent names, tools and statuses.
// The stage is derived from what the progress events already carry: the
// phase, the tool calls of the trace and the parts of a council. Nothing from
// the arguments or results of a tool (patient data lives there) is read.

// Every stage shows for at least this long, so fast steps do not flicker.
export const MIN_STAGE_DWELL_MS = 800;
// The backend never says that the model is writing the text. After the tools
// are done and no event arrives for this long, the model is writing it.
export const DRAFTING_IDLE_MS = 2500;
// After this long a calm second line says that the wait is longer than usual.
export const SLOW_HINT_AFTER_MS = 30000;

export const STAGE = Object.freeze({
  QUEUED: 'queued',
  ANALYZING: 'analyzing',
  KNOWLEDGE: 'knowledge',
  SERVICES: 'services',
  SPECIALIST: 'specialist',
  SLOTS: 'slots',
  PATIENT: 'patient',
  WEB: 'web',
  BOOKING: 'booking',
  STAFF: 'staff',
  COUNCIL: 'council',
  COUNCIL_EDIT: 'council_edit',
  TOOL: 'tool',
  DRAFTING: 'drafting',
});

const KEY_PREFIX = 'CONVERSATION.REPLYBOX.COPILOT_STAGE';

// text: the i18n key of the sentence. The orb next to it is the same for every
// stage; only the sentence says what the step is.
export const STAGE_VIEW = Object.freeze({
  [STAGE.QUEUED]: { text: `${KEY_PREFIX}.QUEUED` },
  [STAGE.ANALYZING]: { text: `${KEY_PREFIX}.ANALYZING` },
  [STAGE.KNOWLEDGE]: { text: `${KEY_PREFIX}.KNOWLEDGE` },
  [STAGE.SERVICES]: { text: `${KEY_PREFIX}.SERVICES` },
  [STAGE.SPECIALIST]: { text: `${KEY_PREFIX}.SPECIALIST` },
  [STAGE.SLOTS]: { text: `${KEY_PREFIX}.SLOTS` },
  [STAGE.PATIENT]: { text: `${KEY_PREFIX}.PATIENT` },
  [STAGE.WEB]: { text: `${KEY_PREFIX}.WEB` },
  [STAGE.BOOKING]: { text: `${KEY_PREFIX}.BOOKING` },
  [STAGE.STAFF]: { text: `${KEY_PREFIX}.STAFF` },
  [STAGE.COUNCIL]: { text: `${KEY_PREFIX}.COUNCIL` },
  [STAGE.COUNCIL_EDIT]: { text: `${KEY_PREFIX}.COUNCIL_EDIT` },
  [STAGE.TOOL]: { text: `${KEY_PREFIX}.TOOL` },
  [STAGE.DRAFTING]: { text: `${KEY_PREFIX}.DRAFTING` },
});

export const SLOW_HINT_TEXT_KEY = `${KEY_PREFIX}.SLOW`;

const STAGE_BY_TOOL = new Map(
  Object.entries({
    [STAGE.KNOWLEDGE]: [
      'faq_lookup',
      'search_documentation',
      'list_captain_documents',
      'search_articles',
      'get_article',
    ],
    [STAGE.SERVICES]: ['search_scheduling_services'],
    [STAGE.SPECIALIST]: [
      'search_scheduling_resources',
      'list_scheduling_resources',
    ],
    [STAGE.SLOTS]: [
      'search_booking_options',
      'search_available_slots',
      'get_scheduling_resource_availability',
      'get_scheduling_resource_schedule',
    ],
    [STAGE.PATIENT]: [
      'get_my_contact',
      'get_contact',
      'search_contacts',
      'list_my_appointments',
      'get_appointment',
      'search_appointments',
      'list_appointment_custom_fields',
    ],
    [STAGE.WEB]: ['web_search', 'web_scrape_url'],
    [STAGE.BOOKING]: [
      'create_appointment',
      'update_appointment',
      'cancel_appointment',
    ],
    [STAGE.STAFF]: ['handoff'],
  }).flatMap(([stage, tools]) => tools.map(tool => [tool, stage]))
);

// update_contact, update_my_contact and the like
const CONTACT_UPDATE_TOOL = /^update_\w*contact$/;

export const stageForTool = toolName => {
  const name = String(toolName || '')
    .trim()
    .toLowerCase();
  if (!name) return STAGE.TOOL;
  if (STAGE_BY_TOOL.has(name)) return STAGE_BY_TOOL.get(name);
  if (CONTACT_UPDATE_TOOL.test(name)) return STAGE.PATIENT;
  return STAGE.TOOL;
};

const FINISHED_STATUSES = new Set([
  'finish',
  'finished',
  'complete',
  'completed',
  'success',
  'failed',
  'error',
  'suppressed',
]);

const STARTING_STATUSES = new Set(['start', 'started']);

const stepName = step =>
  String(step?.tool_name || step?.toolName || step?.function_name || '').trim();

const stepStatus = step =>
  String(step?.status || step?.event || 'progress').toLowerCase();

const stepCallId = step =>
  String(step?.tool_call_id || step?.toolCallId || '').trim();

// The tool calls of the run in the order they began: { name, running }. The raw
// steps are read first (they are what the run reports as it goes); the grouped
// calls only when the steps are absent.
const toolCallsOf = trace => {
  if (!trace || typeof trace !== 'object') return [];

  const steps = trace.tool_steps || trace.toolSteps;
  if (Array.isArray(steps) && steps.length) {
    const calls = [];
    const open = new Map();
    steps.forEach(step => {
      const name = stepName(step);
      if (!name) return;
      const key = `${name}:${stepCallId(step)}`;
      const status = stepStatus(step);
      let call = open.get(key);
      if (!call || (STARTING_STATUSES.has(status) && !call.running)) {
        call = { name, running: true };
        open.set(key, call);
        calls.push(call);
      }
      call.running = !FINISHED_STATUSES.has(status);
    });
    return calls;
  }

  const grouped = trace.tool_calls || trace.toolCalls;
  if (Array.isArray(grouped)) {
    return grouped
      .map(call => ({
        name: stepName(call),
        running: !FINISHED_STATUSES.has(stepStatus(call)),
      }))
      .filter(call => call.name);
  }
  return [];
};

const COUNCIL_ACTIVE_STATUSES = new Set(['planned', 'running']);

const councilOf = council => {
  const parts = Array.isArray(council?.parts) ? council.parts : [];
  return {
    hasParts: parts.length > 0,
    isWorking: parts.some(part =>
      COUNCIL_ACTIVE_STATUSES.has(String(part?.status || 'planned'))
    ),
  };
};

/**
 * Maps one progress payload (captain.reply_suggestion.progress) to the stage
 * the manager sees.
 *
 * @param {Object|null} progress - the payload: phase, captain_trace, council…
 * @param {Object} [options]
 * @param {boolean} [options.queued] - the run waits in the queue
 * @returns {{key: string, afterTools: boolean}} key is a STAGE; afterTools says
 *   that tools have run and none is running now, so the next quiet moment is
 *   the model writing the text (the dwell composable turns it into «drafting»)
 */
export const deriveStage = (progress, { queued = false } = {}) => {
  if (queued) return { key: STAGE.QUEUED, afterTools: false };

  const payload = progress && typeof progress === 'object' ? progress : {};
  const phase = String(payload.phase || '');
  const calls = toolCallsOf(payload.captain_trace || payload.captainTrace);
  const running = calls.filter(call => call.running);
  const lastRunning = running[running.length - 1];
  const lastCall = calls[calls.length - 1];
  const council = councilOf(payload.council);

  if (phase === 'council_running') {
    const key =
      council.hasParts && !council.isWorking
        ? STAGE.COUNCIL_EDIT
        : STAGE.COUNCIL;
    return { key, afterTools: false };
  }

  // A booking tool is done: the card waits for approval and the model writes
  // the text around it.
  if (
    lastCall &&
    !lastRunning &&
    stageForTool(lastCall.name) === STAGE.BOOKING
  ) {
    return { key: STAGE.DRAFTING, afterTools: false };
  }

  if (phase === 'tool_running') {
    const current = lastRunning || lastCall;
    return {
      key: current ? stageForTool(current.name) : STAGE.TOOL,
      afterTools: Boolean(lastCall) && !lastRunning,
    };
  }

  // The council parts are ready and the main answer is being put together
  if (council.hasParts && !council.isWorking && phase === 'thinking') {
    return { key: STAGE.COUNCIL_EDIT, afterTools: false };
  }

  return {
    key: STAGE.ANALYZING,
    afterTools: Boolean(lastCall) && !lastRunning,
  };
};
