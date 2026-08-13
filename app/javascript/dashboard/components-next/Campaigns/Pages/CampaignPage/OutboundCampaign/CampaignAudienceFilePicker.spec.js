import { flushPromises, mount } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import CampaignsAPI from 'dashboard/api/campaigns';
import CampaignAudienceFilePicker from './CampaignAudienceFilePicker.vue';

vi.mock('dashboard/api/campaigns', () => ({
  default: {
    importAudience: vi.fn(),
    getAudienceImport: vi.fn(),
  },
}));

const ButtonStub = {
  inheritAttrs: false,
  props: ['label', 'disabled'],
  emits: ['click'],
  template:
    '<button v-bind="$attrs" :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};

const InputStub = {
  props: ['modelValue'],
  emits: ['update:modelValue'],
  template: '<input :value="modelValue" />',
};

const mountPicker = () =>
  mount(CampaignAudienceFilePicker, {
    props: { inboxId: 17 },
    global: {
      stubs: { Button: ButtonStub, Input: InputStub },
      mocks: { $t: key => key },
    },
  });

const chooseFile = async wrapper => {
  const file = new File(['phone_number\n87051234567'], 'recipients.csv', {
    type: 'text/csv',
  });
  const input = wrapper.get('[data-test-id="campaign-audience-file"]');
  Object.defineProperty(input.element, 'files', {
    configurable: true,
    value: [file],
  });
  await input.trigger('change');
  return file;
};

describe('CampaignAudienceFilePicker', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('uploads, polls, renders the terminal report, and emits the snapshot token', async () => {
    const wrapper = mountPicker();
    const file = await chooseFile(wrapper);
    CampaignsAPI.importAudience.mockResolvedValue({
      data: { id: 44, status: 'pending', token: 'snapshot-token' },
    });
    CampaignsAPI.getAudienceImport
      .mockResolvedValueOnce({ data: { id: 44, status: 'processing' } })
      .mockResolvedValueOnce({
        data: {
          id: 44,
          status: 'completed',
          token: 'snapshot-token',
          recipient_count: 2,
          created_count: 1,
          existing_count: 1,
          duplicate_count: 1,
          invalid_count: 0,
          conflict_count: 0,
        },
      });

    await wrapper
      .get('[data-test-id="campaign-audience-upload"]')
      .trigger('click');
    await flushPromises();
    expect(CampaignsAPI.importAudience).toHaveBeenCalledWith({
      file,
      inboxId: 17,
      defaultCountry: 'KZ',
    });

    await vi.advanceTimersByTimeAsync(1000);
    await flushPromises();

    expect(
      wrapper.find('[data-test-id="campaign-audience-report"]').exists()
    ).toBe(true);
    expect(wrapper.emitted('completed')?.[0]?.[0]).toMatchObject({
      id: 44,
      token: 'snapshot-token',
      recipient_count: 2,
    });
  });

  it('ignores a late poll result after the selected file changes', async () => {
    const wrapper = mountPicker();
    await chooseFile(wrapper);
    let resolvePoll;
    CampaignsAPI.importAudience.mockResolvedValue({
      data: { id: 45, status: 'pending', token: 'old-token' },
    });
    CampaignsAPI.getAudienceImport.mockReturnValue(
      new Promise(resolve => {
        resolvePoll = resolve;
      })
    );

    await wrapper
      .get('[data-test-id="campaign-audience-upload"]')
      .trigger('click');
    await flushPromises();
    await chooseFile(wrapper);
    resolvePoll({
      data: { id: 45, status: 'completed', token: 'old-token' },
    });
    await flushPromises();

    expect(wrapper.emitted('completed')).toBeUndefined();
    expect(
      wrapper.find('[data-test-id="campaign-audience-report"]').exists()
    ).toBe(false);
  });

  it('clears upload loading when the selected file changes during upload', async () => {
    const wrapper = mountPicker();
    await chooseFile(wrapper);
    CampaignsAPI.importAudience.mockReturnValue(new Promise(() => {}));

    await wrapper
      .get('[data-test-id="campaign-audience-upload"]')
      .trigger('click');
    await flushPromises();
    expect(
      wrapper
        .get('[data-test-id="campaign-audience-upload"]')
        .attributes('disabled')
    ).toBeDefined();

    await chooseFile(wrapper);

    expect(
      wrapper
        .get('[data-test-id="campaign-audience-upload"]')
        .attributes('disabled')
    ).toBeUndefined();
  });
});
