import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import { h, nextTick } from 'vue';
import { VueCal } from 'vue-cal';

// An event (or a new appointment) only changes while the pointer button is held and dragged,
// never on a plain click, and a gesture that loses its release never keeps following the pointer.

const at = (hours, minutes = 0) => new Date(2026, 9, 27, hours, minutes);
const pad = value => String(value).padStart(2, '0');
const range = ({ start, end }) =>
  `${pad(start.getHours())}:${pad(start.getMinutes())}-${pad(
    end.getHours()
  )}:${pad(end.getMinutes())}`;

// The mocked cell is 1000px tall for 08:00-20:00, so 1px = 0.72 minute: 11:00 is at 250px.
const ORIGINAL = '10:00-11:00';
const ON_BORDER = 248; // Inside the 8px resizer strip at the bottom of the 10:00-11:00 event.
const DRAGGED_TO = 300; // 11:35 once snapped to 5 minutes.
const DRAGGED_RANGE = '10:00-11:35';

const flush = async () => {
  for (let i = 0; i < 5; i += 1) {
    // eslint-disable-next-line no-await-in-loop
    await Promise.resolve();
    // eslint-disable-next-line no-await-in-loop
    await nextTick();
  }
};
const settle = () =>
  new Promise(resolve => {
    setTimeout(resolve, 10);
  });

const mouse = (target, type, clientY, init = {}) =>
  target.dispatchEvent(
    new MouseEvent(type, {
      bubbles: true,
      cancelable: true,
      clientX: 50,
      clientY,
      ...init,
    })
  );
const press = (target, clientY) =>
  mouse(target, 'mousedown', clientY, { button: 0, buttons: 1 });
const move = (clientY, buttons = 1) =>
  mouse(document, 'mousemove', clientY, { buttons });
const release = (target, clientY) =>
  mouse(target, 'mouseup', clientY, { button: 0, buttons: 0 });

const touch = (type, target, clientY) => {
  const event = new Event(type, { bubbles: true, cancelable: true });
  const point = { clientX: 50, clientY, target };
  const ended = ['touchend', 'touchcancel'].includes(type);
  Object.defineProperty(event, 'touches', { value: ended ? [] : [point] });
  target.dispatchEvent(event);
};

let wrapper;
let events;
let rejections;
let liveListeners;
let savedRejectionListeners;

// Net document/window listeners of the gesture types: what is still attached right now.
const trackListeners = () => {
  const ids = new Map();
  const idOf = fn => {
    if (!ids.has(fn)) ids.set(fn, ids.size);
    return ids.get(fn);
  };
  const watched = [
    'mousemove',
    'touchmove',
    'mouseup',
    'touchend',
    'touchcancel',
    'keydown',
    'blur',
  ];
  const live = new Set();
  [
    ['document', document],
    ['window', window],
  ].forEach(([name, target]) => {
    const add = target.addEventListener.bind(target);
    const remove = target.removeEventListener.bind(target);
    vi.spyOn(target, 'addEventListener').mockImplementation(
      (type, fn, opts) => {
        const key = `${name}:${type}:${idOf(fn)}`;
        add(type, fn, opts);
        if (!watched.includes(type)) return;
        live.add(key);
        // A `once` listener detaches itself after running: a twin registered right after it
        // runs next and forgets it.
        if (opts?.once) add(type, () => live.delete(key), { once: true });
      }
    );
    vi.spyOn(target, 'removeEventListener').mockImplementation(
      (type, fn, opts) => {
        live.delete(`${name}:${type}:${idOf(fn)}`);
        return remove(type, fn, opts);
      }
    );
  });
  return live;
};

const mountCal = (listeners = {}, otherEvents = []) => {
  events = [{ start: at(10), end: at(11), title: 'A' }, ...otherEvents];
  wrapper = mount(
    {
      render: () =>
        h(VueCal, {
          view: 'day',
          views: ['day'],
          viewDate: at(0),
          time: true,
          timeFrom: 8 * 60,
          timeTo: 20 * 60,
          snapToInterval: 5,
          editableEvents: {
            create: true,
            delete: false,
            drag: true,
            resize: true,
          },
          events,
          ...listeners,
        }),
    },
    { attachTo: document.body }
  );
  return wrapper;
};

const resizerOf = () => wrapper.element.querySelector('.vuecal__event-resizer');
const cellOf = () => wrapper.element.querySelector('.vuecal__cell');
const isResizingClass = () =>
  wrapper.element.className.includes('vuecal--resizing-event');

