import { describe, it, expect } from 'vitest';
import en from 'dashboard/i18n/locale/en/conversation.json';
import kk from 'dashboard/i18n/locale/kk/conversation.json';
import ru from 'dashboard/i18n/locale/ru/conversation.json';
import {
  DRAFTING_IDLE_MS,
  MIN_STAGE_DWELL_MS,
  SLOW_HINT_AFTER_MS,
  SLOW_HINT_TEXT_KEY,
  STAGE,
  STAGE_VIEW,
  deriveStage,
  stageForTool,
} from '../captain/suggestionStages';

// The shape the backend sends (Captain::ToolTraceBuilder.step): one step per
// event of a tool call. Arguments and results are in input/output.
const step = (tool, event, extra = {}) => ({
  id: `${tool}:${event}:1:call-${tool}`,
  type: 'captain_tool_event',
  tool_name: tool,
  event,
  status: event === 'complete' ? 'finish' : event,
  content: `${event} ${tool}`,
  tool_call_id: `call-${tool}`,
  current_agent: 'Диана',
  ...extra,
});

const progress = (phase, steps = [], extra = {}) => ({
  phase,
  suggestion_request_id: 'sr-1',
  status: 'running',
  captain_trace: { version: 1, tool_steps: steps },
  ...extra,
});

const keyOf = (...args) => deriveStage(...args).key;

