import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import VoiceCallStatus from './VoiceCallStatus.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const mountComponent = props =>
  shallowMount(VoiceCallStatus, {
    props,
    global: {
      stubs: {
        Icon: {
          props: ['icon'],
          template: '<i :data-icon="icon" />',
        },
      },
    },
  });

describe('VoiceCallStatus', () => {
  it('normalizes Rails no_answer outbound calls to the existing outgoing-call preview', () => {
    const wrapper = mountComponent({
      status: 'no_answer',
      direction: 'outbound',
    });

    expect(wrapper.text()).toContain('CONVERSATION.VOICE_CALL.OUTGOING_CALL');
    expect(wrapper.text()).not.toContain('CONVERSATION.VOICE_CALL.MISSED_CALL');
  });

  it('normalizes Rails no_answer inbound calls to the existing missed-call preview', () => {
    const wrapper = mountComponent({
      status: 'no_answer',
      direction: 'inbound',
    });

    expect(wrapper.text()).toContain('CONVERSATION.VOICE_CALL.MISSED_CALL');
  });
});
