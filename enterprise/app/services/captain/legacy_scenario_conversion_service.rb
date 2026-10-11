# frozen_string_literal: true

module Captain
  # These records deliberately have no application callbacks: converting stored
  # configuration must never deliver messages, schedule work, or contact providers.
  class LegacyScenarioConversionService
    INHERITED_CONFIG_KEYS = %w[
      model temperature thinking_effort feature_faq feature_memory feature_citation feature_web
      feature_document_reading feature_image_understanding use_audio_transcriptions
      message_collapse_window_seconds history_message_limit auto_reply_on_last_incoming context_access rules safety_settings follow_up_settings
      handoff_enabled auto_completion_enabled handoff_message handoff_message_enabled handoff_message_mode
      resolution_message resolution_message_enabled resolution_message_mode outcome_reason_settings voice_settings
    ].freeze
    DEFAULT_AGENT_TOOL_IDS = %w[faq_lookup web_search web_scrape_url handoff].freeze
    TOOL_REFERENCE_REGEX = %r{\[[^\]]+\]\(tool://([^/)]+)\)}.freeze
    FIELD_REFERENCE_REGEX = %r{\[[^\]]+\]\(field://([^)]+)\)}.freeze
    SKILL_REFERENCE_REGEX = %r{\[[^\]]+\]\(skill://([^/)]+)\)}.freeze
    COMPANION_TOOL_GROUPS = [
      [%w[get_deal search_deals create_deal update_deal transition_deal_stage], %w[list_deal_pipelines list_deal_stages]],
      [%w[create_deal update_deal transition_deal_stage], %w[get_deal search_deals]],
      [%w[get_deal search_deals create_deal update_deal], %w[list_deal_custom_fields]],
      [%w[get_task search_tasks create_task update_task], %w[list_task_custom_fields]],
      [%w[get_appointment search_appointments create_appointment update_appointment], %w[list_appointment_custom_fields]],
      [%w[send_message_to_conversation create_touch], %w[list_captain_documents]]
    ].freeze

    class LegacyAssistant < ActiveRecord::Base
      self.table_name = 'captain_assistants'
    end

    class LegacyScenario < ActiveRecord::Base
      self.table_name = 'captain_scenarios'
    end

    class LegacyHandoff < ActiveRecord::Base
      self.table_name = 'captain_agent_handoffs'
    end

    def perform
      report = { converted: 0, existing: 0, skipped: [] }
      LegacyScenario.find_each do |scenario|
        result = convert!(scenario.id)
        if result[:skipped]
          report[:skipped] << result
        else
          report[result[:created] ? :converted : :existing] += 1
        end
      end
      report
    end

    def convert!(scenario_id)
      LegacyAssistant.transaction do
        scenario = LegacyScenario.find(scenario_id)
        parent = LegacyAssistant.find_by(id: scenario.assistant_id)
        unless parent && parent.account_id == scenario.account_id
          next({ skipped: true, scenario_id: scenario.id, warning: 'parent_missing_or_account_mismatch' })
        end

        parent.lock!
        existing = LegacyAssistant.find_by(legacy_scenario_id: scenario.id)
        next({ assistant_id: existing.id, created: false }) if existing

        agent = LegacyAssistant.create!(converted_attributes(scenario, parent))
        initialize_routes!(parent, agent)
        { assistant_id: agent.id, created: true, warnings: agent.config.dig('legacy_scenario_migration', 'warnings') }
      end
    end

    private

    def converted_attributes(scenario, parent)
      attributes = {
        account_id: parent.account_id,
        name: scenario.title.presence || "Scenario #{scenario.id}",
        description: scenario.instruction,
        routing_description: scenario.description,
        usage_mode: parent.usage_mode,
        active: scenario.enabled,
        legacy_scenario_id: scenario.id,
        config: converted_config(scenario, parent),
        response_guidelines: parent.response_guidelines.deep_dup,
        guardrails: parent.guardrails.deep_dup,
        created_at: scenario.created_at,
        updated_at: scenario.updated_at
      }
      attributes.merge(Captain::Assistant::MergeLegacyRulesService.attributes_for(LegacyAssistant.new(attributes)))
    end

    def converted_config(scenario, parent)
      original = parent.config.to_h.deep_stringify_keys
      snapshot = original.slice(*INHERITED_CONFIG_KEYS).deep_dup
      own_texts = [scenario.instruction, *shared_rule_texts(parent)]
      selected = original.dig('tool_access', 'agent').to_h
      selected_ids = Array(selected.fetch('tool_ids', DEFAULT_AGENT_TOOL_IDS)).map(&:to_s)
      referenced_ids = references(own_texts, TOOL_REFERENCE_REGEX) | Array(scenario.tools).map(&:to_s)
      capability_ids = Captain::ToolAccess::CAPABILITY_CONTROLLED_AGENT_TOOL_IDS
      tool_ids = (referenced_ids - capability_ids) | (selected_ids & capability_ids)
      allow_human_handoff = selected_ids.include?('handoff')
      tool_ids = allow_human_handoff ? tool_ids | ['handoff'] : tool_ids - ['handoff']
      COMPANION_TOOL_GROUPS.each { |aware, companions| tool_ids |= companions if (tool_ids & aware).any? }
      snapshot['tool_access'] = {
        'agent' => { 'enabled' => selected.fetch('enabled', true), 'tool_ids' => tool_ids },
        'assistant' => { 'enabled' => false, 'tool_ids' => [] }
      }
      snapshot['legacy_scenario_migration'] = migration_metadata(scenario, parent, own_texts)
      snapshot
    end

    def shared_rule_texts(parent)
      rules = Array(parent.config.to_h['rules']).filter_map do |raw|
        next unless raw.is_a?(Hash) && raw['enabled'] != false
        next if raw['slot'].present? && !%w[current_context_usage reference_glossary_usage].include?(raw['slot'])

        raw['content']
      end
      [*rules, *Array(parent.response_guidelines), *Array(parent.guardrails)].compact
    end

    def migration_metadata(scenario, parent, own_texts)
      warnings = []
      if parent.description.present?
        warnings << {
          'code' => 'parent_prompt_not_copied',
          'message' => 'This scenario previously received the parent main prompt. Review its own instructions before enabling new routes.'
        }
      end
      {
        'tool' => TOOL_REFERENCE_REGEX, 'field' => FIELD_REFERENCE_REGEX, 'skill' => SKILL_REFERENCE_REGEX
      }.each do |kind, pattern|
        inherited_ids = references([parent.description], pattern) - references(own_texts, pattern)
        next if inherited_ids.empty?

        warnings << { 'code' => "parent_prompt_#{kind}_dependencies_not_copied", 'reference_ids' => inherited_ids,
                      'message' => "References to #{kind}s used only by the parent main prompt were not copied." }
      end
      warnings << { 'code' => 'missing_own_instruction', 'message' => 'The legacy scenario has no own instruction.' } if scenario.instruction.blank?
      {
        'scenario_id' => scenario.id, 'parent_assistant_id' => parent.id, 'parent_assistant_name' => parent.name,
        'explicit_tool_ids' => Array(scenario.tools).map(&:to_s).uniq,
        'referenced_tool_ids' => references(own_texts, TOOL_REFERENCE_REGEX),
        'referenced_field_ids' => references(own_texts, FIELD_REFERENCE_REGEX),
        'referenced_skill_ids' => references(own_texts, SKILL_REFERENCE_REGEX),
        'warnings' => warnings
      }
    end

    def references(texts, pattern)
      Array(texts).flatten.compact.flat_map { |text| text.to_s.scan(pattern).flatten }
                  .map { |reference| reference.gsub(/\\(.)/, '\\1') }.uniq
    end

    def initialize_routes!(parent, agent)
      return unless parent.usage_mode == 'external_agent' && agent.usage_mode == 'external_agent'

      scenario_ids = LegacyScenario.where(assistant_id: parent.id, account_id: parent.account_id).pluck(:id)
      peers = LegacyAssistant.where(legacy_scenario_id: scenario_ids, account_id: parent.account_id, usage_mode: 'external_agent').pluck(:id)
      peer_ids = ([parent.id] + peers).uniq - [agent.id]
      now = Time.current
      rows = peer_ids.flat_map do |peer_id|
        [
          { account_id: parent.account_id, source_assistant_id: agent.id, target_assistant_id: peer_id, created_at: now, updated_at: now },
          { account_id: parent.account_id, source_assistant_id: peer_id, target_assistant_id: agent.id, created_at: now, updated_at: now }
        ]
      end
      LegacyHandoff.insert_all(rows, unique_by: :index_captain_agent_handoffs_on_source_and_target) if rows.any?
    end
  end
end
