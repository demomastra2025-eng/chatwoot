import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import AiOrb from './AiOrb.vue';
import {
  MODE_FRAMES,
  paintFrame,
  resolvePreset,
} from './vendor/thinkingOrbsEngine';

// The real engine computes and paints the dots; these wrappers only record how
// the orb calls it.
vi.mock('./vendor/thinkingOrbsEngine', async importOriginal => {
  const actual = await importOriginal();
  return {
    ...actual,
    resolvePreset: vi.fn(actual.resolvePreset),
    paintFrame: vi.fn(actual.paintFrame),
    MODE_FRAMES: Object.fromEntries(
      Object.entries(actual.MODE_FRAMES).map(([mode, frame]) => [
        mode,
        vi.fn(frame),
      ])
    ),
  };
});

// A drawing context that records what is painted
const makeContext = () => {
  const fills = [];
  const ctx = {
    fills,
    clearRect: vi.fn(),
    setTransform: vi.fn(),
    beginPath: vi.fn(),
    arc: vi.fn(),
    fill: vi.fn(),
    moveTo: vi.fn(),
    lineTo: vi.fn(),
    stroke: vi.fn(),
    strokeStyle: '',
    lineWidth: 1,
  };
  Object.defineProperty(ctx, 'fillStyle', {
    get: () => fills[fills.length - 1],
    set: value => {
      fills.push(value);
    },
  });
  return ctx;
};

const START = 1000;
const FRAME_MS = 16;
const FRAME_S = FRAME_MS / 1000;

let ctx;
let getContext;
let clock;
let frameCallbacks;
let nextFrameId;
let intersection;
let reducedMotion;
let motionQuery;
let motionListener;

const stubBrowser = () => {
  ctx = makeContext();
  getContext = vi
    .spyOn(HTMLCanvasElement.prototype, 'getContext')
    .mockImplementation(() => ctx);
  clock = vi.spyOn(performance, 'now').mockReturnValue(START);

  frameCallbacks = new Map();
  nextFrameId = 1;
  vi.stubGlobal(
    'requestAnimationFrame',
    vi.fn(callback => {
      const id = nextFrameId;
      nextFrameId += 1;
      frameCallbacks.set(id, callback);
      return id;
    })
  );
  vi.stubGlobal(
    'cancelAnimationFrame',
    vi.fn(id => frameCallbacks.delete(id))
  );

  motionListener = null;
  motionQuery = {
    matches: reducedMotion,
    addEventListener: (_name, handler) => {
      motionListener = handler;
    },
    removeEventListener: vi.fn(),
  };
  vi.stubGlobal(
    'matchMedia',
    vi.fn(() => motionQuery)
  );

  intersection = null;
  vi.stubGlobal(
    'IntersectionObserver',
    class {
      constructor(callback) {
        this.callback = callback;
        this.disconnect = vi.fn();
        this.observe = vi.fn();
        intersection = this;
      }
    }
  );
};

// Runs the pending animation frame at this time, like the browser would
const tick = now => {
  const [id, callback] = [...frameCallbacks.entries()][0] || [];
  if (!callback) return false;
  frameCallbacks.delete(id);
  callback(now);
  return true;
};

const setHidden = hidden => {
  Object.defineProperty(document, 'hidden', {
    configurable: true,
    get: () => hidden,
  });
  document.dispatchEvent(new Event('visibilitychange'));
};

// The time the engine was asked to draw at, one entry per painted frame
const drawnTimes = () => MODE_FRAMES.globe.mock.calls.map(call => call[1]);
const speedOfGlobe = () => resolvePreset.mock.results[0].value.speed;

