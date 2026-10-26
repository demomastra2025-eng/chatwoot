import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import AiOrb from './AiOrb.vue';

// A drawing context that records what is painted
const makeContext = () => {
  const fills = [];
  const gradient = () => ({ addColorStop: vi.fn() });
  const ctx = {
    fills,
    clearRect: vi.fn(),
    fillRect: vi.fn(),
    save: vi.fn(),
    restore: vi.fn(),
    beginPath: vi.fn(),
    arc: vi.fn(),
    clip: vi.fn(),
    stroke: vi.fn(),
    setTransform: vi.fn(),
    createRadialGradient: vi.fn(gradient),
    createLinearGradient: vi.fn(gradient),
    globalCompositeOperation: 'source-over',
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

let ctx;
let frameCallbacks;
let nextFrameId;
let intersection;
let reducedMotion;
let motionQuery;
let motionListener;

const stubBrowser = () => {
  ctx = makeContext();
  vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockImplementation(
    () => ctx
  );

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

// Runs the pending animation frame, like the browser would
const tick = (time = 16) => {
  const [id, callback] = [...frameCallbacks.entries()][0] || [];
  if (!callback) return false;
  frameCallbacks.delete(id);
  callback(performance.now() + time);
  return true;
};

const setHidden = hidden => {
  Object.defineProperty(document, 'hidden', {
    configurable: true,
    get: () => hidden,
  });
  document.dispatchEvent(new Event('visibilitychange'));
};

describe('AiOrb', () => {
  let wrapper;

  beforeEach(() => {
    reducedMotion = false;
    stubBrowser();
    setHidden(false);
    document.body.classList.remove('dark');
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
    document.body.classList.remove('dark');
  });

  const mountOrb = (props = {}) => {
    wrapper = mount(AiOrb, { props, attachTo: document.body });
    return wrapper;
  };

  it('is a decoration: hidden from assistive technology, no text', () => {
    mountOrb({ stage: 'knowledge' });

    expect(wrapper.attributes('aria-hidden')).toBe('true');
    expect(wrapper.find('canvas').exists()).toBe(true);
    expect(wrapper.text()).toBe('');
  });

  it('paints a frame at once and keeps painting while it is visible', () => {
    mountOrb();
    const painted = ctx.fillRect.mock.calls.length;
    expect(painted).toBeGreaterThan(0);
    expect(requestAnimationFrame).toHaveBeenCalledTimes(1);

    tick();
    tick();

    expect(ctx.fillRect.mock.calls.length).toBeGreaterThan(painted);
    expect(requestAnimationFrame).toHaveBeenCalledTimes(3);
  });

  it('draws at its own size and scales for the pixel ratio', () => {
    const canvas = mountOrb().get('canvas').element;

    expect(canvas.width).toBe(84 * Math.min(2, window.devicePixelRatio || 1));
    expect(canvas.height).toBe(canvas.width);
    expect(ctx.setTransform).toHaveBeenCalled();
  });

  it('draws a still frame and never starts an animation when motion is reduced', () => {
    reducedMotion = true;
    stubBrowser();
    mountOrb();

    expect(ctx.fillRect).toHaveBeenCalled();
    expect(requestAnimationFrame).not.toHaveBeenCalled();
  });

  it('repaints a still orb when the stage changes', async () => {
    reducedMotion = true;
    stubBrowser();
    mountOrb({ stage: 'analyzing' });
    const painted = ctx.fillRect.mock.calls.length;

    await wrapper.setProps({ stage: 'slots' });

    expect(ctx.fillRect.mock.calls.length).toBeGreaterThan(painted);
    expect(requestAnimationFrame).not.toHaveBeenCalled();
  });

  it('stops and starts the animation when the motion preference changes', () => {
    mountOrb();
    expect(frameCallbacks.size).toBe(1);

    motionQuery.matches = true;
    motionListener();
    expect(frameCallbacks.size).toBe(0);

    motionQuery.matches = false;
    motionListener();
    expect(frameCallbacks.size).toBe(1);
  });

  it('stops while the tab is hidden and resumes when it is shown again', () => {
    mountOrb();
    expect(frameCallbacks.size).toBe(1);

    setHidden(true);
    expect(frameCallbacks.size).toBe(0);
    expect(tick()).toBe(false);

    setHidden(false);
    expect(frameCallbacks.size).toBe(1);
    expect(tick()).toBe(true);
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

  it('cleans up when it goes away', () => {
    mountOrb();
    const observer = intersection;

    wrapper.unmount();
    wrapper = null;

    expect(frameCallbacks.size).toBe(0);
    expect(observer.disconnect).toHaveBeenCalled();
    // a late visibility change finds nothing to restart
    setHidden(true);
    setHidden(false);
    expect(frameCallbacks.size).toBe(0);
  });

  it('paints on a dark base in the dark theme and on a light one otherwise', () => {
    mountOrb();
    expect(ctx.fills).toContain('#e9f1fb');
    expect(ctx.fills).not.toContain('#0e1d3a');

    wrapper.unmount();
    wrapper = null;
    stubBrowser();
    document.body.classList.add('dark');
    mountOrb();

    expect(ctx.fills).toContain('#0e1d3a');
    expect(ctx.fills).not.toContain('#e9f1fb');
  });

  it('survives a browser without canvas support', () => {
    vi.mocked(HTMLCanvasElement.prototype.getContext).mockReturnValue(null);

    expect(() => mountOrb()).not.toThrow();
    expect(requestAnimationFrame).not.toHaveBeenCalled();
  });

  it('accepts a stage it does not know', () => {
    expect(() => mountOrb({ stage: 'something_new' })).not.toThrow();
    expect(ctx.fillRect).toHaveBeenCalled();
  });
});
