import { beforeEach, describe, expect, it, vi } from 'vitest';

import NotificationsView from './NotificationsView.vue';

vi.mock('dashboard/composables', () => ({ useTrack: vi.fn() }));

const notification = extra => ({
  id: 5,
  notification_type: 'conversation_mention',
  primary_actor_id: 420,
  primary_actor_type: 'Conversation',
  primary_actor: { id: 42, inbox_id: 7 },
  ...extra,
});

const buildContext = () => ({
  accountId: 1,
  meta: { unreadCount: 2 },
  $store: { dispatch: vi.fn() },
  $router: { push: vi.fn() },
});

describe('NotificationsView', () => {
  let context;

  beforeEach(() => {
    context = buildContext();
  });

  it('opens a conversation inside a communication thread in the thread view', () => {
    NotificationsView.methods.openConversation.call(
      context,
      notification({ communication_thread_id: 9 })
    );

    expect(context.$store.dispatch).toHaveBeenCalledWith(
      'notifications/read',
      expect.objectContaining({ id: 5, primaryActorId: 420 })
    );
    expect(context.$router.push).toHaveBeenCalledWith(
      expect.stringMatching(
        /^\/app\/accounts\/1\/communication_threads\/9(\?|$)/
      )
    );
  });

  it('keeps regular conversations on the inbox conversation URL', () => {
    NotificationsView.methods.openConversation.call(context, notification());

    expect(context.$router.push).toHaveBeenCalledWith(
      expect.stringMatching(/^\/app\/accounts\/1\/inbox\/7\/conversations\/42/)
    );
  });
});
