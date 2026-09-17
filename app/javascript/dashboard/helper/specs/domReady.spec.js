import { describe, expect, it, vi } from 'vitest';

import { runWhenDOMReady } from '../domReady';

describe('runWhenDOMReady', () => {
  it('runs immediately when the DOM is already ready', () => {
    const callback = vi.fn();
    const documentRef = {
      readyState: 'interactive',
      addEventListener: vi.fn(),
    };

    runWhenDOMReady(callback, documentRef);

    expect(callback).toHaveBeenCalledOnce();
    expect(documentRef.addEventListener).not.toHaveBeenCalled();
  });

  it('waits for DOMContentLoaded only once while the DOM is loading', () => {
    const callback = vi.fn();
    const documentRef = {
      readyState: 'loading',
      addEventListener: vi.fn(),
    };

    runWhenDOMReady(callback, documentRef);

    expect(callback).not.toHaveBeenCalled();
    expect(documentRef.addEventListener).toHaveBeenCalledWith(
      'DOMContentLoaded',
      callback,
      { once: true }
    );
  });
});
