import axios from 'axios';
import { createPinia, setActivePinia } from 'pinia';

import { useInboxStore } from './inboxes';

global.axios = axios;
vi.mock('axios');

const inbox = (id, attributes = {}) => ({
  id,
  name: `Inbox ${id}`,
  channel_type: 'Channel::WebWidget',
  ...attributes,
});

describe('useInboxStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    axios.get.mockReset();
    axios.post.mockReset();
    axios.patch.mockReset();
    axios.delete.mockReset();
  });

  it('exposes the existing inbox state and getter contract', () => {
    const store = useInboxStore();
    const visibleInbox = inbox(1);
    const deletingInbox = inbox(2, {
      channel_type: 'Channel::Whatsapp',
      lifecycle_state: 'deleting',
    });

    store.records = [visibleInbox, deletingInbox];

    expect(store.getInboxes).toEqual([visibleInbox]);
    expect(store.getAllInboxes).toEqual([
      expect.objectContaining({ id: 1, channelType: 'Channel::WebWidget' }),
    ]);
    expect(store.getInbox(1)).toEqual(visibleInbox);
    expect(store.getInbox(999)).toEqual({});
    expect(store.getInboxById(1)).toEqual(
      expect.objectContaining({ id: 1, channelType: 'Channel::WebWidget' })
    );
    expect(store.getUIFlags).toEqual(
      expect.objectContaining({ isFetching: false, isUpdating: false })
    );
  });

  it('preserves create, replace, update, and delete record semantics', () => {
    const store = useInboxStore();

    store.applyMutation('ADD_INBOXES', inbox(1));
    store.applyMutation('SET_INBOXES_ITEM', inbox(2));
    store.applyMutation('SET_INBOXES_ITEM', inbox(1, { name: 'Replaced' }));
    store.applyMutation('EDIT_INBOXES', inbox(2, { name: 'Updated' }));
    store.applyMutation('DELETE_INBOXES', 1);

    expect(store.records).toEqual([inbox(2, { name: 'Updated' })]);
  });

  it('merges status-only WhatsApp Web responses with this store records', async () => {
    const store = useInboxStore();
    store.records = [
      inbox(123, {
        additional_attributes: {
          evolution: {
            qrcode: { base64: 'existing-qr' },
            status: 'waiting_for_qr',
          },
        },
      }),
    ];
    axios.post.mockResolvedValue({
      data: {
        id: 123,
        additional_attributes: {
          evolution: { status: 'connected', connection_state: 'open' },
        },
      },
    });

    const result = await store.refreshWhatsappWebQr({
      inboxId: 123,
      statusOnly: true,
    });

    expect(result.additional_attributes.evolution).toEqual({
      qrcode: { base64: 'existing-qr' },
      status: 'connected',
      connection_state: 'open',
    });
    expect(store.getInbox(123)).toEqual(result);
  });

  it('serializes WhatsApp Web lifecycle requests inside one store', async () => {
    const store = useInboxStore();
    let resolveRequest;
    axios.post.mockReturnValue(
      new Promise(resolve => {
        resolveRequest = resolve;
      })
    );

    const first = store.refreshWhatsappWebQr({
      inboxId: 123,
      statusOnly: true,
    });
    const second = store.refreshWhatsappWebQr({
      inboxId: 123,
      statusOnly: true,
      includeQrCode: true,
    });

    expect(axios.post).toHaveBeenCalledTimes(1);
    resolveRequest({ data: inbox(123) });
    await expect(Promise.all([first, second])).resolves.toEqual([
      inbox(123),
      inbox(123),
    ]);
  });

  it('isolates WhatsApp Web lifecycle requests between store instances', async () => {
    const firstStore = useInboxStore(createPinia());
    const secondStore = useInboxStore(createPinia());
    const resolvers = [];
    axios.post.mockImplementation(
      () =>
        new Promise(resolve => {
          resolvers.push(resolve);
        })
    );

    const first = firstStore.refreshWhatsappWebQr({
      inboxId: 123,
      statusOnly: true,
    });
    const second = secondStore.refreshWhatsappWebQr({
      inboxId: 123,
      statusOnly: true,
    });

    expect(axios.post).toHaveBeenCalledTimes(2);
    resolvers.forEach(resolve => resolve({ data: inbox(123) }));
    await expect(Promise.all([first, second])).resolves.toEqual([
      inbox(123),
      inbox(123),
    ]);
  });

  it('isolates Telegram Personal diagnostics between store instances', async () => {
    const firstStore = useInboxStore(createPinia());
    const secondStore = useInboxStore(createPinia());
    axios.get
      .mockResolvedValueOnce({ data: { connected: true } })
      .mockResolvedValueOnce({ data: { connected: false } });

    const [first, second] = await Promise.all([
      firstStore.getTelegramPersonalDiagnostics(123),
      secondStore.getTelegramPersonalDiagnostics(123),
    ]);

    expect(axios.get).toHaveBeenCalledTimes(2);
    expect(first).toEqual({ connected: true });
    expect(second).toEqual({ connected: false });
  });

  it('isolates Weixin diagnostics between store instances', async () => {
    const firstStore = useInboxStore(createPinia());
    const secondStore = useInboxStore(createPinia());
    axios.get
      .mockResolvedValueOnce({ data: { connected: true } })
      .mockResolvedValueOnce({ data: { connected: false } });

    const [first, second] = await Promise.all([
      firstStore.getWeixinDiagnostics(123),
      secondStore.getWeixinDiagnostics(123),
    ]);

    expect(axios.get).toHaveBeenCalledTimes(2);
    expect(first).toEqual({ connected: true });
    expect(second).toEqual({ connected: false });
  });

  it('deduplicates and caches Telegram Personal diagnostics inside one store', async () => {
    const store = useInboxStore();
    axios.get.mockResolvedValue({ data: { connected: true } });

    const [first, second] = await Promise.all([
      store.getTelegramPersonalDiagnostics(123),
      store.getTelegramPersonalDiagnostics(123),
    ]);
    const cached = await store.getTelegramPersonalDiagnostics(123);

    expect(axios.get).toHaveBeenCalledTimes(1);
    expect(first).toEqual({ connected: true });
    expect(second).toBe(first);
    expect(cached).toBe(first);
  });

  it('deduplicates and caches Weixin diagnostics inside one store', async () => {
    const store = useInboxStore();
    axios.get.mockResolvedValue({ data: { connected: true } });

    const [first, second] = await Promise.all([
      store.getWeixinDiagnostics(123),
      store.getWeixinDiagnostics(123),
    ]);
    const cached = await store.getWeixinDiagnostics(123);

    expect(axios.get).toHaveBeenCalledTimes(1);
    expect(first).toEqual({ connected: true });
    expect(second).toBe(first);
    expect(cached).toBe(first);
  });

  it('updates the Pinia record after syncing WhatsApp templates', async () => {
    const store = useInboxStore();
    store.records = [inbox(123, { message_templates: [] })];
    const updatedInbox = inbox(123, {
      message_templates: [{ name: 'order_update', status: 'APPROVED' }],
    });
    axios.post.mockResolvedValue({ data: updatedInbox });

    await expect(store.syncTemplates(123)).resolves.toEqual(updatedInbox);

    expect(store.getInbox(123)).toEqual(updatedInbox);
  });
});
