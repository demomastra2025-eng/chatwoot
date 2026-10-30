import CrmDealsAPI from './deals';
import {
  AVAILABLE_CUSTOM_ROLE_PERMISSIONS,
  CONTACT_IIN_VIEW_PERMISSION,
} from 'dashboard/constants/permissions';
import ruCustomRole from 'dashboard/i18n/locale/ru/customRole.json';
import enCustomRole from 'dashboard/i18n/locale/en/customRole.json';
import kkCustomRole from 'dashboard/i18n/locale/kk/customRole.json';
import ruCrm from 'dashboard/i18n/locale/ru/crm.json';
import enCrm from 'dashboard/i18n/locale/en/crm.json';
import kkCrm from 'dashboard/i18n/locale/kk/crm.json';

describe('CrmDealsAPI & Green Clinic permissions/i18n', () => {
  it('exposes contact_iin_view permission and translations across ru, en, kk', () => {
    expect(CONTACT_IIN_VIEW_PERMISSION).toBe('contact_iin_view');
    expect(AVAILABLE_CUSTOM_ROLE_PERMISSIONS).toContain('contact_iin_view');
    expect(ruCustomRole.CUSTOM_ROLE.PERMISSIONS.CONTACT_IIN_VIEW).toBeTruthy();
    expect(enCustomRole.CUSTOM_ROLE.PERMISSIONS.CONTACT_IIN_VIEW).toBeTruthy();
    expect(kkCustomRole.CUSTOM_ROLE.PERMISSIONS.CONTACT_IIN_VIEW).toBeTruthy();
  });

  it('requests /crm/deals/export with blob responseType and exposes export i18n keys', () => {
    const axiosMock = { get: vi.fn(() => Promise.resolve({ data: new Blob() })) };
    window.axios = axiosMock;

    CrmDealsAPI.exportDeals({ pipeline_id: 7, export_format: 'xlsx' });

    expect(axiosMock.get).toHaveBeenCalledWith(
      expect.stringContaining('/crm/deals/export'),
      {
        params: { pipeline_id: 7, export_format: 'xlsx' },
        responseType: 'blob',
      }
    );
    expect(ruCrm.CRM.DEALS.EXPORT.XLSX).toBeTruthy();
    expect(enCrm.CRM.DEALS.EXPORT.XLSX).toBeTruthy();
    expect(kkCrm.CRM.DEALS.EXPORT.XLSX).toBeTruthy();
  });
});
