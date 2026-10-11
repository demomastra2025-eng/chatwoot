import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  showPaywall: false,
}));

vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({
    shouldShowPaywall: () => mocks.showPaywall,
  }),
}));

vi.mock('dashboard/components/policy.vue', () => ({
  default: { name: 'Policy', template: '<div><slot /></div>' },
}));

vi.mock('dashboard/components-next/button/Button.vue', () => ({
  default: {
    name: 'Button',
    props: { label: { type: String, default: '' }, isLoading: Boolean },
    emits: ['click'],
    template:
      '<button :data-loading="String(isLoading)" @click="$emit(\'click\')">{{ label }}</button>',
  },
}));

vi.mock('dashboard/components/widgets/BackButton.vue', () => ({
  default: { name: 'BackButton', template: '<a />' },
}));

vi.mock('dashboard/components-next/pagination/PaginationFooter.vue', () => ({
  default: { name: 'PaginationFooter', template: '<div />' },
}));

vi.mock('dashboard/components-next/spinner/Spinner.vue', () => ({
  default: { name: 'Spinner', template: '<span />' },
}));

const { default: PageLayout } = await import('./PageLayout.vue');

const mountLayout = ({ props = {}, slots = {} } = {}) =>
  mount(PageLayout, {
    props: { showPaginationFooter: false, ...props },
    slots: { body: '<div data-test="body">body</div>', ...slots },
    global: { directives: { onClickaway: {} } },
  });

const widthClasses = wrapper => [
  wrapper.get('header > div').classes(),
  wrapper.get('main > div').classes(),
];

describe('Captain PageLayout', () => {
  beforeEach(() => {
    mocks.showPaywall = false;
  });

  it.each([
    [undefined, 'max-w-5xl'],
    ['default', 'max-w-5xl'],
    ['form', 'max-w-3xl'],
    ['full', 'max-w-none'],
  ])('uses the %s content width', (contentWidth, widthClass) => {
    const wrapper = mountLayout({
      props: contentWidth ? { contentWidth } : {},
    });

    widthClasses(wrapper).forEach(classes =>
      expect(classes).toContain(widthClass)
    );
  });

  it('has no agent switcher and no create-agent button', () => {
    const wrapper = mountLayout({
      props: { headerTitle: 'Tools', showAssistantSwitcher: true },
    });

    expect(wrapper.text()).toContain('Tools');
    expect(wrapper.text()).not.toContain(
      'CAPTAIN.ASSISTANT_SWITCHER.NEW_ASSISTANT'
    );
    expect(wrapper.findAll('button')).toHaveLength(0);
  });

  it('replaces the title row with the header slot and keeps the sub header', () => {
    const wrapper = mountLayout({
      props: { headerTitle: 'Default title', buttonLabel: 'Add' },
      slots: {
        header: '<div data-test="custom-header">Agent header</div>',
        subHeader: '<div data-test="sub-header" />',
      },
    });

    expect(wrapper.find('[data-test="custom-header"]').exists()).toBe(true);
    expect(wrapper.find('[data-test="sub-header"]').exists()).toBe(true);
    expect(wrapper.text()).not.toContain('Default title');
    expect(wrapper.findAll('button')).toHaveLength(0);
  });

  it('renders the header button and emits click', async () => {
    const wrapper = mountLayout({ props: { buttonLabel: 'Save' } });
    const button = wrapper.get('button');

    expect(button.text()).toBe('Save');
    expect(button.attributes('disabled')).toBeUndefined();
    await button.trigger('click');

    expect(wrapper.emitted('click')).toHaveLength(1);
  });

  it('disables the header button while it is disabled or saving', () => {
    const disabled = mountLayout({
      props: { buttonLabel: 'Save', buttonDisabled: true },
    });
    const saving = mountLayout({
      props: { buttonLabel: 'Save', buttonLoading: true },
    });

    expect(disabled.get('button').attributes('disabled')).toBeDefined();
    expect(disabled.get('button').attributes('data-loading')).toBe('false');
    expect(saving.get('button').attributes('disabled')).toBeDefined();
    expect(saving.get('button').attributes('data-loading')).toBe('true');
  });

  it('shows the paywall instead of the body and hides the header button', () => {
    mocks.showPaywall = true;

    const wrapper = mountLayout({
      props: { buttonLabel: 'Save', featureFlag: 'captain_integration' },
      slots: { paywall: '<div data-test="paywall" />' },
    });

    expect(wrapper.find('[data-test="paywall"]').exists()).toBe(true);
    expect(wrapper.find('[data-test="body"]').exists()).toBe(false);
    expect(wrapper.findAll('button')).toHaveLength(0);
  });
});
