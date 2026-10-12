/* eslint-disable vue/one-component-per-file */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

const testState = vi.hoisted(() => ({
  fetch: vi.fn(),
  save: vi.fn(),
  useAlert: vi.fn(),
  uiFlags: { fetchError: false, isFetching: false, isSaving: false },
  route: { params: { accountId: '1' }, hash: '' },
  leaveGuard: null,
  updateGuard: null,
  showPaywall: false,
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, te: () => true }),
}));

vi.mock('vue-router', () => ({
  useRoute: () => testState.route,
  onBeforeRouteLeave: vi.fn(guard => {
    testState.leaveGuard = guard;
  }),
  onBeforeRouteUpdate: vi.fn(guard => {
    testState.updateGuard = guard;
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => testState.useAlert(...args),
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({
    checkPermissions: () => true,
    shouldShowPaywall: () => testState.showPaywall,
  }),
}));

vi.mock('dashboard/store/captain/aiSettings', () => ({
  useCaptainAiSettingsStore: () => ({
    uiFlags: testState.uiFlags,
    fetch: (...args) => testState.fetch(...args),
    save: (...args) => testState.save(...args),
  }),
}));

vi.mock('dashboard/components-next/captain/pageComponents/Paywall.vue', () => ({
  default: defineComponent({
    name: 'CaptainPaywall',
    setup: () => () => h('div', { 'data-testid': 'paywall' }),
  }),
}));

vi.mock('dashboard/components-next/captain/PageLayout.vue', () => ({
  default: defineComponent({
    name: 'PageLayout',
    props: {
      buttonLabel: { type: String, default: '' },
      buttonDisabled: Boolean,
      isFetching: Boolean,
    },
    emits: ['click'],
    setup(props, { slots, emit }) {
      return () =>
        h('div', [
          h(
            'button',
            {
              'data-testid': 'ai-settings-save',
              disabled: props.buttonDisabled,
              onClick: () => emit('click'),
            },
            props.buttonLabel
          ),
          props.isFetching
            ? h('div', { 'data-testid': 'ai-settings-loading' })
            : slots.body?.(),
        ]);
    },
  }),
}));

const { default: AiSettingsPage } = await import('./Index.vue');

const settingsPayload = () => ({
  understanding: {
    voice_messages: true,
    images: true,
    documents: true,
    web_search: false,
    web_page_reading: false,
  },
  handoff: {
    handoff_reasons: [
      {
        id: 'customer_requested_human',
        label: 'Клиент попросил сотрудника',
        enabled: true,
        builtin: true,
      },
      { id: 'other', label: 'Другое', enabled: true, builtin: true },
    ],
    completion_reasons: [
      {
        id: 'goal_achieved',
        label: 'Цель достигнута',
        enabled: true,
        builtin: true,
      },
      { id: 'other', label: 'Другое', enabled: true, builtin: true },
    ],
    handoff_message: { enabled: true, mode: 'fixed', text: 'Передаю' },
    resolution_message: { enabled: false, mode: 'generated', text: '' },
    auto_completion_enabled: true,
    auto_reply_on_last_incoming: false,
  },
  faq: { generate_from_resolved: false },
  conversation: { message_collapse_window_seconds: 15 },
  // The server also returns platform safety values the page does not show.
  safety: {
    moderation_enabled: true,
    prompt_injection_action: 'off',
    sensitive_info_action: 'flag',
    custom_rules: [
      {
        id: 'rule-in',
        name: '',
        direction: 'inbound',
        instruction: '',
        action: 'handoff',
        enabled: true,
        message: null,
      },
    ],
  },
  availability: { web_access_configured: true },
});

const mountPage = async (payload = settingsPayload(), options = {}) => {
  testState.fetch.mockResolvedValue(payload);
  const wrapper = mount(AiSettingsPage, options);
  await flushPromises();
  return wrapper;
};

const saveButton = wrapper => wrapper.get('[data-testid="ai-settings-save"]');
const clickSave = async wrapper => {
  await saveButton(wrapper).trigger('click');
  await flushPromises();
};
const switchIn = (wrapper, testId) =>
  wrapper.get(`[data-testid="${testId}"] [role="switch"]`);
const within = (wrapper, testId) => wrapper.get(`[data-testid="${testId}"]`);
const reasonRows = (wrapper, list) =>
  within(wrapper, `outcome-section-${list}`).findAll(
    '[data-testid="outcome-reason-row"]'
  );
const SECTION_IDS = [
  'understanding',
  'handoff',
  'knowledge',
  'speed',
  'safety',
];
const originalScrollIntoView = Element.prototype.scrollIntoView;

describe('Captain AI settings page', () => {
  beforeEach(() => {
    testState.fetch.mockReset();
    testState.save.mockReset();
    testState.useAlert.mockReset();
    testState.uiFlags.fetchError = false;
    testState.route = { params: { accountId: '1' }, hash: '' };
    testState.leaveGuard = null;
    testState.updateGuard = null;
    testState.showPaywall = false;
  });

  afterEach(() => {
    vi.restoreAllMocks();
    if (originalScrollIntoView) {
      Element.prototype.scrollIntoView = originalScrollIntoView;
    } else {
      delete Element.prototype.scrollIntoView;
    }
    document.body.innerHTML = '';
  });

  it('renders all five sections from the payload with their anchors', async () => {
    const wrapper = await mountPage();

    expect(testState.fetch).toHaveBeenCalledWith({ force: false });
    SECTION_IDS.forEach(id => {
      expect(wrapper.find(`section#${id}`).exists()).toBe(true);
    });
    expect(reasonRows(wrapper, 'handoff_reasons')).toHaveLength(2);
    expect(reasonRows(wrapper, 'completion_reasons')).toHaveLength(2);
    expect(wrapper.get('#ai-settings-collapse-window').element.value).toBe(
      '15'
    );
    expect(wrapper.get('#handoff-message-text').element.value).toBe('Передаю');
    expect(saveButton(wrapper).attributes('disabled')).toBeDefined();
  });

  it('offers exactly one safety switch for all agents and nothing else', async () => {
    const wrapper = await mountPage();
    const safety = within(wrapper, 'ai-settings-safety');

    expect(safety.findAll('[role="switch"]')).toHaveLength(1);
    expect(
      switchIn(wrapper, 'safety-moderation').attributes('aria-checked')
    ).toBe('true');
    expect(safety.findAll('select, textarea')).toHaveLength(0);
    expect(safety.text()).toContain('CAPTAIN.AI_SETTINGS.SAFETY.CHECK');
    expect(wrapper.find('[data-testid="custom-rules-inbound"]').exists()).toBe(
      false
    );
    expect(wrapper.find('[data-testid="custom-rules-outbound"]').exists()).toBe(
      false
    );
    expect(wrapper.find('#ai-settings-prompt_injection_action').exists()).toBe(
      false
    );
    expect(wrapper.find('#ai-settings-sensitive_info_action').exists()).toBe(
      false
    );
  });

  it('disables the web toggles with a hint when web access is not configured', async () => {
    const payload = settingsPayload();
    payload.availability.web_access_configured = false;
    const wrapper = await mountPage(payload);

    expect(
      switchIn(wrapper, 'understanding-web_search').attributes('disabled')
    ).toBeDefined();
    expect(
      switchIn(wrapper, 'understanding-web_page_reading').attributes('disabled')
    ).toBeDefined();
    expect(
      switchIn(wrapper, 'understanding-voice_messages').attributes('disabled')
    ).toBeUndefined();
    expect(
      wrapper.findAll('[data-testid="understanding-web-hint"]')
    ).toHaveLength(2);
  });

  it('keeps the web toggles available when web access is configured', async () => {
    const wrapper = await mountPage();

    expect(
      switchIn(wrapper, 'understanding-web_search').attributes('disabled')
    ).toBeUndefined();
    expect(
      wrapper.find('[data-testid="understanding-web-hint"]').exists()
    ).toBe(false);
  });

  it('sends only the changed sections in the contract shape', async () => {
    testState.save.mockImplementation(async body => ({
      ok: true,
      settings: { ...settingsPayload(), ...body },
    }));
    const wrapper = await mountPage();

    await switchIn(wrapper, 'knowledge-faq-from-resolved').trigger('click');
    await switchIn(wrapper, 'safety-moderation').trigger('click');
    expect(saveButton(wrapper).attributes('disabled')).toBeUndefined();

    await clickSave(wrapper);

    // The page sends the one switch only: the platform safety values it does
    // not show are never sent back, so a save cannot reset or overwrite them.
    expect(testState.save).toHaveBeenCalledTimes(1);
    expect(testState.save).toHaveBeenCalledWith({
      faq: { generate_from_resolved: true },
      safety: { moderation_enabled: false },
    });
    expect(testState.useAlert).toHaveBeenCalledWith(
      'CAPTAIN.AI_SETTINGS.SAVED'
    );
    expect(saveButton(wrapper).attributes('disabled')).toBeDefined();
  });

  it('is not blocked by a stored platform rule that is invalid for the client', async () => {
    testState.save.mockResolvedValue({ ok: true, settings: settingsPayload() });
    const wrapper = await mountPage();

    await switchIn(wrapper, 'safety-moderation').trigger('click');
    await clickSave(wrapper);

    expect(testState.useAlert).not.toHaveBeenCalledWith(
      'CAPTAIN.AI_SETTINGS.VALIDATION_ERROR'
    );
    expect(testState.save).toHaveBeenCalledWith({
      safety: { moderation_enabled: false },
    });
  });

  it('sends a changed handoff section whole with the reason flags', async () => {
    testState.save.mockResolvedValue({ ok: true, settings: settingsPayload() });
    const wrapper = await mountPage();

    await wrapper
      .get('[data-testid="outcome-add-completion_reasons"]')
      .trigger('click');
    const rows = reasonRows(wrapper, 'completion_reasons');
    expect(rows.map(row => row.attributes('data-reason-id')).at(-1)).toBe(
      'other'
    );
    await rows[1].get('input').setValue('Записан на приём');
    await clickSave(wrapper);

    const body = testState.save.mock.calls[0][0];
    expect(Object.keys(body)).toEqual(['handoff']);
    expect(body.handoff.completion_reasons).toHaveLength(3);
    expect(body.handoff.completion_reasons[1]).toMatchObject({
      label: 'Записан на приём',
      enabled: true,
      builtin: false,
    });
    expect(body.handoff.handoff_message).toEqual({
      enabled: true,
      mode: 'fixed',
      text: 'Передаю',
      instruction: '',
    });
  });

  describe('handoff and closing messages', () => {
    const messageBlock = (wrapper, kind) =>
      within(wrapper, `status-message-${kind}`);

    it('offers the switch, the mode and the text for a fixed message, and no guide', async () => {
      const wrapper = await mountPage();
      const block = messageBlock(wrapper, 'handoff');

      expect(block.find('[role="switch"]').exists()).toBe(true);
      expect(block.find('[role="radiogroup"]').exists()).toBe(true);
      expect(block.get('#handoff-message-text').element.value).toBe('Передаю');
      expect(block.find('#handoff-message-instruction').exists()).toBe(false);
      expect(block.text()).toContain(
        'CAPTAIN.AI_SETTINGS.HANDOFF.TEXT_LABEL_FIXED'
      );
      // A switched-off message shows only its switch.
      const closing = messageBlock(wrapper, 'resolution');
      expect(closing.find('[role="radiogroup"]').exists()).toBe(false);
      expect(closing.find('textarea').exists()).toBe(false);
    });

    it('shows "how to write" with a counter and a 500 character limit for an AI-written message', async () => {
      const payload = settingsPayload();
      payload.handoff.resolution_message = {
        enabled: true,
        mode: 'generated',
        text: '',
        instruction: 'Коротко.',
      };
      const wrapper = await mountPage(payload);
      const block = messageBlock(wrapper, 'resolution');
      const instruction = block.get('#resolution-message-instruction');

      expect(instruction.element.value).toBe('Коротко.');
      expect(instruction.attributes('maxlength')).toBe('500');
      expect(block.text()).toContain(
        'CAPTAIN.AI_SETTINGS.HANDOFF.INSTRUCTION_LABEL'
      );
      expect(block.text()).toContain('8 / 500');
      expect(block.find('#resolution-message-text').exists()).toBe(false);

      await instruction.setValue('Тепло и коротко, на «вы».');
      expect(block.text()).toContain('25 / 500');
      testState.save.mockResolvedValue({ ok: true, settings: payload });
      await clickSave(wrapper);

      expect(testState.save).toHaveBeenCalledTimes(1);
      expect(
        testState.save.mock.calls[0][0].handoff.resolution_message
      ).toEqual({
        enabled: true,
        mode: 'generated',
        text: '',
        instruction: 'Тепло и коротко, на «вы».',
      });
    });

    it('swaps the text for the guide when the mode becomes AI, keeps the text and needs no text to save', async () => {
      const wrapper = await mountPage();
      const block = messageBlock(wrapper, 'handoff');

      await block
        .get('[data-testid="handoff-message-generated"]')
        .trigger('click');

      expect(block.find('#handoff-message-text').exists()).toBe(false);
      await block
        .get('#handoff-message-instruction')
        .setValue('Спокойным тоном, без обещаний.');
      testState.save.mockResolvedValue({
        ok: true,
        settings: settingsPayload(),
      });
      await clickSave(wrapper);

      expect(testState.save.mock.calls[0][0].handoff.handoff_message).toEqual({
        enabled: true,
        mode: 'generated',
        text: 'Передаю',
        instruction: 'Спокойным тоном, без обещаний.',
      });
    });

    it('shows a server error of the guide under the guide', async () => {
      const payload = settingsPayload();
      payload.handoff.handoff_message = {
        enabled: true,
        mode: 'generated',
        text: '',
        instruction: '',
      };
      testState.save.mockResolvedValue({
        ok: false,
        errors: [
          {
            field: 'handoff.handoff_message.instruction',
            code: 'too_long',
            message: 'Guide is too long',
          },
        ],
      });
      const wrapper = await mountPage(payload);

      await wrapper.get('#handoff-message-instruction').setValue('Коротко.');
      await clickSave(wrapper);

      expect(messageBlock(wrapper, 'handoff').text()).toContain(
        'Guide is too long'
      );
      expect(wrapper.find('[data-testid="ai-settings-errors"]').exists()).toBe(
        false
      );
    });
  });

  it('blocks saving while a message is invalid', async () => {
    const wrapper = await mountPage();

    await wrapper.get('#handoff-message-text').setValue('');
    await clickSave(wrapper);

    expect(testState.save).not.toHaveBeenCalled();
    expect(testState.useAlert).toHaveBeenCalledWith(
      'CAPTAIN.AI_SETTINGS.VALIDATION_ERROR'
    );
    expect(wrapper.text()).toContain(
      'CAPTAIN.AI_SETTINGS.HANDOFF.TEXT_REQUIRED'
    );
  });

  it('blocks saving an empty reason label', async () => {
    const wrapper = await mountPage();

    await wrapper
      .get('[data-testid="outcome-add-handoff_reasons"]')
      .trigger('click');
    expect(reasonRows(wrapper, 'handoff_reasons')).toHaveLength(3);
    await clickSave(wrapper);

    expect(testState.save).not.toHaveBeenCalled();
    expect(within(wrapper, 'outcome-section-handoff_reasons').text()).toContain(
      'CAPTAIN.ASSISTANTS.OUTCOMES.VALIDATION'
    );
  });

  it('shows 422 field errors inline and the rest in a banner', async () => {
    testState.save.mockResolvedValue({
      ok: false,
      errors: [
        {
          field: 'safety.moderation_enabled',
          code: 'invalid_type',
          message: 'Must be a boolean',
        },
        {
          field: 'conversation.message_collapse_window_seconds',
          code: 'too_long',
          message: 'Window is too long',
        },
        { field: null, code: 'conflict', message: 'Settings changed' },
      ],
    });
    const wrapper = await mountPage();

    await wrapper.get('#ai-settings-collapse-window').setValue('600');
    await switchIn(wrapper, 'safety-moderation').trigger('click');
    await clickSave(wrapper);

    expect(testState.save).toHaveBeenCalledTimes(1);
    expect(testState.useAlert).toHaveBeenCalledWith(
      'CAPTAIN.AI_SETTINGS.SAVE_ERROR'
    );
    expect(wrapper.get('[data-testid="ai-settings-safety"]').text()).toContain(
      'Must be a boolean'
    );
    expect(wrapper.get('[data-testid="ai-settings-speed"]').text()).toContain(
      'Window is too long'
    );
    expect(wrapper.get('[data-testid="ai-settings-errors"]').text()).toContain(
      'Settings changed'
    );
    expect(saveButton(wrapper).attributes('disabled')).toBeUndefined();
  });

  it('asks before leaving with unsaved changes', async () => {
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(false);
    const wrapper = await mountPage();

    expect(testState.leaveGuard()).toBe(true);
    expect(confirmSpy).not.toHaveBeenCalled();

    await switchIn(wrapper, 'handoff-auto_reply_on_last_incoming').trigger(
      'click'
    );

    expect(testState.leaveGuard()).toBe(false);
    expect(confirmSpy).toHaveBeenCalledWith(
      'CAPTAIN.AI_SETTINGS.LEAVE_CONFIRM'
    );
    expect(
      testState.updateGuard(
        { params: { accountId: '1' }, hash: '#safety' },
        { params: { accountId: '1' }, hash: '' }
      )
    ).toBe(true);
  });

  it('scrolls to the section named in the hash', async () => {
    testState.route = { params: { accountId: '1' }, hash: '#safety' };
    const scrolledIds = [];
    Element.prototype.scrollIntoView = function scrollIntoView() {
      scrolledIds.push(this.id);
    };

    const wrapper = await mountPage(settingsPayload(), {
      attachTo: document.body,
    });

    expect(scrolledIds).toEqual(['safety']);
    wrapper.unmount();
  });

  it('offers a retry when the settings cannot be loaded', async () => {
    testState.uiFlags.fetchError = true;
    const wrapper = await mountPage(null);

    const banner = wrapper.get('[data-testid="ai-settings-load-error"]');
    expect(banner.text()).toContain('CAPTAIN.AI_SETTINGS.LOAD_ERROR');

    testState.fetch.mockResolvedValue(settingsPayload());
    await banner.get('button').trigger('click');
    await flushPromises();

    expect(testState.fetch).toHaveBeenLastCalledWith({ force: true });
    expect(wrapper.find('section#safety').exists()).toBe(true);
  });

  it('does not load anything behind the paywall', async () => {
    testState.showPaywall = true;
    await mountPage();

    expect(testState.fetch).not.toHaveBeenCalled();
  });
});
