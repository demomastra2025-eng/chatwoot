import { describe, it, expect } from 'vitest';
import { validateAutomation } from '../validations';

describe('validateAutomation', () => {
  it('should return no errors for a valid automation', () => {
    const validAutomation = {
      name: 'Test Automation',
      description: 'A test automation',
      event_name: 'message_created',
      conditions: [
        {
          attribute_key: 'content',
          filter_operator: 'contains',
          values: 'hello',
        },
      ],
      actions: [
        { action_name: 'send_message', action_params: ['Hello there!'] },
      ],
    };
    const errors = validateAutomation(validAutomation);
    expect(errors).toEqual({});
  });

  it('should return errors for missing basic fields', () => {
    const invalidAutomation = {
      name: '',
      description: '',
      event_name: '',
      conditions: [],
      actions: [],
    };
    const errors = validateAutomation(invalidAutomation);
    expect(errors).toHaveProperty('name');
    expect(errors).toHaveProperty('description');
    expect(errors).toHaveProperty('event_name');
  });

  it('should return errors for invalid conditions', () => {
    const automationWithInvalidConditions = {
      name: 'Test',
      description: 'Test',
      event_name: 'message_created',
      conditions: [{ attribute_key: '', filter_operator: '', values: '' }],
      actions: [{ action_name: 'send_message', action_params: ['Hello'] }],
    };
    const errors = validateAutomation(automationWithInvalidConditions);
    expect(errors).toHaveProperty('condition_0');
  });

  it('should return errors for invalid actions', () => {
    const automationWithInvalidActions = {
      name: 'Test',
      description: 'Test',
      event_name: 'message_created',
      conditions: [
        {
          attribute_key: 'content',
          filter_operator: 'contains',
          values: 'hello',
        },
      ],
      actions: [{ action_name: 'send_message', action_params: [] }],
    };
    const errors = validateAutomation(automationWithInvalidActions);
    expect(errors).toHaveProperty('action_0');
  });

  it('should not require action params for specific actions', () => {
    const automationWithNoParamAction = {
      name: 'Test',
      description: 'Test',
      event_name: 'message_created',
      conditions: [
        {
          attribute_key: 'content',
          filter_operator: 'contains',
          values: 'hello',
        },
      ],
      actions: [{ action_name: 'mute_conversation' }],
    };
    const errors = validateAutomation(automationWithNoParamAction);
    expect(errors).toEqual({});
  });

  it('should not require action params for native appointment cancel payment action', () => {
    const automationWithNoParamAction = {
      name: 'Test',
      description: 'Test',
      event_name: 'appointment_updated',
      conditions: [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: 'scheduled',
        },
      ],
      actions: [{ action_name: 'cancel_appointment_payment' }],
    };

    const errors = validateAutomation(automationWithNoParamAction);
    expect(errors).toEqual({});
  });

  it('should not require action params for native CRM archive actions', () => {
    const automationWithNoParamAction = {
      name: 'Archive deal',
      description: 'Archive on trigger',
      event_name: 'deal_updated',
      conditions: [
        {
          attribute_key: 'stage_id',
          filter_operator: 'equal_to',
          values: '1',
        },
      ],
      actions: [{ action_name: 'archive_deal' }],
    };

    const errors = validateAutomation(automationWithNoParamAction);
    expect(errors).toEqual({});
  });

  it('should validate create_touch body while allowing explicit auto cancel flag', () => {
    const automation = {
      name: 'Create touch',
      description: 'Create a delayed touch',
      event_name: 'message_created',
      conditions: [
        {
          attribute_key: 'content',
          filter_operator: 'contains',
          values: 'hello',
        },
      ],
      actions: [
        {
          action_name: 'create_touch',
          action_params: {
            body: 'Follow up later',
            delay_minutes: 15,
            auto_cancel_on_incoming: false,
          },
        },
      ],
    };

    const errors = validateAutomation(automation);
    expect(errors).toEqual({});
  });

  it('should validate create_touch with AI instructions and relative timing', () => {
    const automation = {
      name: 'Create AI touch',
      description: 'Create an AI delayed touch',
      event_name: 'message_created',
      conditions: [
        {
          attribute_key: 'content',
          filter_operator: 'contains',
          values: 'hello',
        },
      ],
      actions: [
        {
          action_name: 'create_touch',
          action_params: {
            instructions: 'Generate a useful follow-up',
            text_mode: 'agent',
            timing_mode: 'relative',
            relative_anchor: 'touch.created_at',
            relative_offset_seconds: 3600,
          },
        },
      ],
    };

    const errors = validateAutomation(automation);
    expect(errors).toEqual({});
  });

  it('should reject create_touch with recurring relative timing', () => {
    const automation = {
      name: 'Create invalid touch',
      description: 'Create an invalid delayed touch',
      event_name: 'message_created',
      conditions: [
        {
          attribute_key: 'content',
          filter_operator: 'contains',
          values: 'hello',
        },
      ],
      actions: [
        {
          action_name: 'create_touch',
          action_params: {
            body: 'Follow up later',
            timing_mode: 'relative',
            relative_anchor: 'touch.created_at',
            relative_offset_seconds: 3600,
            repeat_mode: 'daily',
          },
        },
      ],
    };

    const errors = validateAutomation(automation);
    expect(errors).toHaveProperty('action_0');
  });

  it('should reject create_touch without body', () => {
    const automation = {
      name: 'Create touch',
      description: 'Create a delayed touch',
      event_name: 'message_created',
      conditions: [
        {
          attribute_key: 'content',
          filter_operator: 'contains',
          values: 'hello',
        },
      ],
      actions: [
        {
          action_name: 'create_touch',
          action_params: { body: '   ', delay_minutes: 15 },
        },
      ],
    };

    const errors = validateAutomation(automation);
    expect(errors).toHaveProperty('action_0');
  });

  it('should not require action params for cancel_touches', () => {
    const automation = {
      name: 'Cancel touches',
      description: 'Cancel scheduled touches on incoming reply',
      event_name: 'message_created',
      conditions: [
        {
          attribute_key: 'content',
          filter_operator: 'contains',
          values: 'hello',
        },
      ],
      actions: [{ action_name: 'cancel_touches' }],
    };

    const errors = validateAutomation(automation);
    expect(errors).toEqual({});
  });
});
