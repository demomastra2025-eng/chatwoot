import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  PHONE_WIDGET_POSITION_STORAGE_KEY,
  clampPhoneWidgetPosition,
  readPhoneWidgetPosition,
  savePhoneWidgetPosition,
} from './usePhoneWidgetPosition';

const viewport = { width: 1280, height: 800 };
const size = { width: 336, height: 300 };

describe('clampPhoneWidgetPosition', () => {
  it('keeps a position that is already inside the window', () => {
    expect(clampPhoneWidgetPosition({ left: 100, top: 120 }, size, viewport))
      .toEqual({ left: 100, top: 120 });
  });

  it.each([
    ['past the right and bottom edges', { left: 5000, top: 5000 }, 936, 492],
    ['past the left and top edges', { left: -400, top: -90 }, 8, 8],
    ['on the right edge only', { left: 1000, top: 200 }, 936, 200],
  ])('pulls a position %s back inside', (_, position, left, top) => {
    expect(clampPhoneWidgetPosition(position, size, viewport)).toEqual({
      left,
      top,
    });
  });

  it('sticks a box larger than the window to the top-left margin', () => {
    expect(
      clampPhoneWidgetPosition(
        { left: 300, top: 300 },
        { width: 500, height: 900 },
        { width: 400, height: 600 }
      )
    ).toEqual({ left: 8, top: 8 });
  });

  it('rounds to whole pixels', () => {
    expect(
      clampPhoneWidgetPosition({ left: 10.6, top: 20.2 }, size, viewport)
    ).toEqual({ left: 11, top: 20 });
  });
});

describe('remembered phone position', () => {
  beforeEach(() => {
    window.localStorage.clear();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    window.localStorage.clear();
  });

  it('saves and reads the position in this browser', () => {
    savePhoneWidgetPosition({ left: 40, top: 60, extra: 'ignored' });

    expect(
      JSON.parse(window.localStorage.getItem(PHONE_WIDGET_POSITION_STORAGE_KEY))
    ).toEqual({ left: 40, top: 60 });
    expect(readPhoneWidgetPosition()).toEqual({ left: 40, top: 60 });
  });

  it.each([
    ['nothing saved', null],
    ['broken JSON', '{left'],
    ['not numbers', '{"left":"a","top":1}'],
    ['missing top', '{"left":1}'],
  ])('falls back to the default place for %s', (_, raw) => {
    if (raw !== null) {
      window.localStorage.setItem(PHONE_WIDGET_POSITION_STORAGE_KEY, raw);
    }

    expect(readPhoneWidgetPosition()).toBeNull();
  });

  it('survives storage that throws (private mode, blocked site data)', () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new Error('SecurityError');
    });
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('QuotaExceededError');
    });

    expect(readPhoneWidgetPosition()).toBeNull();
    expect(() => savePhoneWidgetPosition({ left: 1, top: 2 })).not.toThrow();
  });
});
