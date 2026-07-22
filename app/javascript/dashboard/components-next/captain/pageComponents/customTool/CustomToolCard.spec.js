import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import CustomToolCard from './CustomToolCard.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('shared/helpers/timeHelper', () => ({
  dynamicTime: () => 'just now',
}));

const longDescription =
  'This custom tool sends appointment reminders, checks CRM context, updates follow-up notes, and includes enough text to require wrapping inside the card at narrow widths.';

const buildWrapper = props =>
  shallowMount(CustomToolCard, {
    props: {
      id: 42,
      title: 'Appointment follow-up tool',
      description: 'Short description',
      groupName: 'CRM',
      authType: 'none',
      updatedAt: 1779720684,
      createdAt: 1779720000,
      ...props,
    },
    global: {
      directives: {
        'on-clickaway': {},
      },
      stubs: {
        Button: true,
        CardLayout: {
          template: '<section class="card-layout"><slot /></section>',
        },
        DropdownMenu: true,
        Policy: {
          template: '<div><slot /></div>',
        },
      },
    },
  });

const descriptionNode = wrapper =>
  wrapper
    .findAll('span')
    .find(span => span.text().includes(wrapper.props('description')));

const expectWrappingClasses = description => {
  expect(description.classes()).toEqual(
    expect.arrayContaining(['line-clamp-2', 'break-words', 'min-w-0', 'flex-1'])
  );
  expect(description.classes()).not.toContain('truncate');
};

describe('CustomToolCard', () => {
  it('wraps and clamps long custom tool descriptions instead of truncating them', () => {
    const wrapper = buildWrapper({ description: longDescription });
    const description = descriptionNode(wrapper);

    expect(description.exists()).toBe(true);
    expectWrappingClasses(description);
    expect(description.text()).toBe(longDescription);
  });

  it('uses breakable wrapping for long unbroken custom tool descriptions', () => {
    const unbrokenDescription = 'x'.repeat(160);
    const wrapper = buildWrapper({ description: unbrokenDescription });
    const description = descriptionNode(wrapper);

    expect(description.exists()).toBe(true);
    expectWrappingClasses(description);
    expect(description.text()).toBe(unbrokenDescription);
  });

  it('keeps the description clamped inside a narrow flex row', () => {
    const wrapper = buildWrapper({ description: longDescription });
    const description = descriptionNode(wrapper);
    const descriptionGroup = description.element.parentElement;
    const row = descriptionGroup.parentElement;

    expect(descriptionGroup.className).toContain('min-w-0');
    expect(row.className).toContain('min-w-0');
    expectWrappingClasses(description);
  });

  it('renders a short custom tool description unchanged', () => {
    const shortDescription = 'Short description';
    const wrapper = buildWrapper({ description: shortDescription });
    const description = descriptionNode(wrapper);

    expect(description.exists()).toBe(true);
    expect(description.text()).toBe(shortDescription);
    expect(description.classes()).toEqual(
      expect.arrayContaining(['text-sm', 'text-n-slate-11', 'flex-1'])
    );
  });

  it('exposes the duplicate action in the tool menu', () => {
    const wrapper = buildWrapper();

    expect(wrapper.vm.menuItems).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ action: 'duplicate', value: 'duplicate' }),
      ])
    );
  });
});
