namespace :calendar_notifications do
  desc 'Preview or mark existing appointment notification rules. MODE=dry-run|apply BACKUP=/safe/path.json'
  task adopt: :environment do
    mode = ENV.fetch('MODE', 'dry-run')
    raise ArgumentError, 'MODE must be dry-run or apply' unless %w[dry-run apply].include?(mode)
    raise ArgumentError, 'BACKUP is required for apply' if mode == 'apply' && ENV['BACKUP'].blank?

    scope = AutomationRule.where(event_name: AutomationRule::APPOINTMENT_EVENT_NAMES, calendar_managed: false)
    rows = scope.pluck(:id, :account_id, :actions).filter_map do |id, account_id, actions|
      { id: id, account_id: account_id, calendar_managed: false } if Array(actions).any? do |action|
        action['action_name'] == 'create_touch'
      end
    end
    rows.group_by { |row| row[:account_id] }.sort.each do |account_id, account_rows|
      puts "account=#{account_id} rules=#{account_rows.size}"
    end
    puts "mode=#{mode} total=#{rows.size}"

    if ENV['BACKUP'].present?
      File.write(ENV.fetch('BACKUP'), JSON.pretty_generate(rows))
      puts "backup=#{ENV.fetch('BACKUP')}"
    end
    if mode == 'apply'
      AutomationRule.transaction do
        scope.where(id: rows.map { |row| row[:id] }).update_all(calendar_managed: true)
      end
      puts "marked=#{rows.size}"
    end
  end
end
