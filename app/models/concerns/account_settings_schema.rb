module AccountSettingsSchema
  extend ActiveSupport::Concern

  SETTINGS_PARAMS_SCHEMA = {
    'type': 'object',
    'properties':
      {
        'auto_resolve_after': { 'type': %w[integer null], 'minimum': 10, 'maximum': 1_439_856 },
        'auto_resolve_message': { 'type': %w[string null] },
        'auto_resolve_ignore_waiting': { 'type': %w[boolean null] },
        'audio_transcriptions': { 'type': %w[boolean null] },
        'auto_resolve_label': { 'type': %w[string null] },
        'keep_pending_on_bot_failure': { 'type': %w[boolean null] },
        'captain_auto_resolve_mode': { 'type': %w[string null], 'enum': ['evaluated', 'legacy', 'disabled', nil] },
        'scheduling_contact_required': { 'type': %w[boolean null] },
        'scheduling_company_enabled': { 'type': %w[boolean null] },
        'default_appointment_touch_plan_id': { 'type': %w[integer string null] },
        'default_deal_touch_plan_id': { 'type': %w[integer string null] },
        'default_task_touch_plan_id': { 'type': %w[integer string null] },
        'conversation_required_attributes': {
          'type': %w[array null],
          'items': { 'type': 'string' }
        },
        'captain_models': {
          'type': %w[object null],
          'properties': {
            'editor': { 'type': %w[string null] },
            'assistant': { 'type': %w[string null] },
            'copilot': { 'type': %w[string null] },
            'label_suggestion': { 'type': %w[string null] },
            'audio_transcription': { 'type': %w[string null] },
            'help_center_search': { 'type': %w[string null] }
          },
          'additionalProperties': false
        },
        'captain_features': {
          'type': %w[object null],
          'properties': {
            'editor': { 'type': %w[boolean null] },
            'assistant': { 'type': %w[boolean null] },
            'copilot': { 'type': %w[boolean null] },
            'label_suggestion': { 'type': %w[boolean null] },
            'audio_transcription': { 'type': %w[boolean null] },
            'help_center_search': { 'type': %w[boolean null] }
          },
          'additionalProperties': false
        },
        'captain_runtime': {
          'type': %w[object null],
          'properties': {
            'assistant_thinking_effort': { 'type': %w[string null], 'enum': ['none', 'low', 'medium', 'high', nil] },
            'copilot_thinking_effort': { 'type': %w[string null], 'enum': ['none', 'low', 'medium', 'high', nil] },
            'assistant_moderation': { 'type': %w[boolean null] },
            'copilot_moderation': { 'type': %w[boolean null] },
            'moderation_failure_mode': { 'type': %w[string null], 'enum': ['fail_open', 'fail_closed', nil] },
            'trace_input_capture': { 'type': %w[boolean null] },
            'trace_output_capture': { 'type': %w[boolean null] },
            'safety_blocklist': {
              'type': %w[array null],
              'items': { 'type': 'string' }
            },
            'assistant_safety_blocklist': {
              'type': %w[array null],
              'items': { 'type': 'string' }
            },
            'copilot_safety_blocklist': {
              'type': %w[array null],
              'items': { 'type': 'string' }
            },
            'agent_high_risk_tools': {
              'type': %w[string boolean null],
              'enum': ['disabled', 'enabled', true, false, nil]
            },
            'agent_high_risk_tool_ids': {
              'type': %w[array null],
              'items': { 'type': 'string' }
            },
            'agent_permissioned_tool_ids': {
              'type': %w[array null],
              'items': { 'type': 'string' }
            },
            'release_gate': {
              'type': %w[object null],
              'properties': {
                'enabled': { 'type': %w[boolean null] },
                'min_request_count': { 'type': %w[integer null], 'minimum': 1, 'maximum': 100_000 },
                'max_error_rate': { 'type': %w[number null], 'minimum': 0, 'maximum': 1 },
                'max_schema_invalid_rate': { 'type': %w[number null], 'minimum': 0, 'maximum': 1 },
                'max_tool_failure_rate': { 'type': %w[number null], 'minimum': 0, 'maximum': 1 },
                'max_moderation_skipped_rate': { 'type': %w[number null], 'minimum': 0, 'maximum': 1 },
                'max_avg_duration_ms': { 'type': %w[integer null], 'minimum': 1, 'maximum': 600_000 },
                'max_p95_duration_ms': { 'type': %w[integer null], 'minimum': 1, 'maximum': 600_000 },
                'max_cost_per_request': { 'type': %w[number null], 'minimum': 0, 'maximum': 1_000 },
                'max_error_rate_regression': { 'type': %w[number null], 'minimum': 1, 'maximum': 100 },
                'max_avg_duration_regression': { 'type': %w[number null], 'minimum': 1, 'maximum': 100 }
              },
              'additionalProperties': false
            }
          },
          'additionalProperties': false
        },
        'captain_observability': {
          'type': %w[object null],
          'properties': {
            'default_lookback_days': { 'type': %w[integer null], 'minimum': 1, 'maximum': 365 },
            'retention_days': { 'type': %w[integer null], 'minimum': 7, 'maximum': 3650 },
            'saved_views': {
              'type': %w[array null],
              'items': {
                'type': 'object',
                'properties': {
                  'id': { 'type': 'string' },
                  'name': { 'type': 'string', 'minLength': 1, 'maxLength': 80 },
                  'tab': { 'type': 'string', 'enum': %w[overview events traces evaluations] },
                  'filters': { 'type': %w[object null] }
                },
                'required': %w[id name tab],
                'additionalProperties': false
              }
            },
            'alert_channels': {
              'type': %w[object null],
              'properties': {
                'enabled': { 'type': %w[boolean null] },
                'minimum_severity': { 'type': %w[string null], 'enum': ['warning', 'critical', nil] },
                'email_recipients': {
                  'type': %w[array null],
                  'items': { 'type': 'string' }
                },
                'webhook_url': { 'type': %w[string null] },
                'notify_on': {
                  'type': %w[array null],
                  'items': { 'type': 'string' }
                }
              },
              'additionalProperties': false
            }
          },
          'additionalProperties': false
        }
      },
    'required': [],
    'additionalProperties': true
  }.to_json.freeze

  included do
    const_set(:SETTINGS_PARAMS_SCHEMA, AccountSettingsSchema::SETTINGS_PARAMS_SCHEMA) unless const_defined?(:SETTINGS_PARAMS_SCHEMA, false)
  end
end
