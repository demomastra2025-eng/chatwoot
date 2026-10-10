import { mount } from '@vue/test-utils';
import { defineComponent, ref } from 'vue';
import { describe, expect, it } from 'vitest';
import SchedulingAppointmentTimeFields from './SchedulingAppointmentTimeFields.vue';

const mountFields = () =>
  mount(
    defineComponent({
      components: { SchedulingAppointmentTimeFields },
      setup() {
        return {
          startsAt: ref('2026-06-27T10:00'),
          endsAt: ref('2026-06-27T10:30'),
          durationMin: ref(30),
        };
      },
      template: `<SchedulingAppointmentTimeFields
        v-model:starts-at="startsAt" v-model:ends-at="endsAt"
        v-model:duration-min="durationMin" id-prefix="manual" />`,
    }),
    {
      global: {
        stubs: { SchedulingDateTimeField: true, Input: true },
      },
    }
  );

describe('SchedulingAppointmentTimeFields', () => {
  it('shifts the ending time for an authored duration and keeps it when start changes', async () => {
    const wrapper = mountFields();
    const fields = wrapper.findComponent(SchedulingAppointmentTimeFields);
    await fields
      .findComponent({ name: 'Input' })
      .vm.$emit('update:modelValue', '75');

    expect(wrapper.vm.endsAt).toBe('2026-06-27T11:15');
    await fields
      .findAllComponents({ name: 'SchedulingDateTimeField' })[0]
      .vm.$emit('update:modelValue', '2026-06-27T11:00');
    expect(wrapper.vm.endsAt).toBe('2026-06-27T12:15');
    expect(Number(wrapper.vm.durationMin)).toBe(75);
  });

  it('derives duration from a directly edited ending time on the clinic clock', async () => {
    const wrapper = mountFields();
    const fields = wrapper.findComponent(SchedulingAppointmentTimeFields);
    await fields
      .findAllComponents({ name: 'SchedulingDateTimeField' })[1]
      .vm.$emit('update:modelValue', '2026-06-27T11:10');

    expect(wrapper.vm.startsAt).toBe('2026-06-27T10:00');
    expect(wrapper.vm.durationMin).toBe(70);
  });

  it.each(['0', '1', '2000'])(
    'keeps invalid duration %s visible after editing the start',
    async duration => {
      const wrapper = mountFields();
      const fields = wrapper.findComponent(SchedulingAppointmentTimeFields);
      await fields
        .findComponent({ name: 'Input' })
        .vm.$emit('update:modelValue', duration);

      expect(wrapper.vm.endsAt).toBe('2026-06-27T10:30');
      expect(wrapper.vm.durationMin).toBe(duration);

      await fields
        .findAllComponents({ name: 'SchedulingDateTimeField' })[0]
        .vm.$emit('update:modelValue', '2026-06-27T09:00');

      expect(wrapper.vm.endsAt).toBe('2026-06-27T10:30');
      expect(wrapper.vm.durationMin).toBe(duration);
    }
  );
});
