# frozen_string_literal: true

# A read-only report for the owner: for every account, what applying "base + the modules it already uses" would
# switch on, switch off and change in the limits. A module counts as used when any of its flags is on.
# Nothing is written; it is meant to be read before any plan is applied to existing clinics.
#
#   puts Accounts::PlanReport.new.to_text           # all accounts
#   puts Accounts::PlanReport.new(Account.where(id: 12)).to_text
class Accounts::PlanReport
  Row = Struct.new(:account_id, :name, :modules, :enable, :disable, :limits, :notes, keyword_init: true) do
    def unchanged?
      enable.empty? && disable.empty? && limits.empty?
    end
  end

  def initialize(accounts = Account.all)
    @accounts = accounts
  end

  def rows
    @accounts.order(:id).map { |account| row_for(account) }
  end

  def to_text
    report_rows = rows
    lines = ["Plan report (read-only, nothing is written), plans version #{Accounts::Plans.version}"]
    report_rows.each { |row| lines.concat(lines_for(row)) }
    lines << "Accounts: #{report_rows.size}, with no change: #{report_rows.count(&:unchanged?)}"
    lines.join("\n")
  end

  # The modules an account uses today
  def self.used_modules(account)
    Accounts::Plans.module_keys.select do |key|
      Accounts::Plans.module_features(key).any? { |feature| account.feature_enabled?(feature) }
    end
  end

  private

  def row_for(account)
    modules = self.class.used_modules(account)
    diff = Accounts::ApplyPlan.new(account: account, modules: modules).preview
    Row.new(account_id: account.id, name: account.name, modules: modules, enable: diff.enable, disable: diff.disable,
            limits: diff.limits, notes: diff.notes)
  end

  def lines_for(row)
    ["##{row.account_id} #{row.name} | modules used: #{row.modules.join(', ').presence || '-'}"] + change_lines(row) + closing_lines(row)
  end

  def change_lines(row)
    lines = []
    lines << "    enable  (#{row.enable.size}): #{row.enable.join(', ')}" if row.enable.any?
    lines << "    disable (#{row.disable.size}): #{row.disable.join(', ')}" if row.disable.any?
    lines + row.limits.map { |key, change| "    limit #{key}: #{change['from'].inspect} -> #{change['to'].inspect}" }
  end

  def closing_lines(row)
    lines = []
    lines << "    notes: #{row.notes.join(', ')}" if row.notes.any?
    lines << '    no change' if row.unchanged?
    lines
  end
end
