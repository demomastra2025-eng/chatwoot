import bulkActions from '../bulkActions';
import ApiClient from '../ApiClient';
import axios from 'axios';

vi.mock('axios');
global.axios = axios;

describe('#BulkActionsAPI', () => {
  beforeEach(() => {
    axios.post.mockReset();
    axios.get.mockReset();
  });

  it('creates correct instance', () => {
    expect(bulkActions).toBeInstanceOf(ApiClient);
    expect(bulkActions).toHaveProperty('create');
  });

  it('requests a bounded all-matching selection snapshot with the active filters', async () => {
    const filters = {
      mode: 'advanced',
      query_data: { payload: [{ attribute_key: 'status', values: ['open'] }] },
      unread: true,
    };
    axios.post.mockResolvedValue({ data: { payload: { count: 4 } } });

    await bulkActions.selectAll('CommunicationThread', filters);

    expect(axios.post).toHaveBeenCalledWith(`${bulkActions.url}/selection`, {
      type: 'CommunicationThread',
      filters,
    });
  });

  it('keeps create and status requests bound to the account where the run started', async () => {
    const { pathname, search, hash } = window.location;
    const originalPath = `${pathname}${search}${hash}`;
    axios.post.mockResolvedValue({ data: { payload: { id: 42 } } });

    try {
      window.history.replaceState({}, '', '/app/accounts/12/conversations/5');
      const context = bulkActions.captureContext();
      await bulkActions.create({ type: 'Conversation' }, context);

      window.history.replaceState({}, '', '/app/accounts/34/conversations/9');
      await bulkActions.show(42, context);

      expect(bulkActions.isContextCurrent(context)).toBe(false);
      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/accounts/12/bulk_actions',
        { type: 'Conversation' }
      );
      expect(axios.get).toHaveBeenCalledWith(
        '/api/v1/accounts/12/bulk_action_runs/42'
      );
    } finally {
      window.history.replaceState({}, '', originalPath || '/');
    }
  });
});
