require 'rails_helper'

RSpec.describe SuperAdmin::AiModelsHistory do
  let(:super_admin) { create(:super_admin, name: 'Айдар') }
  let(:saver) { SuperAdmin::AppConfigSaver.new(actor: super_admin) }

  def history
    values = InstallationConfig.where(name: SuperAdmin::AppConfigsController::CAPTAIN_CONFIG_KEYS).to_h { |config| [config.name, config.value] }
    described_class.new(values: values)
  end

  it 'says what a setting was before its last change, who changed it and when' do
    saver.save('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-5.6-luna', secret: false)
    saver.save('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-6-luna', secret: false)

    entry = history.previous('CAPTAIN_DEFAULT_MODEL')

    expect(entry).to have_attributes(value: 'openai/gpt-5.6-luna', actor: 'Айдар')
    expect(entry.at).to be_within(1.minute).of(Time.current)
  end

  it 'says the setting followed the built-in value when it was blank before' do
    InstallationConfig.where(name: 'CAPTAIN_MODERATION_MODEL').delete_all
    saver.save('CAPTAIN_MODERATION_MODEL', 'openai/gpt-oss-safeguard-20b', secret: false)

    expect(history.previous('CAPTAIN_MODERATION_MODEL')).to have_attributes(value: '')
  end

  it 'offers nothing for a setting that was never changed here' do
    upsert_installation_config('CAPTAIN_LANGUAGE_DETECTION_MODEL', 'openai/gpt-6-luna-decisions')

    expect(history.previous('CAPTAIN_LANGUAGE_DETECTION_MODEL')).to be_nil
  end

  it 'offers nothing when the value was changed by other means after the last entry of the log' do
    saver.save('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-5.6-luna', secret: false)
    upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-6-luna')

    expect(history.previous('CAPTAIN_DEFAULT_MODEL')).to be_nil
  end

  it 'never offers the value of a secret, which the log does not hold' do
    saver.save('CAPTAIN_OPENROUTER_API_KEY', 'sk-first', secret: true)
    saver.save('CAPTAIN_OPENROUTER_API_KEY', 'sk-second', secret: true)

    expect(history.previous('CAPTAIN_OPENROUTER_API_KEY')).to be_nil
  end

  it 'keeps a short list of models whole, so that it can be put back' do
    first = Array.new(16) { |index| "vendor/model-number-#{index}" }
    expect(JSON.generate(first).length).to be > SuperAdmin::AppConfigSaver::VALUE_LIMIT
    saver.save('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', JSON.generate(first), secret: false)
    saver.save('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', JSON.generate(first.first(2)), secret: false)

    entry = history.previous('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')

    expect(JSON.parse(entry.value)).to eq(first)
  end

  it 'does not offer a value that the log cut short' do
    audit = SuperAdmin::PlatformAudit.record(
      auditable: InstallationConfig.find_or_create_by!(name: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST') { |config| config.value = '["a"]' },
      action: SuperAdmin::AppConfigSaver::AUDIT_ACTION, actor: super_admin,
      changes: { 'name' => 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', 'value' => ["[\"#{'x' * 300}"[0, 297] + '...', '["a"]'] }
    )
    InstallationConfig.find_by!(name: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST').update!(value: '["a"]')

    expect(audit).to be_present
    expect(history.previous('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')).to be_nil
  end

  it 'names nobody when the person who made the change is gone' do
    saver.save('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-5.6-luna', secret: false)
    saver.save('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-6-luna', secret: false)
    Audited::Audit.where(action: SuperAdmin::AppConfigSaver::AUDIT_ACTION).update_all(user_id: nil, user_type: nil)

    expect(history.previous('CAPTAIN_DEFAULT_MODEL')).to have_attributes(value: 'openai/gpt-5.6-luna', actor: nil)
  end
end
