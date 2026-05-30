import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import CopilotThinkingGroup from './CopilotThinkingGroup.vue';

const i18nState = vi.hoisted(() => ({ locale: 'ru' }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: {
      get value() {
        return i18nState.locale;
      },
    },
    t: (key, params = {}) =>
      ({
        'CAPTAIN.COPILOT.SHOW_STEPS': 'Детали',
        'CAPTAIN.COPILOT.TOOL_COUNT.ONE': `${params.count} инструмент`,
        'CAPTAIN.COPILOT.TOOL_COUNT.FEW': `${params.count} инструмента`,
        'CAPTAIN.COPILOT.TOOL_COUNT.MANY': `${params.count} инструментов`,
      })[key] || key,
  }),
}));

const toolMessage = id => ({
  id: `tool-${id}`,
  message: { content: `Completed tool_${id}`, toolName: `tool_${id}` },
});

const mountComponent = props =>
  mount(CopilotThinkingGroup, {
    props: {
      messages: [],
      ...props,
    },
    global: {
      stubs: {
        Icon: true,
        CopilotThinkingBlock: true,
      },
    },
  });

describe('CopilotThinkingGroup', () => {
  it('renders a details label with the tool count', () => {
    i18nState.locale = 'ru';
    const wrapper = mountComponent({
      messages: [
        { id: 'reasoning', message: { content: 'Обоснование ответа' } },
        toolMessage(1),
        toolMessage(2),
      ],
    });

    expect(wrapper.find('button').text()).toContain('Детали - 2 инструмента');
  });

  it('uses locale-aware plural categories instead of Russian modulo rules', () => {
    i18nState.locale = 'en';
    const wrapper = mountComponent({
      messages: Array.from({ length: 21 }, (_, index) => toolMessage(index)),
    });

    expect(wrapper.find('button').text()).toContain('Детали - 21 инструментов');
  });

  it('does not show a zero tool counter for reasoning-only details', () => {
    i18nState.locale = 'ru';
    const wrapper = mountComponent({
      messages: [
        {
          id: 'reasoning',
          message: {
            content: 'Обоснование ответа',
            reasoning: 'Ответ подготовлен без инструментов.',
          },
        },
      ],
    });

    expect(wrapper.find('button').text()).toBe('Детали');
  });
});
