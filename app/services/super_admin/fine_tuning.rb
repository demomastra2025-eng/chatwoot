# frozen_string_literal: true

# The switches of the «Тонкая настройка» block of a clinic: single functions on top of the plan, in groups.
#
# Only flags the plans classify as part of the base or of a module are offered. Operational flags that are always on
# (`locked_on`), flags no plan ever enables (`never_enabled`) and infrastructure flags (`internal`) are not shown, so
# the operator cannot switch off the management of operators or channels, or switch on roles or SAML.
#
#   SuperAdmin::FineTuning.new(account).groups.each do |group|
#     group.title                       # => "Телефония"
#     group.switches.each { |sw| sw.name, sw.label, sw.enabled, sw.manual }
#   end
#
# A switch is `manual` when the clinic's flag differs from what its plan says (the flag is in the plan drift).
class SuperAdmin::FineTuning
  Switch = Struct.new(:name, :label, :enabled, :manual, keyword_init: true)
  Group = Struct.new(:key, :title, :switches, keyword_init: true)

  # How the flags of the base are grouped on screen. A base flag that is not listed lands in «Прочее», so a flag
  # added to the base later still gets a switch.
  BASE_GROUPS = {
    'channels' => %w[channel_website channel_email inbound_emails channel_facebook channel_instagram channel_tiktok],
    'telephony' => %w[channel_voice whatsapp_call voice_recorder],
    'chats' => %w[auto_resolve_conversations macros canned_responses agent_bots automations integrations reports help_center],
    'crm' => %w[crm companies crm_deals crm_tasks scheduling]
  }.freeze
  OTHER_GROUP = 'other'

  def initialize(account)
    @account = account
  end

  def groups
    @groups ||= (base_groups + module_groups).select { |group| group.switches.any? }
  end

  # Every flag that has a switch
  def flag_names
    groups.flat_map { |group| group.switches.map(&:name) }
  end

  # Names of the flags no plan ever enables and that still matter to an operator (not the deprecated ones)
  def never_enabled_labels
    deprecated = SuperAdmin::AccountFeaturesHelper.account_features.select { |feature| feature['deprecated'] }.pluck('name')
    names = (Accounts::Plans.never_enabled & Featurable::FEATURE_NAMES) - deprecated
    names.map { |name| SuperAdmin::AccountFeaturesHelper.feature_label(name) }
  end

  private

  def base_groups
    remaining = known(Accounts::Plans.base_features)
    listed = BASE_GROUPS.map do |key, names|
      chosen = names & remaining
      remaining -= chosen
      build_group(key, I18n.t("super_admin.fine_tuning.groups.#{key}"), chosen)
    end
    listed + [build_group(OTHER_GROUP, I18n.t("super_admin.fine_tuning.groups.#{OTHER_GROUP}"), remaining)]
  end

  def module_groups
    Accounts::Plans.module_keys.map do |key|
      build_group("module_#{key}", Accounts::Plans.module_name(key), known(Accounts::Plans.module_features(key)))
    end
  end

  def build_group(key, title, names)
    Group.new(key: key, title: title, switches: names.map { |name| build_switch(name) })
  end

  def build_switch(name)
    Switch.new(
      name: name, label: SuperAdmin::AccountFeaturesHelper.feature_label(name),
      enabled: enabled_flags.include?(name), manual: manual_flags.include?(name)
    )
  end

  # Flags of the plan that the application knows (a flag removed from features.yml is skipped)
  def known(names)
    names & Featurable::FEATURE_NAMES
  end

  def enabled_flags
    @enabled_flags ||= @account.enabled_features.keys
  end

  def manual_flags
    @manual_flags ||= begin
      drift = Accounts::PlanDrift.call(@account)
      drift ? drift[:extra] + drift[:missing] : []
    end
  end
end
