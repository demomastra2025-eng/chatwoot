import { vi } from 'vitest';

const { mockGet, getMockUrl, setMockUrl } = vi.hoisted(() => {
  let currentUrl = '/api/v1/accounts/1/context_fields';

  return {
    mockGet: vi.fn(),
    getMockUrl: () => currentUrl,
    setMockUrl: url => {
      currentUrl = url;
    },
  };
});

vi.mock('dashboard/api/contextFields', () => ({
  default: {
    get url() {
      return getMockUrl();
    },
    get: mockGet,
  },
}));

describe('contextFieldCatalog', () => {
  beforeEach(() => {
    vi.resetModules();
    mockGet.mockReset();
    setMockUrl('/api/v1/accounts/1/context_fields');
  });

  it('reuses the cached catalog for the same account url', async () => {
    mockGet.mockResolvedValue({
      data: [{ id: 'contact.name', title: 'Name' }],
    });

    const { loadContextFieldCatalog } = await import('../contextFieldCatalog');

    const firstResult = await loadContextFieldCatalog();
    const secondResult = await loadContextFieldCatalog();

    expect(firstResult).toEqual([{ id: 'contact.name', title: 'Name' }]);
    expect(secondResult).toEqual([{ id: 'contact.name', title: 'Name' }]);
    expect(mockGet).toHaveBeenCalledTimes(1);
  });

  it('fetches a fresh catalog when the account url changes', async () => {
    mockGet
      .mockResolvedValueOnce({
        data: [{ id: 'contact.name', title: 'Name' }],
      })
      .mockResolvedValueOnce({
        data: [{ id: 'deal.title', title: 'Deal Title' }],
      });

    const { loadContextFieldCatalog } = await import('../contextFieldCatalog');

    const firstResult = await loadContextFieldCatalog();
    setMockUrl('/api/v1/accounts/2/context_fields');
    const secondResult = await loadContextFieldCatalog();

    expect(firstResult).toEqual([{ id: 'contact.name', title: 'Name' }]);
    expect(secondResult).toEqual([{ id: 'deal.title', title: 'Deal Title' }]);
    expect(mockGet).toHaveBeenCalledTimes(2);
  });
});
