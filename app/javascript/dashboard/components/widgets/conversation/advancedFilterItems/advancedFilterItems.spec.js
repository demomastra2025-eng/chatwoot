import conversationFilterTypes, {
  filterAttributeGroups as conversationFilterGroups,
} from './index';
import contactFilterTypes, {
  filterAttributeGroups as contactFilterGroups,
} from 'dashboard/routes/dashboard/contacts/contactFilterItems';
import filterQueryGenerator from 'dashboard/helper/filterQueryGenerator';
import { generateValuesForEditCustomViews } from 'dashboard/helper/customViewsHelper';
import enAdvancedFilters from 'dashboard/i18n/locale/en/advancedFilters.json';
import ruAdvancedFilters from 'dashboard/i18n/locale/ru/advancedFilters.json';
import kkAdvancedFilters from 'dashboard/i18n/locale/kk/advancedFilters.json';
import enContactFilters from 'dashboard/i18n/locale/en/contactFilters.json';
import ruContactFilters from 'dashboard/i18n/locale/ru/contactFilters.json';
import kkContactFilters from 'dashboard/i18n/locale/kk/contactFilters.json';
import enContact from 'dashboard/i18n/locale/en/contact.json';
import ruContact from 'dashboard/i18n/locale/ru/contact.json';
import kkContact from 'dashboard/i18n/locale/kk/contact.json';

describe('Meta Ads filter items & i18n parity', () => {
  it('registers meta_ad_referral and meta_ad_source_id in conversation advancedFilterItems', () => {
    const referral = conversationFilterTypes.find(
      item => item.attributeKey === 'meta_ad_referral'
    );
    const source = conversationFilterTypes.find(
      item => item.attributeKey === 'meta_ad_source_id'
    );
    const standardGroup = conversationFilterGroups.find(
      group => group.i18nGroup === 'STANDARD_FILTERS'
    );

    expect(referral).toMatchObject({
      attributeKey: 'meta_ad_referral',
      attributeI18nKey: 'META_AD_REFERRAL',
      inputType: 'search_select',
    });
    expect(referral.filterOperators.map(op => op.value)).toEqual([
      'equal_to',
      'not_equal_to',
      'is_present',
      'is_not_present',
    ]);

    expect(source).toMatchObject({
      attributeKey: 'meta_ad_source_id',
      attributeI18nKey: 'META_AD_SOURCE_ID',
      inputType: 'plain_text',
    });
    expect(source.filterOperators.map(op => op.value)).toEqual([
      'equal_to',
      'not_equal_to',
      'contains',
      'does_not_contain',
      'is_present',
      'is_not_present',
    ]);

    expect(standardGroup.attributes.map(attr => attr.key)).toEqual(
      expect.arrayContaining(['meta_ad_referral', 'meta_ad_source_id'])
    );
  });

  it('registers meta_ad_referral and meta_ad_source_id in contactFilterItems', () => {
    const referral = contactFilterTypes.find(
      item => item.attributeKey === 'meta_ad_referral'
    );
    const source = contactFilterTypes.find(
      item => item.attributeKey === 'meta_ad_source_id'
    );
    const standardGroup = contactFilterGroups.find(
      group => group.i18nGroup === 'STANDARD_FILTERS'
    );

    expect(referral).toMatchObject({
      attributeKey: 'meta_ad_referral',
      attributeI18nKey: 'META_AD_REFERRAL',
      inputType: 'search_select',
    });
    expect(source).toMatchObject({
      attributeKey: 'meta_ad_source_id',
      attributeI18nKey: 'META_AD_SOURCE_ID',
      inputType: 'plain_text',
    });
    expect(standardGroup.attributes.map(attr => attr.key)).toEqual(
      expect.arrayContaining(['meta_ad_referral', 'meta_ad_source_id'])
    );
  });

  it('serializes and restores saved custom views for meta_ad_referral and meta_ad_source_id', () => {
    const generated = filterQueryGenerator([
      {
        attribute_key: 'meta_ad_referral',
        filter_operator: 'is_present',
        values: {},
        query_operator: 'and',
      },
      {
        attribute_key: 'meta_ad_source_id',
        filter_operator: 'contains',
        values: 'МРТ',
        query_operator: 'and',
      },
    ]);

    expect(generated.payload).toEqual([
      {
        attribute_key: 'meta_ad_referral',
        filter_operator: 'is_present',
        values: [],
        query_operator: 'and',
      },
      {
        attribute_key: 'meta_ad_source_id',
        filter_operator: 'contains',
        values: ['МРТ'],
        query_operator: undefined,
      },
    ]);

    expect(
      generateValuesForEditCustomViews(generated.payload[0], {
        filterTypes: conversationFilterTypes,
        allCustomAttributes: [],
      })
    ).toEqual([]);

    expect(
      generateValuesForEditCustomViews(generated.payload[1], {
        filterTypes: conversationFilterTypes,
        allCustomAttributes: [],
      })
    ).toBe('МРТ');
  });

  it('defines en, ru, and kk translations for conversation and contact Meta Ads filters', () => {
    [enAdvancedFilters, ruAdvancedFilters, kkAdvancedFilters].forEach(
      locale => {
        expect(locale.FILTER.ATTRIBUTES.META_AD_REFERRAL).toBeTruthy();
        expect(locale.FILTER.ATTRIBUTES.META_AD_SOURCE_ID).toBeTruthy();
        expect(locale.FILTER.ATTRIBUTE_LABELS.YES).toBeTruthy();
        expect(locale.FILTER.ATTRIBUTE_LABELS.NO).toBeTruthy();
      }
    );

    [enContactFilters, ruContactFilters, kkContactFilters].forEach(locale => {
      expect(locale.CONTACTS_FILTER.ATTRIBUTES.META_AD_REFERRAL).toBeTruthy();
      expect(locale.CONTACTS_FILTER.ATTRIBUTES.META_AD_SOURCE_ID).toBeTruthy();
    });

    [enContact, ruContact, kkContact].forEach(locale => {
      expect(locale.CONTACTS_LAYOUT.FILTER.META_AD_REFERRAL).toBeTruthy();
      expect(locale.CONTACTS_LAYOUT.FILTER.META_AD_REFERRAL_TRUE).toBeTruthy();
      expect(locale.CONTACTS_LAYOUT.FILTER.META_AD_REFERRAL_FALSE).toBeTruthy();
      expect(locale.CONTACTS_LAYOUT.FILTER.META_AD_SOURCE_ID).toBeTruthy();
    });
  });
});
