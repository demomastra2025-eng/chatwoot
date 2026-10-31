// Public OneLink globals share one value with previously installed embeds.
export const aliasGlobal = (target, canonicalName, legacyNames) => {
  const names = [canonicalName, ...legacyNames];
  const initialName = names.find(name => target[name] !== undefined);
  const initialValue = initialName ? target[initialName] : undefined;
  const fixedName = names.find(name => {
    const descriptor = Object.getOwnPropertyDescriptor(target, name);
    return descriptor && !descriptor.configurable;
  });
  let value = initialValue;
  const getValue = fixedName ? () => target[fixedName] : () => value;
  const setValue = nextValue => {
    if (fixedName) {
      target[fixedName] = nextValue;
    } else {
      value = nextValue;
    }
  };

  if (fixedName && target[fixedName] !== initialValue) {
    setValue(initialValue);
  }

  names.forEach(name => {
    const descriptor = Object.getOwnPropertyDescriptor(target, name);
    if (descriptor && !descriptor.configurable) return;

    Object.defineProperty(target, name, {
      configurable: true,
      enumerable: true,
      get: getValue,
      set: setValue,
    });
  });
};

export const installOneLinkGlobals = (target = window) => {
  aliasGlobal(target, 'onelinkConfig', ['chatwootConfig']);
  aliasGlobal(target, 'onelinkSettings', [
    'chatwootSettings',
    'chatonelinkSettings',
  ]);
  aliasGlobal(target, 'onelinkSDK', ['chatwootSDK']);
  aliasGlobal(target, '$onelink', ['$chatwoot']);
};
