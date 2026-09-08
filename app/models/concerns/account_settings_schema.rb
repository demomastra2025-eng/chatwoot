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
        'call_transcriptions': { 'type': %w[boolean null] },
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
        'conversation_status_reason_config': {
          'type': %w[object null],
          'properties': {
            'open': {
              'type': %w[object null],
              'properties': {
                'options': { 'type': %w[array null], 'items': { 'type': 'string' } },
                'required': { 'type': %w[boolean null] }
              },
              'additionalProperties': false
            },
            'resolved': {
              'type': %w[object null],
              'properties': {
                'options': { 'type': %w[array null], 'items': { 'type': 'string' } },
                'required': { 'type': %w[boolean null] }
              },
              'additionalProperties': false
            },
            'pending': {
              'type': %w[object null],
              'properties': {
                'options': { 'type': %w[array null], 'items': { 'type': 'string' } },
                'required': { 'type': %w[boolean null] }
              },
              'additionalProperties': false
            },
            'snoozed': {
              'type': %w[object null],
              'properties': {
                'options': { 'type': %w[array null], 'items': { 'type': 'string' } },
                'required': { 'type': %w[boolean null] }
              },
              'additionalProperties': false
            }
          },
          'additionalProperties': false
        },
        'captain_models': {
          'type': %w[object null],
          'properties': {
            'editor': { 'type': %w[string null] },
            'assistant': { 'type': %w[string null] },
            'copilot': { 'type': %w[string null] },
            'label_suggestion': { 'type': %w[string null] },
            'audio_transcription': { 'type': %w[string null] },
            'image_recognition': { 'type': %w[string null] },
            'help_center_search': { 'type': %w[string null] },
            'moderation': { 'type': %w[string null] }
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
            'privacy_profile': {
              'type': %w[string null],
              'enum': Llm::OpenRouterWorkspacePolicy::PRIVACY_PROFILES.keys + [nil]
            },
            'assistant_thinking_effort': { 'type': %w[string null], 'enum': ['none', 'low', 'medium', 'high', nil] },
            'copilot_thinking_effort': { 'type': %w[string null], 'enum': ['none', 'low', 'medium', 'high', nil] },
            'assistant_moderation': { 'type': %w[boolean null] },
            'copilot_moderation': { 'type': %w[boolean null] },
            'moderation_failure_mode': { 'type': %w[string null], 'enum': ['fail_open', 'fail_closed', nil] },
            'prompt_injection_guardrail': {
              'type': %w[string boolean null],
              'enum': Llm::RuntimePolicy::GUARDRAIL_ACTIONS + [true, false, nil]
            },
            'sensitive_info_guardrail': {
              'type': %w[string boolean null],
              'enum': Llm::RuntimePolicy::GUARDRAIL_ACTIONS + [true, false, nil]
            },
            'assistant_prompt_injection_guardrail': {
              'type': %w[string boolean null],
              'enum': Llm::RuntimePolicy::GUARDRAIL_ACTIONS + [true, false, nil]
            },
            'assistant_sensitive_info_guardrail': {
              'type': %w[string boolean null],
              'enum': Llm::RuntimePolicy::GUARDRAIL_ACTIONS + [true, false, nil]
            },
            'copilot_prompt_injection_guardrail': {
              'type': %w[string boolean null],
              'enum': Llm::RuntimePolicy::GUARDRAIL_ACTIONS + [true, false, nil]
            },
            'copilot_sensitive_info_guardrail': {
              'type': %w[string boolean null],
              'enum': Llm::RuntimePolicy::GUARDRAIL_ACTIONS + [true, false, nil]
            },
            'audio_transcription_prompt': { 'type': %w[string null] },
            'knowledge_chunk_size': {
              'type': %w[integer null],
              'minimum': Captain::KnowledgeSettings::MIN_CHUNK_SIZE,
              'maximum': Captain::KnowledgeSettings::MAX_CHUNK_SIZE
            },
            'trace_input_capture': { 'type': %w[boolean null] },
            'trace_output_capture': { 'type': %w[boolean null] },
            'openrouter_routing_strategy': {
              'type': %w[string null],
              'enum': Llm::OpenRouterRoutingProfile::ROUTING_STRATEGIES + [nil]
            },
            'routing_strategy': {
              'type': %w[string null],
              'enum': Llm::OpenRouterRoutingProfile::ROUTING_STRATEGIES + [nil]
            },
            'openrouter_provider_order': {
              'type': %w[array null],
              'items': { 'type': 'string' }
            },
            'provider_order': {
              'type': %w[array null],
              'items': { 'type': 'string' }
            },
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
            'web_search_enabled': { 'type': %w[boolean null] },
            'web_scrape_enabled': { 'type': %w[boolean null] },
            'web_document_parse_enabled': { 'type': %w[boolean null] },
            'web_search_max_results': {
              'type': %w[integer null],
              'minimum': 1,
              'maximum': Llm::RuntimePolicy::WEB_SEARCH_MAX_LIMIT
            },
            'web_scrape_max_chars': {
              'type': %w[integer null],
              'minimum': 1_000,
              'maximum': Llm::RuntimePolicy::WEB_SCRAPE_MAX_CHARS
            },
            'web_document_parse_max_chars': {
              'type': %w[integer null],
              'minimum': 1_000,
              'maximum': Llm::RuntimePolicy::WEB_DOCUMENT_PARSE_MAX_CHARS
            },
            'web_allowed_domains': {
              'type': %w[array null],
              'items': { 'type': 'string' }
            },
            'web_blocked_domains': {
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
        },
        'mcp_access': {
          'type': %w[object null],
          'properties': {
            'enabled': { 'type': %w[boolean null] },
            'max_risk_level': { 'type': %w[string null], 'enum': ['low', 'medium', 'high', 'custom', nil] },
            'require_confirmation_for_mutations': { 'type': %w[boolean null] },
            'sources': {
              'type': %w[object null],
              'properties': {
                'captain': { 'type': %w[boolean null] },
                'openapi_read': { 'type': %w[boolean null] },
                'openapi_write': { 'type': %w[boolean null] }
              },
              'additionalProperties': false
            },
            'allowed_groups': { 'type': %w[array null], 'items': { 'type': 'string' } },
            'blocked_groups': { 'type': %w[array null], 'items': { 'type': 'string' } },
            'allowed_tool_ids': { 'type': %w[array null], 'items': { 'type': 'string' } },
            'blocked_tool_ids': { 'type': %w[array null], 'items': { 'type': 'string' } },
            'allowed_openapi_operation_ids': { 'type': %w[array null], 'items': { 'type': 'string' } },
            'blocked_openapi_operation_ids': { 'type': %w[array null], 'items': { 'type': 'string' } }
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