describe('suggestionStages: the stage of a progress event', () => {
  it('says the run is queued whatever else the event carries', () => {
    const busy = progress('tool_running', [
      step('search_available_slots', 'start'),
    ]);

    expect(keyOf(busy, { queued: true })).toBe(STAGE.QUEUED);
    expect(keyOf(null, { queued: true })).toBe(STAGE.QUEUED);
  });

  it('starts with «analyzing» before any event arrived', () => {
    expect(deriveStage(null)).toEqual({
      key: STAGE.ANALYZING,
      afterTools: false,
    });
    expect(deriveStage(undefined)).toEqual({
      key: STAGE.ANALYZING,
      afterTools: false,
    });
    expect(deriveStage({})).toEqual({
      key: STAGE.ANALYZING,
      afterTools: false,
    });
  });

  it.each(['starting', 'routing', 'thinking', 'handoff'])(
    'shows «analyzing» in the %s phase',
    phase => {
      expect(deriveStage(progress(phase))).toEqual({
        key: STAGE.ANALYZING,
        afterTools: false,
      });
    }
  );

  it('shows «analyzing» for a phase it does not know', () => {
    expect(keyOf(progress('something_new'))).toBe(STAGE.ANALYZING);
  });

  describe('a running tool', () => {
    const TOOLS = {
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
        'search_available_slots',
        'get_scheduling_resource_availability',
        'get_scheduling_resource_schedule',
      ],
      [STAGE.PATIENT]: [
        'get_my_contact',
        'get_contact',
        'search_contacts',
        'update_contact',
        'update_my_contact',
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
      [STAGE.TOOL]: ['add_private_note', 'some_future_tool'],
    };

    const cases = Object.entries(TOOLS).flatMap(([stage, tools]) =>
      tools.map(tool => [tool, stage])
    );

    it.each(cases)('maps %s to «%s»', (tool, stage) => {
      expect(stageForTool(tool)).toBe(stage);
      expect(keyOf(progress('tool_running', [step(tool, 'start')]))).toBe(
        stage
      );
    });

    it.each([['start'], ['progress']])(
      'counts a %s step as running (the statuses the run really sends)',
      event => {
        const live = progress('tool_running', [
          step('faq_lookup', 'complete'),
          step('search_available_slots', event),
        ]);

        expect(deriveStage(live)).toEqual({
          key: STAGE.SLOTS,
          afterTools: false,
        });
      }
    );

    it('follows the call that is still running when another one is done', () => {
      const live = progress('tool_running', [
        step('faq_lookup', 'start'),
        step('search_scheduling_services', 'start'),
        step('faq_lookup', 'complete'),
      ]);

      expect(keyOf(live)).toBe(STAGE.SERVICES);
    });

    it('keeps the stage of the last tool when it has just finished', () => {
      const live = progress('tool_running', [
        step('search_available_slots', 'start'),
        step('search_available_slots', 'complete'),
      ]);

      expect(deriveStage(live)).toEqual({
        key: STAGE.SLOTS,
        afterTools: true,
      });
    });

    it('treats a failed tool as finished', () => {
      const live = progress('tool_running', [
        step('web_search', 'start'),
        step('web_search', 'failed'),
      ]);

      expect(deriveStage(live)).toEqual({ key: STAGE.WEB, afterTools: true });
    });

    it('tells the same tool called twice apart', () => {
      const first = step('faq_lookup', 'start', { tool_call_id: 'a' });
      const firstDone = step('faq_lookup', 'complete', { tool_call_id: 'a' });
      const second = step('faq_lookup', 'start', { tool_call_id: 'b' });

      expect(
        deriveStage(progress('tool_running', [first, firstDone, second]))
      ).toEqual({ key: STAGE.KNOWLEDGE, afterTools: false });
    });

    it('starts a new call of a tool that has no call id once the first ended', () => {
      const bare = (event, extra = {}) =>
        step('faq_lookup', event, { tool_call_id: undefined, ...extra });

      expect(
        deriveStage(
          progress('tool_running', [
            bare('start'),
            bare('complete'),
            bare('start'),
          ])
        )
      ).toEqual({ key: STAGE.KNOWLEDGE, afterTools: false });
    });

    it('falls back to «tool» when the phase says a tool runs but no trace came', () => {
      expect(
        deriveStage({ phase: 'tool_running', captain_trace: null })
      ).toEqual({ key: STAGE.TOOL, afterTools: false });
    });

    it('reads the grouped calls when there are no raw steps', () => {
      const grouped = {
        phase: 'tool_running',
        captain_trace: {
          tool_calls: [
            { tool_name: 'faq_lookup', status: 'completed' },
            { tool_name: 'search_available_slots', status: 'partial' },
          ],
        },
      };

      expect(deriveStage(grouped)).toEqual({
        key: STAGE.SLOTS,
        afterTools: false,
      });
    });

    it('never needs the arguments or the results of a tool', () => {
      const withData = progress('tool_running', [
        step('get_my_contact', 'start', {
          input: { name: 'Асель Серикова', phone: '+7 700 000 00 00' },
        }),
      ]);
      const withoutData = progress('tool_running', [
        step('get_my_contact', 'start'),
      ]);

      expect(deriveStage(withData)).toEqual(deriveStage(withoutData));
      expect(Object.keys(deriveStage(withData)).sort()).toEqual([
        'afterTools',
        'key',
      ]);
    });
  });

  describe('after the tools', () => {
    it('shows «analyzing» when the model thinks again after a lookup, and says tools ran', () => {
      const live = progress('thinking', [
        step('search_available_slots', 'start'),
        step('search_available_slots', 'complete'),
      ]);

      expect(deriveStage(live)).toEqual({
        key: STAGE.ANALYZING,
        afterTools: true,
      });
    });

    it('does not say tools ran when none was called', () => {
      expect(deriveStage(progress('thinking')).afterTools).toBe(false);
    });

    it('shows «booking» while a booking tool runs', () => {
      const live = progress('tool_running', [
        step('create_appointment', 'start'),
      ]);

      expect(keyOf(live)).toBe(STAGE.BOOKING);
    });

    it('moves on to «drafting» at once when a booking tool is done', () => {
      const done = [
        step('create_appointment', 'start'),
        step('create_appointment', 'complete'),
      ];

      expect(deriveStage(progress('tool_running', done))).toEqual({
        key: STAGE.DRAFTING,
        afterTools: false,
      });
      expect(keyOf(progress('thinking', done))).toBe(STAGE.DRAFTING);
    });

    it('goes back to the tool stage when another tool starts after a booking', () => {
      const live = progress('tool_running', [
        step('create_appointment', 'start'),
        step('create_appointment', 'complete'),
        step('faq_lookup', 'start'),
      ]);

      expect(keyOf(live)).toBe(STAGE.KNOWLEDGE);
    });
  });

  describe('a council of specialists', () => {
    const council = (...statuses) => ({
      active: true,
      parts: statuses.map((status, index) => ({
        id: index + 1,
        status,
        agent: { id: index + 10, name: 'Сезім' },
      })),
    });

    it('shows «council» while parts work, with no parts yet and with a part still planned', () => {
      expect(keyOf(progress('council_running'))).toBe(STAGE.COUNCIL);
      expect(
        keyOf(progress('council_running', [], { council: council('running') }))
      ).toBe(STAGE.COUNCIL);
      expect(
        keyOf(
          progress('council_running', [], {
            council: council('answered', 'planned'),
          })
        )
      ).toBe(STAGE.COUNCIL);
    });

    it('shows «council» for a tool that runs inside a part, not the tool', () => {
      const live = progress(
        'council_running',
        [step('search_available_slots', 'start')],
        { council: council('running') }
      );

      expect(keyOf(live)).toBe(STAGE.COUNCIL);
    });

    it.each([['answered'], ['done'], ['needs_information'], ['out_of_scope']])(
      'shows «council_edit» when every part is settled (%s)',
      status => {
        expect(
          keyOf(
            progress('council_running', [], {
              council: council('answered', status),
            })
          )
        ).toBe(STAGE.COUNCIL_EDIT);
      }
    );

    it('keeps «council_edit» while the main answer is put together after the parts', () => {
      const live = progress('thinking', [], {
        council: council('answered', 'answered'),
      });

      expect(keyOf(live)).toBe(STAGE.COUNCIL_EDIT);
    });
  });

  it('never returns a stage the view does not know', () => {
    const phases = [
      'starting',
      'routing',
      'thinking',
      'tool_running',
      'council_running',
      'handoff',
      'nonsense',
    ];
    phases.forEach(phase => {
      expect(STAGE_VIEW[keyOf(progress(phase))]).toBeDefined();
    });
  });
});

