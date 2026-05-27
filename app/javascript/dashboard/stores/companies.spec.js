import { setActivePinia, createPinia } from 'pinia';
import CompanyAPI from 'dashboard/api/companies';
import {
  buildCompanyRequestPayload,
  normalizeMeta,
  useCompaniesStore,
} from './companies';

vi.mock('dashboard/api/companies', () => ({
  default: {
    get: vi.fn(),
    show: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
    delete: vi.fn(),
    destroyAvatar: vi.fn(),
    destroyCustomAttributes: vi.fn(),
    listContacts: vi.fn(),
    listNotes: vi.fn(),
    listConversations: vi.fn(),
    searchContacts: vi.fn(),
    createContact: vi.fn(),
    removeContact: vi.fn(),
  },
}));

vi.mock('dashboard/store/utils/api', () => ({
  throwErrorMessage: vi.fn(error => {
    throw error;
  }),
}));

describe('companies pinia store', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.clearAllMocks();
  });

  it('initializes company detail state from custom Pinia state', () => {
    const store = useCompaniesStore();

    expect(store.activeCompanyId).toBeNull();
    expect(store.companyContacts).toEqual([]);
    expect(store.companyConversations).toEqual([]);
    expect(store.companyNotes).toEqual([]);
    expect(store.contactSearchResults).toEqual([]);
    expect(store.uiFlags.fetchingContacts).toBe(false);
  });

  it('normalizes contact meta from Rails response keys', async () => {
    CompanyAPI.listContacts.mockResolvedValue({
      data: {
        meta: { total_count: '2', page: '3' },
        payload: [
          {
            id: 7,
            name: 'Jane',
            phone_number: '+100000000',
            company_id: 4,
          },
        ],
      },
    });

    const store = useCompaniesStore();
    await store.getCompanyContacts(4, 3);

    expect(store.companyContactsMeta).toEqual({ totalCount: 2, page: 3 });
    expect(store.companyContacts[0]).toMatchObject({
      id: 7,
      phoneNumber: '+100000000',
      companyId: 4,
    });
  });

  it('resets company detail state without clearing list loading flag', () => {
    const store = useCompaniesStore();
    store.activeCompanyId = 4;
    store.companyContacts = [{ id: 1 }];
    store.companyNotes = [{ id: 2 }];
    store.setUIFlag({ fetchingList: true, fetchingContacts: true });

    store.resetCompanyDetailState();

    expect(store.activeCompanyId).toBeNull();
    expect(store.companyContacts).toEqual([]);
    expect(store.companyNotes).toEqual([]);
    expect(store.uiFlags.fetchingList).toBe(true);
    expect(store.uiFlags.fetchingContacts).toBe(false);
  });
});

describe('companies store helpers', () => {
  it('normalizes snake_case meta into numeric camelCase keys', () => {
    expect(normalizeMeta({ total_count: '11', page: '2' })).toEqual({
      totalCount: 11,
      page: 2,
    });
  });

  it('wraps non-upload company payloads under company', () => {
    expect(
      buildCompanyRequestPayload({
        name: 'Acme',
        customAttributes: { segment: 'enterprise' },
      })
    ).toEqual({
      company: {
        name: 'Acme',
        custom_attributes: { segment: 'enterprise' },
      },
    });
  });
});
