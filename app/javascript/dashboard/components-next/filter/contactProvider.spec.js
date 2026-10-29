import { ref } from 'vue';
import { useContactFilterContext } from './contactProvider';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('dashboard/composables/store.js', () => ({
  useMapGetter: key => {
    const getters = {
      'attributes/getContactAttributes': [],
      'labels/getLabels': [],
    };
    return ref(getters[key] || []);
  },
}));

describe('useContactFilterContext', () => {
  it('exposes meta_ad_referral and meta_ad_source_id filter definitions for contacts', () => {
    const { filterTypes } = useContactFilterContext();

    const referralFilter = filterTypes.value.find(
      filter => filter.attributeKey === 'meta_ad_referral'
    );
    const sourceFilter = filterTypes.value.find(
      filter => filter.attributeKey === 'meta_ad_source_id'
    );

    expect(referralFilter).toBeDefined();
    expect(referralFilter.inputType).toBe('searchSelect');
    expect(referralFilter.options).toEqual([
      { id: 'true', name: 'CONTACTS_LAYOUT.FILTER.META_AD_REFERRAL_TRUE' },
      { id: 'false', name: 'CONTACTS_LAYOUT.FILTER.META_AD_REFERRAL_FALSE' },
    ]);
    expect(referralFilter.filterOperators.map(op => op.value)).toEqual([
      'equal_to',
      'not_equal_to',
      'is_present',
      'is_not_present',
    ]);

    expect(sourceFilter).toBeDefined();
    expect(sourceFilter.inputType).toBe('plainText');
    expect(sourceFilter.filterOperators.map(op => op.value)).toEqual([
      'equal_to',
      'not_equal_to',
      'contains',
      'does_not_contain',
      'is_present',
      'is_not_present',
    ]);
  });
});