describe('suggestionStages: the texts', () => {
  const stages = Object.values(STAGE);

  it('has a view for every stage with a hue and a tempo for the orb', () => {
    expect(Object.keys(STAGE_VIEW).sort()).toEqual([...stages].sort());
    stages.forEach(stage => {
      expect(['blue', 'teal', 'sky', 'pale']).toContain(STAGE_VIEW[stage].hue);
      expect(STAGE_VIEW[stage].tempo).toBeGreaterThan(0);
    });
  });

  it('keeps the timing rules in one place', () => {
    expect(MIN_STAGE_DWELL_MS).toBe(800);
    expect(DRAFTING_IDLE_MS).toBe(2500);
    expect(SLOW_HINT_AFTER_MS).toBe(30000);
  });

  const lookup = (messages, key) =>
    key.split('.').reduce((node, part) => node?.[part], messages);

  describe.each([
    ['ru', ru],
    ['en', en],
    ['kk', kk],
  ])('in %s', (_locale, messages) => {
    it('has a sentence for every stage and for the slow hint', () => {
      [
        ...stages.map(stage => STAGE_VIEW[stage].text),
        SLOW_HINT_TEXT_KEY,
      ].forEach(key => {
        const text = lookup({ CONVERSATION: messages.CONVERSATION }, key);
        expect(typeof text, key).toBe('string');
        expect(text.length, key).toBeGreaterThan(5);
      });
    });

    it('starts every stage sentence with «AI» and ends it with an ellipsis', () => {
      stages.forEach(stage => {
        const text = lookup(
          { CONVERSATION: messages.CONVERSATION },
          STAGE_VIEW[stage].text
        );
        expect(text.startsWith('AI '), text).toBe(true);
        expect(text.endsWith('…'), text).toBe(true);
      });
    });

    it('names no agent, tool, model or router in the staff texts', () => {
      const TECHNICAL =
        /агент|agent|инструмент|\btools?\b|модел|\bmodel\b|маршрутиз|router|routing|консилиум|council|faq_|search_|json|api\b/i;
      const { COPILOT_STAGE, COPILOT_SUGGESTION, COPILOT_TRACE } =
        messages.CONVERSATION.REPLYBOX;
      const shown = [
        ...Object.values(COPILOT_STAGE),
        COPILOT_SUGGESTION.INSERT,
        COPILOT_SUGGESTION.CANCEL,
        COPILOT_SUGGESTION.LEGACY_ENGINE,
        ...Object.values(COPILOT_SUGGESTION.NOTICE).filter(
          value => typeof value === 'string'
        ),
        COPILOT_TRACE.ACTION_SUGGESTS,
        COPILOT_TRACE.ACTION_SUGGESTS_DEFAULT,
      ];

      shown.forEach(text => expect(text).not.toMatch(TECHNICAL));
    });
  });
});
