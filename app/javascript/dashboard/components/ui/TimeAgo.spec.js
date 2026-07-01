import { mount } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import TimeAgo from './TimeAgo.vue';

const mountComponent = props =>
  mount(TimeAgo, {
    props: {
      isAutoRefreshEnabled: false,
      createdAtTimestamp: Date.UTC(2026, 0, 1, 0, 0, 0) / 1000,
      conversationId: 1,
      ...props,
    },
    global: {
      mocks: {
        $t: key => key,
      },
    },
  });

describe('TimeAgo', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('formats compact elapsed time with days and hours', () => {
    vi.setSystemTime(new Date(Date.UTC(2026, 0, 2, 2, 0, 0)));

    const wrapper = mountComponent({
      displayMode: 'compact_elapsed',
      lastActivityTimestamp: Date.UTC(2026, 0, 1, 0, 0, 0) / 1000,
    });

    expect(wrapper.text()).toBe('1д-2ч');
  });

  it('formats compact elapsed time with hours and minutes', () => {
    vi.setSystemTime(new Date(Date.UTC(2026, 0, 1, 3, 1, 0)));

    const wrapper = mountComponent({
      displayMode: 'compact_elapsed',
      lastActivityTimestamp: Date.UTC(2026, 0, 1, 0, 0, 0) / 1000,
    });

    expect(wrapper.text()).toBe('3ч-1м');
  });

  it('formats compact elapsed time with minutes and seconds', () => {
    vi.setSystemTime(new Date(Date.UTC(2026, 0, 1, 0, 40, 5)));

    const wrapper = mountComponent({
      displayMode: 'compact_elapsed',
      lastActivityTimestamp: Date.UTC(2026, 0, 1, 0, 0, 0) / 1000,
    });

    expect(wrapper.text()).toBe('40м-5с');
  });

  it('formats compact elapsed pair as customer-reply single units', () => {
    vi.setSystemTime(new Date(Date.UTC(2026, 0, 2, 14, 0, 0)));

    const wrapper = mountComponent({
      displayMode: 'compact_elapsed',
      lastActivityTimestamp: Date.UTC(2026, 0, 1, 0, 0, 0) / 1000,
      secondaryActivityTimestamp: Date.UTC(2026, 0, 2, 0, 0, 0) / 1000,
    });

    expect(wrapper.text()).toBe('1д-14ч');
  });

  it('formats a compact elapsed pair with only the manager-side timestamp', () => {
    vi.setSystemTime(new Date(Date.UTC(2026, 0, 2, 14, 0, 0)));

    const wrapper = mountComponent({
      displayMode: 'compact_elapsed',
      lastActivityTimestamp: 0,
      secondaryActivityTimestamp: Date.UTC(2026, 0, 2, 0, 0, 0) / 1000,
      tooltipTextOverride: 'Последнее от клиента',
      secondaryTooltipTextOverride: 'Последняя реакция менеджера',
    });

    expect(wrapper.text()).toBe('14ч');
    expect(wrapper.vm.tooltipText).toContain('Последняя реакция менеджера:');
    expect(wrapper.vm.tooltipText).not.toContain('Последнее от клиента:');
  });

  it('uses an explicit tooltip text when provided', () => {
    const wrapper = mountComponent({
      displayMode: 'compact_elapsed',
      lastActivityTimestamp: Date.UTC(2026, 0, 1, 0, 0, 0) / 1000,
      tooltipTextOverride: 'Последнее от клиента',
    });

    expect(wrapper.vm.tooltipText).toContain('Последнее от клиента:');
  });
});
