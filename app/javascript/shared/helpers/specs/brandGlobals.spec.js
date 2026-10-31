import { aliasGlobal, installOneLinkGlobals } from '../brandGlobals';

describe('OneLink public globals', () => {
  it('adopts preloaded legacy configuration and keeps assignments in either direction shared', () => {
    const config = { hostURL: 'https://example.test' };
    const settings = { locale: 'kk' };
    const target = { chatwootConfig: config, chatwootSettings: settings };
    installOneLinkGlobals(target);

    expect(target.onelinkConfig).toBe(config);
    expect(target.onelinkSettings).toBe(settings);
    target.chatwootConfig = { hostURL: 'https://new.example.test' };
    expect(target.onelinkConfig).toBe(target.chatwootConfig);
    target.onelinkSettings = { locale: 'ru' };
    expect(target.chatwootSettings).toBe(target.onelinkSettings);
    expect(target.chatonelinkSettings).toBe(target.onelinkSettings);
  });

  it('prefers the canonical configuration when both names were supplied', () => {
    const target = {
      onelinkConfig: { hostURL: 'https://canonical.example.test' },
      chatwootConfig: { hostURL: 'https://legacy.example.test' },
    };
    const canonical = target.onelinkConfig;
    installOneLinkGlobals(target);
    expect(target.chatwootConfig).toBe(canonical);
  });

  it('adopts settings copied from the previously generated misspelled snippets', () => {
    const target = { chatonelinkSettings: { position: 'left' } };
    installOneLinkGlobals(target);
    expect(target.onelinkSettings).toBe(target.chatonelinkSettings);
    target.chatwootSettings = { position: 'right' };
    expect(target.onelinkSettings.position).toBe('right');
  });

  it('preserves an existing SDK and client instance across repeated initialization', () => {
    const sdk = { run: vi.fn() };
    const client = { toggle: vi.fn() };
    const target = { chatwootSDK: sdk, $chatwoot: client };
    installOneLinkGlobals(target);
    installOneLinkGlobals(target);
    expect(target.onelinkSDK).toBe(sdk);
    expect(target.$onelink).toBe(client);
    target.$onelink = { reset: vi.fn() };
    expect(target.$chatwoot).toBe(target.$onelink);
  });

  it('supports a legacy global declared with a non-configurable writable property', () => {
    const target = { onelinkSettings: { locale: 'ru' } };
    Object.defineProperty(target, 'chatwootSettings', {
      value: { locale: 'kk' },
      writable: true,
      configurable: false,
    });
    aliasGlobal(target, 'onelinkSettings', ['chatwootSettings']);
    expect(target.chatwootSettings.locale).toBe('ru');
    target.onelinkSettings = { locale: 'ru' };
    expect(target.chatwootSettings.locale).toBe('ru');
    target.chatwootSettings = { locale: 'en' };
    expect(target.onelinkSettings.locale).toBe('en');
  });

  it('honors a non-configurable readonly host value without breaking canonical boot', () => {
    const settings = { locale: 'en' };
    const target = { onelinkSettings: { locale: 'kk' } };
    Object.defineProperty(target, 'chatwootSettings', {
      value: settings,
      writable: false,
      configurable: false,
    });

    expect(() => installOneLinkGlobals(target)).not.toThrow();
    expect(target.onelinkSettings).toBe(settings);
    expect(() => {
      target.onelinkSettings = { locale: 'ru' };
      target.chatonelinkSettings = { locale: 'kk' };
    }).not.toThrow();
    expect(target.onelinkSettings).toBe(settings);
    expect(target.chatwootSettings).toBe(settings);
    expect(() => installOneLinkGlobals(target)).not.toThrow();
  });

  it('reads a getter-only host global and does not call a missing setter', () => {
    let settings = { locale: 'en' };
    const target = { onelinkSettings: { locale: 'kk' } };
    Object.defineProperty(target, 'chatwootSettings', {
      get: () => settings,
      configurable: false,
    });

    expect(() => installOneLinkGlobals(target)).not.toThrow();
    expect(target.onelinkSettings).toBe(settings);
    expect(() => {
      target.onelinkSettings = { locale: 'ru' };
    }).not.toThrow();
    settings = { locale: 'kk' };
    expect(target.onelinkSettings).toBe(settings);
    expect(
      Object.getOwnPropertyDescriptor(target, 'chatwootSettings').set
    ).toBeUndefined();
  });

  it('forwards writes to an existing non-configurable accessor setter', () => {
    let settings = { locale: 'en' };
    const target = { onelinkSettings: { locale: 'kk' } };
    const setter = vi.fn(next => {
      settings = next;
    });
    Object.defineProperty(target, 'chatwootSettings', {
      get: () => settings,
      set: setter,
      configurable: false,
    });

    installOneLinkGlobals(target);
    expect(settings.locale).toBe('kk');
    target.onelinkSettings = { locale: 'ru' };
    expect(setter).toHaveBeenCalledTimes(2);
    expect(target.chatwootSettings.locale).toBe('ru');
  });
});