describe('vendored vue-cal hold to resize', () => {
  beforeEach(() => {
    vi.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(
      () => ({
        top: 0,
        left: 0,
        width: 200,
        height: 1000,
        right: 200,
        bottom: 1000,
        x: 0,
        y: 0,
      })
    );
    liveListeners = trackListeners();

    // Capture unhandled promise rejections here instead of failing the whole run.
    rejections = [];
    savedRejectionListeners = process.listeners('unhandledRejection');
    process.removeAllListeners('unhandledRejection');
    process.on('unhandledRejection', reason => rejections.push(reason));
  });

  afterEach(async () => {
    wrapper?.unmount();
    wrapper = null;
    document.body.innerHTML = '';
    await settle();
    process.removeAllListeners('unhandledRejection');
    savedRejectionListeners.forEach(listener =>
      process.on('unhandledRejection', listener)
    );
    vi.restoreAllMocks();
  });

  // Mount, then remember what is attached so a gesture can be checked to leave nothing behind.
  const mountAndBaseline = async (listeners, otherEvents) => {
    mountCal(listeners, otherEvents);
    await flush();
    return new Set(liveListeners);
  };

  describe.each([
    ['refuses', () => false],
    ['accepts', () => true],
  ])('a plain click on the resizer while the app %s it', (_, answer) => {
    it('changes nothing and leaves no listener behind', async () => {
      const onEventResizeStart = vi.fn();
      const onEventResizeEnd = vi.fn(answer);
      const baseline = await mountAndBaseline({
        onEventResizeStart,
        onEventResizeEnd,
      });

      press(resizerOf(), ON_BORDER);
      release(resizerOf(), ON_BORDER);
      await flush();
      await settle();

      expect(onEventResizeStart).not.toHaveBeenCalled();
      expect(onEventResizeEnd).not.toHaveBeenCalled();
      expect(range(events[0])).toBe(ORIGINAL);
      expect(isResizingClass()).toBe(false);
      expect(liveListeners).toEqual(baseline);
      expect(rejections).toEqual([]);

      // Moving the mouse afterwards, even claiming a pressed button, does nothing.
      move(500);
      move(100, 0);
      await flush();
      expect(range(events[0])).toBe(ORIGINAL);
    });
  });

  it('ignores a jitter of up to 4px and starts resizing past it', async () => {
    const onEventResizeStart = vi.fn();
    const onEventResizeEnd = vi.fn(() => true);
    await mountAndBaseline({ onEventResizeStart, onEventResizeEnd });

    press(resizerOf(), ON_BORDER);
    move(ON_BORDER + 4);
    release(resizerOf(), ON_BORDER + 4);
    await flush();

    expect(onEventResizeStart).not.toHaveBeenCalled();
    expect(onEventResizeEnd).not.toHaveBeenCalled();
    expect(range(events[0])).toBe(ORIGINAL);

    press(resizerOf(), ON_BORDER);
    move(ON_BORDER + 5);
    await flush();
    expect(onEventResizeStart).toHaveBeenCalledTimes(1);
    expect(isResizingClass()).toBe(true);
    release(resizerOf(), ON_BORDER + 5);
    await flush();
    expect(onEventResizeEnd).toHaveBeenCalledTimes(1);
  });

  it('resizes while the button is held and commits once on release', async () => {
    const onEventResizeStart = vi.fn();
    const onEventResizeEnd = vi.fn(() => true);
    const baseline = await mountAndBaseline({
      onEventResizeStart,
      onEventResizeEnd,
    });

    press(resizerOf(), ON_BORDER);
    move(DRAGGED_TO);
    await flush();

    expect(onEventResizeStart).toHaveBeenCalledTimes(1);
    expect(range(events[0])).toBe(DRAGGED_RANGE);
    expect(onEventResizeEnd).not.toHaveBeenCalled();

    release(resizerOf(), DRAGGED_TO);
    await flush();

    expect(onEventResizeEnd).toHaveBeenCalledTimes(1);
    const { event, original } = onEventResizeEnd.mock.calls[0][0];
    expect(range(event)).toBe(DRAGGED_RANGE);
    expect(range(original)).toBe(ORIGINAL);
    expect(range(events[0])).toBe(DRAGGED_RANGE);
    expect(isResizingClass()).toBe(false);
    expect(liveListeners).toEqual(baseline);

    // The gesture is over: further movement leaves the event alone.
    move(500);
    await flush();
    expect(range(events[0])).toBe(DRAGGED_RANGE);
  });

  it('reverts to the original range when the app refuses a held resize', async () => {
    const onEventResizeEnd = vi.fn(() => false);
    const baseline = await mountAndBaseline({ onEventResizeEnd });

    press(resizerOf(), ON_BORDER);
    move(DRAGGED_TO);
    release(resizerOf(), DRAGGED_TO);
    await flush();
    await settle();

    expect(onEventResizeEnd).toHaveBeenCalledTimes(1);
    expect(range(events[0])).toBe(ORIGINAL);
    expect(isResizingClass()).toBe(false);
    expect(liveListeners).toEqual(baseline);
    expect(rejections).toEqual([]);
  });

  it('cleans up and reverts when the app handler throws', async () => {
    const failure = new Error('handler failed');
    const onEventResizeEnd = vi.fn(() => {
      throw failure;
    });
    const baseline = await mountAndBaseline({ onEventResizeEnd });

    press(resizerOf(), ON_BORDER);
    move(DRAGGED_TO);
    release(resizerOf(), DRAGGED_TO);
    await flush();
    await settle();

    expect(onEventResizeEnd).toHaveBeenCalledTimes(1);
    expect(range(events[0])).toBe(ORIGINAL);
    expect(isResizingClass()).toBe(false);
    expect(liveListeners).toEqual(baseline);
    expect(rejections).toEqual([failure]);

    move(500);
    await flush();
    expect(range(events[0])).toBe(ORIGINAL);
  });

  it('cancels and reverts when the mouse moves without the button pressed', async () => {
    const onEventResizeEnd = vi.fn(() => true);
    const baseline = await mountAndBaseline({ onEventResizeEnd });

    press(resizerOf(), ON_BORDER);
    move(DRAGGED_TO);
    await flush();
    expect(range(events[0])).toBe(DRAGGED_RANGE);

    // The mouseup was lost (released outside the window, over a context menu...).
    move(400, 0);
    await flush();

    expect(range(events[0])).toBe(ORIGINAL);
    expect(onEventResizeEnd).not.toHaveBeenCalled();
    expect(isResizingClass()).toBe(false);
    expect(liveListeners).toEqual(baseline);

    move(600);
    await flush();
    expect(range(events[0])).toBe(ORIGINAL);
  });

  it('shortens the card when the border is dragged up, once past the threshold', async () => {
    const onEventResizeStart = vi.fn();
    const onEventResizeEnd = vi.fn(() => true);
    await mountAndBaseline({ onEventResizeStart, onEventResizeEnd });
    const endMinutes = ({ end }) => end.getHours() * 60 + end.getMinutes();

    press(resizerOf(), ON_BORDER);
    move(ON_BORDER - 4); // 4px up is still a click.
    await flush();
    expect(onEventResizeStart).not.toHaveBeenCalled();
    expect(range(events[0])).toBe(ORIGINAL);

    move(ON_BORDER - 5);
    await flush();
    expect(onEventResizeStart).toHaveBeenCalledTimes(1);

    move(209); // About 10:30.
    await flush();
    expect(endMinutes(events[0])).toBeLessThan(11 * 60);
    expect(endMinutes(events[0])).toBeGreaterThan(10 * 60);

    release(resizerOf(), 209);
    await flush();
    expect(onEventResizeEnd).toHaveBeenCalledTimes(1);
    expect(endMinutes(events[0])).toBeLessThan(11 * 60);
  });

  describe('a second press while a resize is armed or running', () => {
    const SECOND = 'B';
    const secondResizer = () =>
      [...wrapper.element.querySelectorAll('.vuecal__event')]
        .find(el => el.textContent.includes(SECOND))
        .querySelector('.vuecal__event-resizer');
    const SECOND_ON_BORDER = 583; // The bottom border of the 14:00-15:00 event.
    const secondEvent = { start: at(14), end: at(15), title: SECOND };

    // A touchstart of a further finger: `touches` lists every finger down, the first one first.
    const addFinger = (target, clientY, firstTarget, firstY) => {
      const event = new Event('touchstart', {
        bubbles: true,
        cancelable: true,
      });
      Object.defineProperty(event, 'touches', {
        value: [
          { clientX: 50, clientY: firstY, target: firstTarget },
          { clientX: 50, clientY, target },
        ],
      });
      target.dispatchEvent(event);
    };

    it('ignores a second finger on another card and lets the first resize carry on', async () => {
      const onEventResizeEnd = vi.fn(() => true);
      await mountAndBaseline({ onEventResizeEnd }, [secondEvent]);

      touch('touchstart', resizerOf(), ON_BORDER);
      touch('touchmove', document, DRAGGED_TO);
      await flush();
      expect(range(events[0])).toBe(DRAGGED_RANGE);

      addFinger(secondResizer(), SECOND_ON_BORDER, resizerOf(), DRAGGED_TO);
      touch('touchmove', document, 350);
      await flush();
      touch('touchend', document, 350);
      await flush();

      // The first card was resized and saved, the second one was never armed.
      expect(onEventResizeEnd).toHaveBeenCalledTimes(1);
      expect(onEventResizeEnd.mock.calls[0][0].event.title).toBe('A');
      expect(range(events[1])).toBe('14:00-15:00');
      expect(isResizingClass()).toBe(false);
    });

    it('reverts the card when a second finger lands on it and the app refuses the resize', async () => {
      const onEventResizeEnd = vi.fn(() => false);
      await mountAndBaseline({ onEventResizeEnd });

      touch('touchstart', resizerOf(), ON_BORDER);
      touch('touchmove', document, DRAGGED_TO);
      await flush();
      expect(range(events[0])).toBe(DRAGGED_RANGE);

      addFinger(resizerOf(), ON_BORDER, resizerOf(), DRAGGED_TO);
      touch('touchend', document, DRAGGED_TO);
      await flush();
      await settle();

      expect(onEventResizeEnd).toHaveBeenCalledTimes(1);
      expect(range(events[0])).toBe(ORIGINAL);
    });

    it('starts over on a new single touch when the end of the previous touch was lost', async () => {
      const onEventResizeEnd = vi.fn(() => true);
      const baseline = await mountAndBaseline({ onEventResizeEnd });

      touch('touchstart', resizerOf(), ON_BORDER);
      touch('touchmove', document, DRAGGED_TO);
      await flush();
      expect(range(events[0])).toBe(DRAGGED_RANGE);

      // No touchend nor touchcancel ever came (the card was re-rendered under the finger...).
      touch('touchstart', resizerOf(), ON_BORDER);
      expect(range(events[0])).toBe(ORIGINAL);

      touch('touchmove', document, DRAGGED_TO);
      await flush();
      touch('touchend', document, DRAGGED_TO);
      await flush();

      expect(onEventResizeEnd).toHaveBeenCalledTimes(1);
      expect(range(events[0])).toBe(DRAGGED_RANGE);
      expect(liveListeners).toEqual(baseline);
    });

    it('reverts the first card and starts over when the mouse is pressed on another one', async () => {
      const onEventResizeStart = vi.fn();
      const onEventResizeEnd = vi.fn(() => true);
      const baseline = await mountAndBaseline(
        { onEventResizeStart, onEventResizeEnd },
        [secondEvent]
      );

      press(resizerOf(), ON_BORDER);
      move(DRAGGED_TO);
      await flush();
      expect(range(events[0])).toBe(DRAGGED_RANGE);

      // The release of the first press never reached the page.
      press(secondResizer(), SECOND_ON_BORDER);
      expect(range(events[0])).toBe(ORIGINAL);

      move(SECOND_ON_BORDER + 40);
      await flush();
      release(secondResizer(), SECOND_ON_BORDER + 40);
      await flush();

      expect(onEventResizeStart).toHaveBeenCalledTimes(2);
      expect(onEventResizeEnd).toHaveBeenCalledTimes(1);
      expect(onEventResizeEnd.mock.calls[0][0].event.title).toBe(SECOND);
      expect(range(events[0])).toBe(ORIGINAL);
      expect(events[1].end.getHours()).toBe(15);
      expect(events[1].end.getMinutes()).toBeGreaterThan(0);
      expect(liveListeners).toEqual(baseline);
    });
  });

  it.each([
    ['right', 2],
    ['middle', 1],
  ])('does not start a resize from the %s button', async (_, button) => {
    const onEventResizeStart = vi.fn();
    const onEventResizeEnd = vi.fn(() => true);
    const baseline = await mountAndBaseline({
      onEventResizeStart,
      onEventResizeEnd,
    });

    mouse(resizerOf(), 'mousedown', ON_BORDER, { button, buttons: button });
    expect(liveListeners).toEqual(baseline);
    expect(isResizingClass()).toBe(false);

    move(DRAGGED_TO, button);
    mouse(resizerOf(), 'mouseup', DRAGGED_TO, { button, buttons: 0 });
    await flush();

    expect(onEventResizeStart).not.toHaveBeenCalled();
    expect(onEventResizeEnd).not.toHaveBeenCalled();
    expect(range(events[0])).toBe(ORIGINAL);
  });

  describe('with touch', () => {
    it('ignores a tap on the resizer', async () => {
      const onEventResizeStart = vi.fn();
      const onEventResizeEnd = vi.fn(() => false);
      const baseline = await mountAndBaseline({
        onEventResizeStart,
        onEventResizeEnd,
      });

      touch('touchstart', resizerOf(), ON_BORDER);
      touch('touchend', resizerOf(), ON_BORDER);
      await flush();
      await settle();

      expect(onEventResizeStart).not.toHaveBeenCalled();
      expect(onEventResizeEnd).not.toHaveBeenCalled();
      expect(range(events[0])).toBe(ORIGINAL);
      expect(liveListeners).toEqual(baseline);
      expect(rejections).toEqual([]);

      // A later swipe elsewhere does not resize the event.
      touch('touchmove', document, 650);
      await flush();
      expect(range(events[0])).toBe(ORIGINAL);
    });

    it('resizes on a held drag and commits on touchend', async () => {
      const onEventResizeEnd = vi.fn(() => true);
      const baseline = await mountAndBaseline({ onEventResizeEnd });

      touch('touchstart', resizerOf(), ON_BORDER);
      touch('touchmove', document, ON_BORDER + 2);
      await flush();
      expect(range(events[0])).toBe(ORIGINAL);

      touch('touchmove', document, DRAGGED_TO);
      await flush();
      expect(range(events[0])).toBe(DRAGGED_RANGE);

      touch('touchend', resizerOf(), DRAGGED_TO);
      await flush();

      expect(onEventResizeEnd).toHaveBeenCalledTimes(1);
      expect(range(events[0])).toBe(DRAGGED_RANGE);
      expect(liveListeners).toEqual(baseline);
    });

    it('cancels and reverts on touchcancel', async () => {
      const onEventResizeEnd = vi.fn(() => true);
      const baseline = await mountAndBaseline({ onEventResizeEnd });

      touch('touchstart', resizerOf(), ON_BORDER);
      touch('touchmove', document, DRAGGED_TO);
      await flush();
      expect(range(events[0])).toBe(DRAGGED_RANGE);

      touch('touchcancel', document, DRAGGED_TO);
      await flush();

      expect(range(events[0])).toBe(ORIGINAL);
      expect(onEventResizeEnd).not.toHaveBeenCalled();
      expect(liveListeners).toEqual(baseline);

      touch('touchmove', document, 650);
      await flush();
      expect(range(events[0])).toBe(ORIGINAL);
    });
  });

  it('does not swallow the next click on the card after a click on the resizer', async () => {
    const onEventClick = vi.fn();
    await mountAndBaseline({ onEventClick });

    press(resizerOf(), ON_BORDER);
    release(resizerOf(), ON_BORDER);
    mouse(resizerOf(), 'click', ON_BORDER);
    await flush();
    expect(onEventClick).not.toHaveBeenCalled();

    const card = wrapper.element.querySelector('.vuecal__event');
    press(card, 200);
    release(card, 200);
    mouse(card, 'click', 200);
    await flush();
    expect(onEventClick).toHaveBeenCalledTimes(1);
  });

  describe('the click that ends a press on the resizer', () => {
    // The release lands on the cell around the card, so the browser sends the click to the cell.
    const click = y => mouse(cellOf(), 'click', y, { button: 0, buttons: 0 });

    it('control: a click on an empty cell reaches the cell', async () => {
      const onCellClick = vi.fn();
      await mountAndBaseline({ onCellClick });

      press(cellOf(), 400);
      release(cellOf(), 400);
      click(400);
      await flush();

      expect(onCellClick).toHaveBeenCalledTimes(1);
    });

    it.each([
      ['drifts off the border by a few pixels', ON_BORDER + 3],
      ['is a bare click on the border', ON_BORDER],
      ['was a held resize', DRAGGED_TO],
    ])('never reaches the cell when the press %s', async (_, to) => {
      const onCellClick = vi.fn();
      await mountAndBaseline({ onCellClick, onEventResizeEnd: () => true });

      press(resizerOf(), ON_BORDER);
      move(to);
      release(cellOf(), to);
      click(to);
      await flush();

      expect(onCellClick).not.toHaveBeenCalled();
    });

    it('never reaches the cell after a tap, whose touchend is followed by mouse events', async () => {
      const onCellClick = vi.fn();
      await mountAndBaseline({ onCellClick });

      touch('touchstart', resizerOf(), ON_BORDER);
      touch('touchend', resizerOf(), ON_BORDER);
      press(resizerOf(), ON_BORDER);
      release(cellOf(), ON_BORDER + 3);
      click(ON_BORDER + 3);
      await flush();

      expect(onCellClick).not.toHaveBeenCalled();
    });

    it('is the only click swallowed', async () => {
      const onCellClick = vi.fn();
      await mountAndBaseline({ onCellClick });

      press(resizerOf(), ON_BORDER);
      release(cellOf(), ON_BORDER + 3);
      await flush();
      await settle(); // No click came after the release.

      click(400);
      await flush();
      expect(onCellClick).toHaveBeenCalledTimes(1);
    });

    it('is not waited for when the release never reached the page', async () => {
      const onCellClick = vi.fn();
      await mountAndBaseline({ onCellClick });

      press(resizerOf(), ON_BORDER);
      move(DRAGGED_TO);
      move(400, 0); // The mouseup was lost: the resize is cancelled.
      await flush();

      press(cellOf(), 400);
      release(cellOf(), 400);
      click(400);
      await flush();
      expect(onCellClick).toHaveBeenCalledTimes(1);
    });
  });

  it('does not let a press on the resizer start dragging the card to move it', async () => {
    await mountAndBaseline();

    press(resizerOf(), ON_BORDER);
    const dragstart = new Event('dragstart', {
      bubbles: true,
      cancelable: true,
    });
    wrapper.element.querySelector('.vuecal__event').dispatchEvent(dragstart);

    expect(dragstart.defaultPrevented).toBe(true);
    release(resizerOf(), ON_BORDER);
  });

  describe('dragging on an empty cell to create an event', () => {
    const placeholder = () =>
      wrapper.element.querySelector('.vuecal__event-placeholder');
    const creator = () =>
      vi.fn(({ resolve }) => {
        resolve(false);
      });

    it('creates the event on a held drag, released', async () => {
      const onEventCreate = creator();
      const baseline = await mountAndBaseline({ onEventCreate });

      press(cellOf(), 400);
      move(460);
      await flush();
      expect(placeholder()).not.toBeNull();

      release(cellOf(), 460);
      await flush();

      expect(onEventCreate).toHaveBeenCalledTimes(1);
      expect(placeholder()).toBeNull();
      expect(liveListeners).toEqual(baseline);
    });

    it('does not start from the right button', async () => {
      const onEventCreate = creator();
      const baseline = await mountAndBaseline({ onEventCreate });

      mouse(cellOf(), 'mousedown', 400, { button: 2, buttons: 2 });
      expect(liveListeners).toEqual(baseline);
      move(460, 2);
      await flush();
      expect(placeholder()).toBeNull();

      mouse(cellOf(), 'mouseup', 460, { button: 2, buttons: 0 });
      await flush();
      expect(onEventCreate).not.toHaveBeenCalled();
    });

    it('cancels without creating when the mouse moves without the button pressed', async () => {
      const onEventCreate = creator();
      const baseline = await mountAndBaseline({ onEventCreate });

      press(cellOf(), 400);
      move(460);
      await flush();
      expect(placeholder()).not.toBeNull();

      move(520, 0);
      await flush();
      expect(placeholder()).toBeNull();
      expect(liveListeners).toEqual(baseline);

      release(document.body, 520);
      await flush();
      expect(onEventCreate).not.toHaveBeenCalled();
    });

    it('cancels without creating on touchcancel', async () => {
      const onEventCreate = creator();
      vi.useFakeTimers();
      try {
        const baseline = await mountAndBaseline({ onEventCreate });

        touch('touchstart', cellOf(), 400);
        vi.advanceTimersByTime(600); // The 500ms hold before a touch can create.
        touch('touchmove', document, 460);
        await flush();
        expect(placeholder()).not.toBeNull();

        touch('touchcancel', document, 460);
        await flush();
        expect(placeholder()).toBeNull();
        expect(liveListeners).toEqual(baseline);

        touch('touchend', document, 460);
        await flush();
        expect(onEventCreate).not.toHaveBeenCalled();
      } finally {
        vi.useRealTimers();
      }
    });
  });
});
