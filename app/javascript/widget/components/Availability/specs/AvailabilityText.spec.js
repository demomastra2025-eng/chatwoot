import { config, mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import en from 'widget/i18n/locale/en.json';
import AvailabilityText from '../AvailabilityText.vue';

const plugins = config.global.plugins;
beforeAll(() => {
  config.global.plugins = [
    createI18n({ legacy: false, locale: 'en', messages: { en } }),
  ];
});
afterAll(() => {
  config.global.plugins = plugins;
});

const opening = (day, hour) => new Date(2026, 8, day, hour).toISOString();
const props = {
  time: new Date(2026, 8, 7, 12, 45),
  workingHours: [{ starts_at: opening(7, 13), ends_at: opening(7, 17) }],
  workingHoursEnabled: true,
  isOnline: false,
  isInWorkingHours: false,
};

describe('AvailabilityText', () => {
  it('shows the real reopening after a lunch break', () => {
    const wrapper = mount(AvailabilityText, { props });
    expect(wrapper.text()).toBe('We will be back online in 15 minutes');
  });

  it('does not offer an opening during a holiday', () => {
    const wrapper = mount(AvailabilityText, {
      props: {
        ...props,
        workingHours: [{ starts_at: opening(8, 9), ends_at: opening(8, 17) }],
      },
    });
    expect(wrapper.text()).toBe('We will be back online tomorrow');
  });

  it('uses the offline message without configured hours and without online agents', () => {
    const wrapper = mount(AvailabilityText, {
      props: {
        ...props,
        workingHoursEnabled: false,
        isInWorkingHours: true,
      },
    });
    expect(wrapper.text()).toBe(en.TEAM_AVAILABILITY.BACK_AS_SOON_AS_POSSIBLE);
  });
});
