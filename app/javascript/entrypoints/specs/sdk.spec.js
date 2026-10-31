const { frame } = vi.hoisted(() => ({
  frame: {
    createFrame: vi.fn(),
    sendMessage: vi.fn(),
    events: { toggleBubble: vi.fn() },
  },
}));
vi.mock('../../sdk/IFrameHelper', () => ({ IFrameHelper: frame }));

const names = [
  'onelinkConfig',
  'chatwootConfig',
  'onelinkSettings',
  'chatwootSettings',
  'chatonelinkSettings',
  'onelinkSDK',
  'chatwootSDK',
  '$onelink',
  '$chatwoot',
];

describe('SDK public compatibility', () => {
  let descriptors;
  beforeEach(() => {
    descriptors = new Map(
      names.map(name => [name, Object.getOwnPropertyDescriptor(window, name)])
    );
    names.forEach(name => delete window[name]);
    vi.resetModules();
    vi.clearAllMocks();
  });
  afterEach(() => {
    names.forEach(name => {
      delete window[name];
      if (descriptors.get(name))
        Object.defineProperty(window, name, descriptors.get(name));
    });
  });

  it('boots a preloaded legacy embed and publishes the identical SDK/client under OneLink names', async () => {
    window.chatwootSettings = { locale: 'kk', position: 'left' };
    await import('../sdk');
    expect(window.onelinkSDK).toBe(window.chatwootSDK);
    window.chatwootSDK.run({
      baseUrl: 'https://example.test',
      websiteToken: 'test-token',
    });
    expect(window.$onelink).toBe(window.$chatwoot);
    expect(window.$onelink).toMatchObject({ locale: 'kk', position: 'left' });
    expect(frame.createFrame).toHaveBeenCalledTimes(1);
    window.onelinkSDK.run({
      baseUrl: 'https://example.test',
      websiteToken: 'test-token',
    });
    expect(frame.createFrame).toHaveBeenCalledTimes(1);
  });

  it('uses canonical settings and supports a new OneLink embed', async () => {
    window.onelinkSettings = { locale: 'ru', position: 'left' };
    await import('../sdk');
    window.onelinkSDK.run({
      baseUrl: 'https://example.test',
      websiteToken: 'test-token',
    });
    expect(window.$chatwoot).toBe(window.$onelink);
    expect(window.$onelink.locale).toBe('ru');
  });

  it('honors already copied misspelled settings snippets', async () => {
    window.chatonelinkSettings = { locale: 'kk', position: 'left' };
    await import('../sdk');
    window.onelinkSDK.run({
      baseUrl: 'https://example.test',
      websiteToken: 'test-token',
    });
    expect(window.$onelink).toMatchObject({ locale: 'kk', position: 'left' });
  });

  it('preserves a client created by a cached legacy SDK instead of making a second iframe', async () => {
    const client = { hasLoaded: true, toggle: vi.fn() };
    window.$chatwoot = client;
    await import('../sdk');
    window.onelinkSDK.run({
      baseUrl: 'https://example.test',
      websiteToken: 'test-token',
    });
    expect(window.$onelink).toBe(client);
    expect(frame.createFrame).not.toHaveBeenCalled();
  });
});
