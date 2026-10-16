# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::Plans do
  subject(:plans) { described_class.current }

  let(:feature_names) { Featurable::FEATURE_NAMES }
  let(:deprecated_features) { Featurable::FEATURE_LIST.select { |feature| feature['deprecated'] }.pluck('name') }

  # A valid config to bend in the validation examples
  def valid_config(overrides = {})
    {
      'version' => 1,
      'base' => { 'features' => %w[crm], 'limits' => described_class::LIMIT_KEYS.index_with { nil } },
      'modules' => { 'ai_agents' => { 'features' => %w[captain_integration], 'limits' => {} } },
      'locked_on' => %w[labels],
      'never_enabled' => %w[saml],
      'internal' => %w[ip_lookup],
      'trial' => { 'days' => 3, 'modules' => %w[ai_agents] }
    }.merge(overrides)
  end

  def registry_from(overrides = {})
    described_class.new(valid_config(overrides), feature_names: feature_names)
  end

  describe 'the shipped config/account_plans.yml' do
    it 'classifies every flag of features.yml exactly once' do
      placed = plans.base_features + plans.module_keys.flat_map { |key| plans.module_features(key) } +
               plans.locked_on + plans.never_enabled + plans.internal

      expect(plans.unclassified_features).to be_empty
      expect(placed.tally.select { |_name, count| count > 1 }).to be_empty
      expect(feature_names - placed).to be_empty
    end

    it 'names only flags that exist in base, the modules, locked_on and internal' do
      listed = plans.base_features + plans.module_keys.flat_map { |key| plans.module_features(key) } + plans.locked_on + plans.internal

      expect(listed - feature_names).to be_empty
    end

    it 'never lets a never_enabled flag into the base, a module or locked_on' do
      allowed = plans.base_features + plans.module_keys.flat_map { |key| plans.module_features(key) } + plans.locked_on

      expect(plans.never_enabled & allowed).to be_empty
      expect(plans.features_for(plans.module_keys) & plans.never_enabled).to be_empty
    end

    it 'keeps the dangerous and deprecated flags switched off by every plan' do
      expect(plans.never_enabled).to include(
        'scheduling_finance', 'custom_roles', 'saml', 'captain_scheduling_grounding_guard', 'contact_chatwoot_support_team'
      )
      expect(plans.never_enabled).to include(*deprecated_features)
    end

    it 'puts chats, CRM and telephony in the base and the four modules where the owner approved them' do
      expect(plans.base_features).to include(
        'channel_website', 'channel_email', 'inbound_emails', 'channel_facebook', 'channel_instagram', 'channel_tiktok', 'help_center',
        'automations', 'integrations', 'reports', 'crm', 'crm_deals', 'crm_tasks', 'scheduling', 'macros', 'canned_responses', 'agent_bots',
        'channel_voice', 'whatsapp_call', 'voice_recorder'
      )
      expect(plans.module_keys).to eq(%w[ai_agents broadcasts quality extensions])
      expect(plans.module_features('ai_agents')).to include('captain_integration', 'captain_integration_v2', 'captain_tasks',
                                                            'help_center_embedding_search')
      expect(plans.module_features('broadcasts')).to contain_exactly('campaigns', 'whatsapp_campaign')
      expect(plans.module_features('quality')).to contain_exactly('sla', 'audit_logs', 'csat_review_notes')
      expect(plans.module_features('extensions')).to contain_exactly('custom_tools', 'crm_integration', 'conversation_required_attributes',
                                                                     'disable_branding')
    end

    it 'keeps the operational flags always on' do
      expect(plans.locked_on).to include('agent_management', 'team_management', 'inbox_management', 'labels', 'custom_attributes')
    end

    it 'lists every limit key in the base and only valid limit keys in the modules' do
      expect(plans.base_limits.keys).to match_array(described_class::LIMIT_KEYS)
      plans.module_keys.each do |key|
        expect(plans.module_limits(key).keys - described_class::LIMIT_KEYS).to be_empty
      end
    end

    it 'leaves operators and storage open until the owner sets the numbers' do
      expect(plans.base_limits).to include('agents' => nil, 'storage_bytes' => nil)
    end

    it 'produces limits the account validation accepts' do
      numbers = plans.limits_for(plans.module_keys).compact
      account = Account.new(name: 'Plan limits', limits: numbers)

      expect(account).to be_valid
      expect(Account.new(name: 'All keys', limits: described_class::LIMIT_KEYS.index_with(1))).to be_valid
    end

    it 'is the one list of limit keys: the account accepts each of them, nothing else, and follows the list when it changes' do
      described_class::LIMIT_KEYS.each do |key|
        expect(Account.new(name: 'One key', limits: { key => 1 })).to be_valid, key
      end
      expect(Account.new(name: 'Ghost', limits: { 'ghost_limit' => 1 })).not_to be_valid
      expect(Account.new(name: 'Negative', limits: described_class::LIMIT_KEYS.index_with(-1))).not_to be_valid

      stub_const('Accounts::Plans::LIMIT_KEYS', [*described_class::LIMIT_KEYS, 'ghost_limit'].freeze)

      expect(Account.new(name: 'Ghost', limits: { 'ghost_limit' => 1 })).to be_valid
    end

    it 'turns unlimited into the platform maximum so the global defaults cannot trap a new clinic' do
      limits = plans.limits_for([])

      expect(limits).to include('conversations' => ChatwootApp.max_limit, 'non_web_inboxes' => ChatwootApp.max_limit, 'agents' => nil)
    end

    it 'derives the trial from the base plus the trial modules' do
      expect(plans.trial_days).to eq(3)
      expect(plans.trial_modules).to eq(%w[ai_agents])
      expect(plans.trial_features).to match_array(plans.base_features + plans.module_features('ai_agents') + plans.locked_on)
      expect(plans.trial_features).not_to include('channel_whatsapp')
    end

    it 'has Russian names and descriptions for the base and every module' do
      expect(I18n.t('super_admin.plans.base.name', locale: :ru, raise: true)).to eq('База')
      expect(I18n.t('super_admin.plans.base.description', locale: :ru, raise: true)).to be_present
      plans.module_keys.each do |key|
        expect(I18n.t("super_admin.plans.modules.#{key}.name", locale: :ru, raise: true)).to be_present
        expect(I18n.t("super_admin.plans.modules.#{key}.description", locale: :ru, raise: true)).to be_present
      end
    end

    it 'is frozen' do
      expect(plans).to be_frozen
      expect(plans.base_features).to be_frozen
      expect(plans.module_features('ai_agents')).to be_frozen
    end
  end

  describe '.plan_label' do
    it 'names the base alone and the base with modules' do
      expect(described_class.plan_label([])).to eq('База')
      expect(described_class.plan_label(%w[ai_agents broadcasts])).to eq('База + ИИ-агенты + Рассылки')
    end
  end

  describe '.astana_now' do
    it 'is ISO 8601 in the Astana offset, never UTC' do
      expect(described_class.astana_now).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+05:00\z/)
    end
  end

  describe '#features_for / #normalize_modules' do
    it 'adds the chosen modules to the base and the locked flags' do
      expect(plans.features_for([])).to match_array(plans.base_features + plans.locked_on)
      expect(plans.features_for(%w[broadcasts])).to include('campaigns', 'crm', 'labels')
      expect(plans.features_for(%w[broadcasts])).not_to include('captain_integration')
    end

    it 'orders modules like the registry, drops duplicates and blanks, and rejects unknown ones' do
      expect(plans.normalize_modules(['quality', 'ai_agents', 'quality', ''])).to eq(%w[ai_agents quality])
      expect { plans.normalize_modules(%w[nope]) }.to raise_error(ArgumentError, /nope/)
    end

    it 'finds the module that owns a flag' do
      expect(plans.module_for_feature('campaigns')).to eq('broadcasts')
      expect(plans.module_for_feature('crm')).to be_nil
    end
  end

  describe 'validation of a config' do
    it 'accepts a valid config and tolerates a never_enabled flag that features.yml no longer has' do
      expect { registry_from('never_enabled' => %w[saml removed_by_another_branch]) }.not_to raise_error
      expect(registry_from('never_enabled' => %w[removed_by_another_branch]).managed_features).not_to include('removed_by_another_branch')
    end

    it 'rejects an unknown flag in the base, a module, locked_on or internal' do
      expect { registry_from('base' => valid_config['base'].merge('features' => %w[nope])) }.to raise_error(described_class::InvalidConfig, /nope/)
      expect { registry_from('modules' => { 'ai_agents' => { 'features' => %w[nope] } }) }.to raise_error(described_class::InvalidConfig, /nope/)
      expect { registry_from('locked_on' => %w[nope]) }.to raise_error(described_class::InvalidConfig, /nope/)
      expect { registry_from('internal' => %w[nope]) }.to raise_error(described_class::InvalidConfig, /nope/)
    end

    it 'rejects a flag that is placed twice, also between never_enabled and the base' do
      expect { registry_from('internal' => %w[crm]) }.to raise_error(described_class::InvalidConfig, /crm/)
      expect { registry_from('never_enabled' => %w[crm]) }.to raise_error(described_class::InvalidConfig, /crm/)
      expect { registry_from('locked_on' => %w[labels labels]) }.to raise_error(described_class::InvalidConfig, /labels/)
    end

    it 'rejects base limits that do not list every key and limits with unknown keys or bad values' do
      limits = valid_config['base']['limits']
      expect { registry_from('base' => { 'features' => %w[crm], 'limits' => limits.except('agents') }) }
        .to raise_error(described_class::InvalidConfig, /agents/)
      expect { registry_from('base' => { 'features' => %w[crm], 'limits' => limits.merge('seats' => 1) }) }
        .to raise_error(described_class::InvalidConfig, /seats/)
      expect { registry_from('base' => { 'features' => %w[crm], 'limits' => limits.merge('agents' => -1) }) }
        .to raise_error(described_class::InvalidConfig, /agents/)
      expect { registry_from('base' => { 'features' => %w[crm], 'limits' => limits.merge('agents' => 'many') }) }
        .to raise_error(described_class::InvalidConfig, /agents/)
    end

    it 'rejects a bad module key, an empty module and a trial that names an unknown module' do
      expect { registry_from('modules' => { 'base' => { 'features' => %w[sla] } }) }.to raise_error(described_class::InvalidConfig, /base/)
      expect { registry_from('modules' => { 'ai_agents' => { 'features' => [] } }) }.to raise_error(described_class::InvalidConfig, /ai_agents/)
      expect { registry_from('trial' => { 'days' => 3, 'modules' => %w[ghost] }) }.to raise_error(described_class::InvalidConfig, /ghost/)
      expect { registry_from('trial' => { 'days' => 0, 'modules' => [] }) }.to raise_error(described_class::InvalidConfig, /days/)
    end

    it 'rejects a missing or non-positive version' do
      expect { registry_from('version' => nil) }.to raise_error(described_class::InvalidConfig, /version/)
      expect { registry_from('version' => 0) }.to raise_error(described_class::InvalidConfig, /version/)
    end

    it 'reports flags of features.yml that no place names, without failing to load' do
      registry = registry_from

      expect(registry.unclassified_features).to include('sla', 'campaigns')
      expect(registry.unclassified_features).not_to include('crm', 'labels', 'ip_lookup')
    end
  end
end
