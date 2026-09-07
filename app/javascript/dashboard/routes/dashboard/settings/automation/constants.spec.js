import { AUTOMATIONS, AUTOMATION_RULE_EVENTS } from './constants';

describe('CRM automation event registry', () => {
  it('exposes every granular deal and task event supported by the backend', () => {
    const eventKeys = AUTOMATION_RULE_EVENTS.map(event => event.key);

    const granularEvents = [
      'deal_waiting_set',
      'deal_waiting_cleared',
      'task_assigned',
      'task_rescheduled',
      'task_completed',
      'task_cancelled',
      'task_reopened',
      'task_waiting_changed',
    ];

    expect(eventKeys).toEqual(expect.arrayContaining(granularEvents));
    granularEvents.forEach(eventName => {
      expect(AUTOMATIONS[eventName].conditions).toBeDefined();
      expect(AUTOMATIONS[eventName].actions).toBeDefined();
    });
  });
});
