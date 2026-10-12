import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  showBadgeOnFavicon,
  startFaviconBlinking,
  stopFaviconBlinking,
} from '../faviconHelper';

const originalVisibilityState = Object.getOwnPropertyDescriptor(
  document,
  'visibilityState'
);

const setVisibilityState = value => {
  Object.defineProperty(document, 'visibilityState', {
    configurable: true,
    value,
  });
};

const faviconPath = () =>
  document.querySelector('.favicon').getAttribute('href');

describe('faviconHelper', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.head.innerHTML =
      '<link class="favicon" rel="icon" sizes="16x16" href="/favicon-16x16.png">';
  });

  afterEach(() => {
    stopFaviconBlinking();
    document.head.innerHTML = '';
    if (originalVisibilityState) {
      Object.defineProperty(
        document,
        'visibilityState',
        originalVisibilityState
      );
    } else {
      delete document.visibilityState;
    }
    vi.useRealTimers();
  });

  it('alternates the notification badge while the tab is hidden', () => {
    setVisibilityState('hidden');

    startFaviconBlinking();

    expect(faviconPath()).toBe('/favicon-badge-16x16.png');
    expect(vi.getTimerCount()).toBe(1);

    vi.advanceTimersByTime(1000);
    expect(faviconPath()).toBe('/favicon-16x16.png');

    vi.advanceTimersByTime(1000);
    expect(faviconPath()).toBe('/favicon-badge-16x16.png');
  });

  it('does not blink when the tab is already visible', () => {
    setVisibilityState('visible');

    startFaviconBlinking();
    vi.advanceTimersByTime(2000);

    expect(faviconPath()).toBe('/favicon-16x16.png');
    expect(vi.getTimerCount()).toBe(0);
  });

  it('restores the regular favicon when the tab becomes visible', () => {
    setVisibilityState('hidden');
    startFaviconBlinking();

    setVisibilityState('visible');
    document.dispatchEvent(new Event('visibilitychange'));

    expect(faviconPath()).toBe('/favicon-16x16.png');
    expect(vi.getTimerCount()).toBe(0);
  });

  it('keeps a single timer when multiple notifications arrive', () => {
    setVisibilityState('hidden');

    startFaviconBlinking();
    startFaviconBlinking();

    expect(vi.getTimerCount()).toBe(1);
  });

  describe('named holders', () => {
    beforeEach(() => setVisibilityState('hidden'));

    it('stops the blinking once its only holder lets go', () => {
      startFaviconBlinking('call');
      expect(faviconPath()).toBe('/favicon-badge-16x16.png');

      stopFaviconBlinking('call');

      expect(faviconPath()).toBe('/favicon-16x16.png');
      expect(vi.getTimerCount()).toBe(0);
    });

    it('keeps blinking for a holder that still needs it', () => {
      startFaviconBlinking();
      startFaviconBlinking('call');

      stopFaviconBlinking('call');

      expect(vi.getTimerCount()).toBe(1);
      expect(faviconPath()).toBe('/favicon-badge-16x16.png');
      vi.advanceTimersByTime(1000);
      expect(faviconPath()).toBe('/favicon-16x16.png');
    });

    it('lets the blinking outlive a holder that started it first', () => {
      startFaviconBlinking('call');
      startFaviconBlinking();

      stopFaviconBlinking('call');

      expect(vi.getTimerCount()).toBe(1);
    });

    it('stops everything when stopped without a holder', () => {
      startFaviconBlinking();
      startFaviconBlinking('call');

      stopFaviconBlinking();
      stopFaviconBlinking('call');

      expect(vi.getTimerCount()).toBe(0);
      expect(faviconPath()).toBe('/favicon-16x16.png');
    });

    it('ignores a holder that never asked and leaves a shown badge alone', () => {
      showBadgeOnFavicon();

      stopFaviconBlinking('call');

      expect(faviconPath()).toBe('/favicon-badge-16x16.png');
    });

    it('brings back an unread badge that was shown before the blinking', () => {
      showBadgeOnFavicon();
      startFaviconBlinking('call');
      vi.advanceTimersByTime(1000);
      expect(faviconPath()).toBe('/favicon-16x16.png');

      stopFaviconBlinking('call');

      expect(faviconPath()).toBe('/favicon-badge-16x16.png');
      expect(vi.getTimerCount()).toBe(0);
    });

    it('keeps the unread badge in mind when another holder joins the blinking', () => {
      showBadgeOnFavicon();
      startFaviconBlinking('call');
      vi.advanceTimersByTime(1000);
      startFaviconBlinking('other');

      stopFaviconBlinking('call');
      stopFaviconBlinking('other');

      expect(faviconPath()).toBe('/favicon-badge-16x16.png');
    });

    it('restores the regular favicon on a stop without a holder even after a badge', () => {
      showBadgeOnFavicon();
      startFaviconBlinking('call');

      stopFaviconBlinking();

      expect(faviconPath()).toBe('/favicon-16x16.png');
    });

    it('does not keep a request made while the tab was visible', () => {
      setVisibilityState('visible');
      startFaviconBlinking('call');
      setVisibilityState('hidden');

      startFaviconBlinking('other');
      stopFaviconBlinking('other');

      expect(vi.getTimerCount()).toBe(0);
    });
  });

  it('blinks the real layout icons and restores their branded URLs', () => {
    document.head.innerHTML = `
      <link rel="icon" href="/favicon.ico?v=onelink-brand">
      <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png?v=onelink-brand">
      <link rel="icon" type="image/svg+xml" sizes="any" href="/favicon.svg?v=onelink-brand">
    `;
    const originalHrefs = Array.from(
      document.querySelectorAll('link[rel~="icon"]')
    ).map(icon => icon.getAttribute('href'));
    setVisibilityState('hidden');

    startFaviconBlinking();

    expect(
      Array.from(document.querySelectorAll('link[rel~="icon"]')).map(icon =>
        icon.getAttribute('href')
      )
    ).toEqual([
      '/favicon-badge-32x32.png',
      '/favicon-badge-32x32.png',
      '/favicon-badge-32x32.png',
    ]);

    setVisibilityState('visible');
    document.dispatchEvent(new Event('visibilitychange'));

    expect(
      Array.from(document.querySelectorAll('link[rel~="icon"]')).map(icon =>
        icon.getAttribute('href')
      )
    ).toEqual(originalHrefs);
  });

  it('restores an icon that originally had no href', () => {
    document.head.innerHTML = '<link rel="icon" sizes="32x32">';
    const icon = document.querySelector('link[rel~="icon"]');
    setVisibilityState('hidden');

    startFaviconBlinking();
    stopFaviconBlinking();

    expect(icon.hasAttribute('href')).toBe(false);
  });

  it('preserves an externally changed branded URL on the same icon', () => {
    const icon = document.querySelector('.favicon');
    setVisibilityState('hidden');
    startFaviconBlinking();

    icon.setAttribute('href', '/tenant-favicon-16x16.png?v=2');
    stopFaviconBlinking();

    expect(icon.getAttribute('href')).toBe('/tenant-favicon-16x16.png?v=2');
  });
});
