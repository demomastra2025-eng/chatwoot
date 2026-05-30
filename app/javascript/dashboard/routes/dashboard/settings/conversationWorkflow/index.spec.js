import { shallowMount } from '@vue/test-utils';
import { useAccount } from 'dashboard/composables/useAccount';
import { useMapGetter } from 'dashboard/composables/store';
import { FEATURE_FLAGS } from '../../../../featureFlags';
import ConversationWorkflowSettings from './index.vue';

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: vi.fn(),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: vi.fn(),
}));

const mountComponent = ({ featureEnabled = () => false } = {}) => {
  useAccount.mockReturnValue({ accountId: { value: 1 } });
  useMapGetter.mockReturnValue({ value: featureEnabled });

  return shallowMount(ConversationWorkflowSettings, {
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        AutoResolve: { template: '<div data-test="auto-resolve" />' },
        BaseSettingsHeader: {
          props: ['title', 'description'],
          template:
            '<header data-test="settings-header" :data-title="title" :data-description="description" />',
        },
        ConversationRequiredAttributes: {
          props: ['isEnabled'],
          template:
            '<div data-test="required-attributes" :data-enabled="isEnabled" />',
        },
        SettingsLayout: {
          template:
            '<div><slot name="header" /><slot name="body" /><slot /></div>',
        },
      },
    },
  });
};

describe('ConversationWorkflow settings', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders dialog settings as a separate settings page', () => {
    const wrapper = mountComponent({
      featureEnabled: (_accountId, flag) =>
        flag === FEATURE_FLAGS.AUTO_RESOLVE_CONVERSATIONS ||
        flag === FEATURE_FLAGS.CONVERSATION_REQUIRED_ATTRIBUTES,
    });

    expect(
      wrapper.find('[data-test="settings-header"]').attributes()
    ).toMatchObject({
      'data-title': 'CONVERSATION_WORKFLOW.INDEX.HEADER.TITLE',
      'data-description': 'CONVERSATION_WORKFLOW.INDEX.HEADER.DESCRIPTION',
    });
    expect(wrapper.find('[data-test="auto-resolve"]').exists()).toBe(true);
    expect(
      wrapper.find('[data-test="required-attributes"]').attributes()
    ).toMatchObject({
      'data-enabled': 'true',
    });
  });

  it('keeps required attributes visible behind its feature paywall state', () => {
    const wrapper = mountComponent();

    expect(wrapper.find('[data-test="auto-resolve"]').exists()).toBe(false);
    expect(
      wrapper.find('[data-test="required-attributes"]').attributes()
    ).toMatchObject({
      'data-enabled': 'false',
    });
  });
});
