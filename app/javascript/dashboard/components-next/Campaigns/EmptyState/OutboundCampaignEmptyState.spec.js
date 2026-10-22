import { describe, expect, it } from 'vitest';
import { mount } from '@vue/test-utils';
import OutboundCampaignEmptyState from './OutboundCampaignEmptyState.vue';
import TouchEmptyState from 'dashboard/components-next/Outbound/TouchEmptyState.vue';

const EmptyStateLayoutStub = {
  props: ['title', 'subtitle', 'showBackdrop'],
  template: `
    <div data-testid="empty-state-layout">
      <h2>{{ title }}</h2>
      <p>{{ subtitle }}</p>
      <slot name="actions" />
    </div>
  `,
};

const ButtonStub = {
  props: ['label', 'icon', 'size'],
  emits: ['click'],
  template: `
    <button type="button" data-testid="empty-state-cta" @click="$emit('click')">
      {{ label }}
    </button>
  `,
};

describe('Outbound / Touch empty state CTA button', () => {
  it('renders the centered action button in OutboundCampaignEmptyState and emits click', async () => {
    const wrapper = mount(OutboundCampaignEmptyState, {
      props: {
        title: 'Нет доступных кампаний',
        subtitle: 'Запустите кампанию',
        buttonLabel: 'Массовая рассылка',
      },
      global: {
        stubs: {
          EmptyStateLayout: EmptyStateLayoutStub,
          Button: ButtonStub,
        },
      },
    });

    const button = wrapper.get('[data-testid="empty-state-cta"]');
    expect(button.text()).toBe('Массовая рассылка');

    await button.trigger('click');
    expect(wrapper.emitted('click')).toHaveLength(1);
  });

  it('renders the centered action button in TouchEmptyState and emits click', async () => {
    const wrapper = mount(TouchEmptyState, {
      props: {
        title: 'Напоминаний пока нет.',
        subtitle: 'Создайте напоминание',
        buttonLabel: 'Создать напоминание',
      },
      global: {
        stubs: {
          EmptyStateLayout: EmptyStateLayoutStub,
          Button: ButtonStub,
        },
      },
    });

    const button = wrapper.get('[data-testid="empty-state-cta"]');
    expect(button.text()).toBe('Создать напоминание');

    await button.trigger('click');
    expect(wrapper.emitted('click')).toHaveLength(1);
  });
});
