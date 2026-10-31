import { dispatchWindowEvent } from '../CustomEventHelper';

describe('dispatchWindowEvent', () => {
  afterEach(() => vi.restoreAllMocks());

  it.each(['chatwoot:ready', 'onelink:ready'])(
    'emits each public and legacy ready event once from %s',
    eventName => {
      const dispatch = vi
        .spyOn(window, 'dispatchEvent')
        .mockImplementation(() => true);
      const addListener = vi.spyOn(window, 'addEventListener');
      dispatchWindowEvent({ eventName });

      expect(dispatch.mock.calls.map(([event]) => event.type)).toEqual([
        'onelink:ready',
        'chatwoot:ready',
      ]);
      expect(addListener).not.toHaveBeenCalled();
    }
  );

  it('preserves error details and dispatches both names without forwarding listeners', () => {
    const dispatch = vi
      .spyOn(window, 'dispatchEvent')
      .mockImplementation(() => true);
    const detail = { code: 'test-error' };
    dispatchWindowEvent({ eventName: 'chatwoot:error', data: detail });
    expect(dispatch.mock.calls.map(([event]) => event.type)).toEqual([
      'onelink:error',
      'chatwoot:error',
    ]);
    expect(
      dispatch.mock.calls.every(([event]) => event.detail === detail)
    ).toBe(true);
  });

  it('keeps unrelated events single and unchanged', () => {
    const dispatch = vi
      .spyOn(window, 'dispatchEvent')
      .mockImplementation(() => true);
    dispatchWindowEvent({ eventName: 'custom:ready' });
    expect(dispatch).toHaveBeenCalledTimes(1);
    expect(dispatch.mock.calls[0][0].type).toBe('custom:ready');
  });
});