describe('AiOrb', () => {
  let wrapper;

  beforeEach(() => {
    vi.clearAllMocks();
    reducedMotion = false;
    stubBrowser();
    setHidden(false);
    document.body.classList.remove('dark');
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    vi.unstubAllGlobals();
    getContext.mockRestore();
    clock.mockRestore();
    document.body.classList.remove('dark');
  });

  const mountOrb = (props = {}) => {
    wrapper = mount(AiOrb, { props, attachTo: document.body });
    return wrapper;
  };

  it('is a decoration: hidden from assistive technology, no text', () => {
    mountOrb();

    expect(wrapper.attributes('aria-hidden')).toBe('true');
    expect(wrapper.find('canvas').exists()).toBe(true);
    expect(wrapper.text()).toBe('');
  });

  it('draws a globe of dots with the engine on its 64-unit grid', () => {
    mountOrb();

    expect(resolvePreset).toHaveBeenCalledWith('searching', 64);
    const preset = resolvePreset.mock.results[0].value;
    expect(preset.mode).toBe('globe');
    expect(MODE_FRAMES.globe).toHaveBeenCalledTimes(1);
    expect(MODE_FRAMES.globe).toHaveBeenCalledWith(
      64,
      expect.any(Number),
      preset.opts
    );
    expect(ctx.clearRect).toHaveBeenCalledWith(0, 0, 64, 64);
    expect(paintFrame).toHaveBeenCalledTimes(1);
    const [target, frame] = paintFrame.mock.calls[0];
    expect(target).toBe(ctx);
    expect(frame.dots.length).toBeGreaterThan(0);
    // the engine really drew them on the context
    expect(ctx.arc).toHaveBeenCalled();
    expect(ctx.fill).toHaveBeenCalled();
  });

  it('draws at its own size and scales the grid for the pixel ratio', () => {
    const canvas = mountOrb().get('canvas').element;

    const ratio = Math.min(2, window.devicePixelRatio || 1);
    expect(canvas.width).toBe(84 * ratio);
    expect(canvas.height).toBe(canvas.width);
    const scale = (ratio * 84) / 64;
    expect(ctx.setTransform).toHaveBeenCalledWith(scale, 0, 0, scale, 0, 0);
  });

  it('is the same globe whatever the stage: one state, never another mode', () => {
    mountOrb();
    tick(START + FRAME_MS);
    tick(START + 2 * FRAME_MS);

    expect(
      resolvePreset.mock.calls.every(
        ([state, size]) => state === 'searching' && size === 64
      )
    ).toBe(true);
    Object.entries(MODE_FRAMES)
      .filter(([mode]) => mode !== 'globe')
      .forEach(([, frame]) => expect(frame).not.toHaveBeenCalled());
    expect(MODE_FRAMES.globe).toHaveBeenCalledTimes(3);
  });

  it('paints a frame at once and keeps painting while it is visible', () => {
    mountOrb();
    expect(paintFrame).toHaveBeenCalledTimes(1);
    expect(requestAnimationFrame).toHaveBeenCalledTimes(1);

    tick(START + FRAME_MS);
    tick(START + 2 * FRAME_MS);

    expect(paintFrame).toHaveBeenCalledTimes(3);
    expect(requestAnimationFrame).toHaveBeenCalledTimes(3);
  });

  it('turns at the pace of the clock: constant, one speed for every stage', () => {
    mountOrb();
    tick(START + FRAME_MS);
    tick(START + 2 * FRAME_MS);
    tick(START + 3 * FRAME_MS);

    const times = drawnTimes();
    const step = FRAME_S * speedOfGlobe();
    expect(times[1] - times[0]).toBeCloseTo(step, 6);
    expect(times[2] - times[1]).toBeCloseTo(step, 6);
    expect(times[3] - times[2]).toBeCloseTo(step, 6);
  });

  describe('when the system asks to reduce motion', () => {
    it('keeps turning, never a still frame', () => {
      reducedMotion = true;
      stubBrowser();
      mountOrb();

      expect(requestAnimationFrame).toHaveBeenCalledTimes(1);
      tick(START + FRAME_MS);
      tick(START + 2 * FRAME_MS);
      tick(START + 3 * FRAME_MS);

      expect(paintFrame).toHaveBeenCalledTimes(4);
      expect(requestAnimationFrame).toHaveBeenCalledTimes(4);
      expect(frameCallbacks.size).toBe(1);
    });

    it('turns at half speed', () => {
      reducedMotion = true;
      stubBrowser();
      mountOrb();
      tick(START + FRAME_MS);
      tick(START + 2 * FRAME_MS);

      const times = drawnTimes();
      const half = (FRAME_S * speedOfGlobe()) / 2;
      expect(times[1] - times[0]).toBeCloseTo(half, 6);
      expect(times[2] - times[1]).toBeCloseTo(half, 6);
    });

    it('changes the pace, not the loop, when the preference changes', () => {
      mountOrb();
      tick(START + FRAME_MS);
      const full = FRAME_S * speedOfGlobe();

      motionQuery.matches = true;
      motionListener();
      expect(frameCallbacks.size).toBe(1);
      tick(START + 2 * FRAME_MS);

      motionQuery.matches = false;
      motionListener();
      expect(frameCallbacks.size).toBe(1);
      tick(START + 3 * FRAME_MS);

      const times = drawnTimes();
      expect(times[1] - times[0]).toBeCloseTo(full, 6);
      expect(times[2] - times[1]).toBeCloseTo(full / 2, 6);
      expect(times[3] - times[2]).toBeCloseTo(full, 6);
    });
  });

  it('stops while the tab is hidden and resumes when it is shown again', () => {
    mountOrb();
    expect(frameCallbacks.size).toBe(1);

    setHidden(true);
    expect(frameCallbacks.size).toBe(0);
    expect(tick(START + FRAME_MS)).toBe(false);

    setHidden(false);
    expect(frameCallbacks.size).toBe(1);
    expect(tick(START + 2 * FRAME_MS)).toBe(true);
  });

  it('stops while scrolled out of view and resumes when it comes back', () => {
    mountOrb();
    expect(intersection.observe).toHaveBeenCalledTimes(1);

    intersection.callback([{ isIntersecting: false }]);
    expect(frameCallbacks.size).toBe(0);

    intersection.callback([{ isIntersecting: true }]);
    expect(frameCallbacks.size).toBe(1);
  });

  it('never asks for two frames at once', () => {
    mountOrb();
    intersection.callback([{ isIntersecting: true }]);
    setHidden(false);

    expect(frameCallbacks.size).toBe(1);
  });

  it('stops for good and lets go of everything when it goes away', async () => {
    mountOrb();
    const observer = intersection;
    const painted = paintFrame.mock.calls.length;

    wrapper.unmount();
    wrapper = null;

    expect(frameCallbacks.size).toBe(0);
    expect(cancelAnimationFrame).toHaveBeenCalled();
    expect(observer.disconnect).toHaveBeenCalled();
    expect(motionQuery.removeEventListener).toHaveBeenCalledWith(
      'change',
      motionListener
    );
    // a late visibility change or theme switch finds nothing to restart
    setHidden(true);
    setHidden(false);
    document.body.classList.add('dark');
    await flushPromises();
    expect(frameCallbacks.size).toBe(0);
    expect(paintFrame).toHaveBeenCalledTimes(painted);
  });

  describe('colours', () => {
    it('paints for the light theme with the product blue as the tint', () => {
      mountOrb();

      const [, , dark, tint] = paintFrame.mock.calls[0];
      expect(dark).toBe(false);
      expect(tint).toEqual({ r: 8, g: 109, b: 224 });
    });

    it('paints for the dark theme when the page is dark', () => {
      document.body.classList.add('dark');
      mountOrb();

      expect(paintFrame.mock.calls[0][2]).toBe(true);
    });

    it('takes the blue of the theme from the page tokens', () => {
      const style = vi
        .spyOn(window, 'getComputedStyle')
        .mockReturnValue({ getPropertyValue: () => ' 126 182 255 ' });
      mountOrb();
      style.mockRestore();

      expect(paintFrame.mock.calls[0][3]).toEqual({ r: 126, g: 182, b: 255 });
    });

    it('repaints a stopped orb when the theme is switched', async () => {
      mountOrb();
      setHidden(true);
      const painted = paintFrame.mock.calls.length;

      document.body.classList.add('dark');
      await flushPromises();

      expect(paintFrame).toHaveBeenCalledTimes(painted + 1);
      expect(paintFrame.mock.lastCall[2]).toBe(true);
      expect(frameCallbacks.size).toBe(0);
    });
  });

  it('survives a browser without canvas support', () => {
    getContext.mockReturnValue(null);

    expect(() => mountOrb()).not.toThrow();
    expect(requestAnimationFrame).not.toHaveBeenCalled();
    expect(paintFrame).not.toHaveBeenCalled();
  });
});
