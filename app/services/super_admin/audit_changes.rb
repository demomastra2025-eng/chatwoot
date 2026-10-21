# frozen_string_literal: true

# The changes of an entry of the audit log as the audit page shows them (what is stored is never touched):
#
# * the limits are said in words, never as the number that stands for no limit (100 000 operators): a plan writes
#   { 'limits' => { 'conversations' => { 'from' => 'не задан', 'to' => 'Без ограничений' } } }, any other entry (the generic save of an
#   account, the Platform API) shows its numbers as words in the place of the numbers;
# * an entry that carries its own words (a change of the limits by a super admin, `update_limits`) is shown as it was written;
# * the lists the limits keep for themselves in the custom attributes (Accounts::LimitSettings) are left out;
# * the limits of an entry that changes them (`update_limits`, `apply_plan`, `sync_plan_limits`) are one line each in the order of the
#   screens, not the JSON of the database (which keeps no order): «Письма в день: как в тарифе (100 писем в день) → своё число (50 писем в день)».
#
#   changes = SuperAdmin::AuditChanges.new(audit, method(:super_admin_limit_value))
#   changes.readable    # the changes as a hash, in words
#   changes.limit_lines # => ['Операторы: как в тарифе (без ограничений) → своё число (5 операторов)'] ([] for an entry without such limits)
#   changes.rest        # the changes without the limits that limit_lines tells (all of them when there are no lines)
#
# `limit_value` says one number of a limit: ->(key, value, given_back: false) { 'Без ограничений' } (SuperAdmin::DisplayHelper).
class SuperAdmin::AuditChanges
  LIMIT_KEYS = Accounts::Plans::LIMIT_KEYS
  # The entries whose `limits` are { 'agents' => { 'from' => words, 'to' => words } } once readable
  LIMIT_ACTIONS = %w[update_limits apply_plan sync_plan_limits].freeze
  ARROW = ' → '

  def initialize(audit, limit_value)
    @audit = audit
    @limit_value = limit_value
  end

  def readable
    return @readable if defined?(@readable)

    @readable = read_changes(@audit.audited_changes)
  end

  # One line per changed limit, in the order of the screens: «Операторы: не задан → 5 операторов»
  def limit_lines
    @limit_lines ||= begin
      limits = readable.is_a?(Hash) && LIMIT_ACTIONS.include?(@audit.action) ? readable['limits'] : nil
      limits.is_a?(Hash) ? ordered(limits).filter_map { |key, change| limit_line(key, change) } : []
    end
  end

  # The changes without the limits that are told by #limit_lines (a limit that could not be told stays)
  def rest
    changes = readable
    return changes if limit_lines.empty?

    untold = changes['limits'].reject { |key, change| limit_change?(key, change) }
    changes.except('limits').merge(untold.empty? ? {} : { 'limits' => untold })
  end

  private

  def read_changes(changes)
    return changes unless changes.is_a?(Hash)

    case @audit.action
    when 'apply_plan', 'sync_plan_limits' then plan_limits(changes)
    when 'update_limits' then changes
    else account_changes(changes)
    end
  end

  def ordered(limits)
    limits.sort_by { |key, _change| SuperAdmin::LimitWords::SCREEN_ORDER.index(key.to_s) || SuperAdmin::LimitWords::SCREEN_ORDER.size }
  end

  def limit_change?(key, change)
    change.is_a?(Hash) && LIMIT_KEYS.include?(key.to_s)
  end

  def limit_line(key, change)
    return unless limit_change?(key, change)

    label = change['label'].presence || I18n.t("super_admin.limits.#{key}.label")
    "#{label}: #{change['from']}#{ARROW}#{change['to']}"
  end

  # The limits a plan wrote (applied, or only synced into the limits): { 'conversations' => { 'from' => nil, 'to' => 100000 } }
  def plan_limits(changes)
    return changes unless changes['limits'].is_a?(Hash)

    readable = changes['limits'].to_h do |key, change|
      next [key, change] unless change.is_a?(Hash) && LIMIT_KEYS.include?(key)

      given_back = !change['from'].nil?
      [key, { 'from' => @limit_value.call(key, change['from']), 'to' => @limit_value.call(key, change['to'], given_back: given_back) }]
    end
    changes.merge('limits' => readable)
  end

  # The limits of a save of an account: the numbers in words, the lists of the limits left out of the custom attributes
  def account_changes(changes)
    readable = changes.dup
    readable['limits'] = limit_numbers(changes['limits']) if changes.key?('limits')
    readable['custom_attributes'] = without_limit_lists(changes['custom_attributes']) if changes.key?('custom_attributes')
    readable.delete('custom_attributes') if readable['custom_attributes'].is_a?(Array) && readable['custom_attributes'].uniq.size == 1
    readable
  end

  # { 'agents' => 5, 'conversations' => 100000 } or the pair [before, after] of it
  def limit_numbers(limits)
    case limits
    when Array then limits.map { |side| limit_numbers(side) }
    when Hash then limits.to_h { |key, value| [key, number?(key, value) ? @limit_value.call(key, value) : value] }
    else limits
    end
  end

  def number?(key, value)
    LIMIT_KEYS.include?(key.to_s) && (value.nil? || value.is_a?(Numeric))
  end

  def without_limit_lists(attributes)
    case attributes
    when Array then attributes.map { |side| without_limit_lists(side) }
    when Hash then attributes.except(*Accounts::LimitSettings::ATTRIBUTE_KEYS)
    else attributes
    end
  end
end
